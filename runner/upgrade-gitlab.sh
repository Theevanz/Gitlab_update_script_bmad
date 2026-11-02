#!/usr/bin/env bash
#
# upgrade-gitlab.sh moves one Docker Compose GitLab exactly one required stop.
#
# Each run carries the instance from its live version to the next required
# stop only. Run again to advance further. Every failure stops the run with
# one clear log line naming what failed, where, and what to do next.
#
# Usage:
#   GITLAB_URL=... GITLAB_ADMIN_TOKEN=... ... ./upgrade-gitlab.sh [--plan] [--nobackup]
#
# Required settings (passed as environment values):
#   GITLAB_URL            web address of this GitLab, for example https://gitlab.example.com
#   GITLAB_ADMIN_TOKEN    token that may pause runners (needs the manage_runner right)
#   GITLAB_SMOKE_TOKEN    token that may push to the seed project (needs the write_repository right)
#   GITLAB_COMPOSE_FILE   path to the docker-compose.yml file that runs GitLab
#   COMPOSE_SERVICE       service name of GitLab inside that compose file
#   BACKUP_PATH           folder holding the backup (may be unset with --nobackup)
#   SEED_PROJECT_PATH     project path inside GitLab used for the clone-and-push
#                         smoke test, for example "seed/demo"
#
# Optional settings (empty counts as unset, the default applies):
#   GITLAB_IMAGE_REPO     image name without tag, default gitlab/gitlab-ce
#   LOG_FILE              file log lines are added to, default ./upgrade-gitlab.log
#   UPGRADE_PATH_FILE     stop list file, default upgrade_path.yml next to this script
#
# Flags:
#   --plan      print the plan and rehearse every readable check, change nothing
#   --nobackup  skip backup checks run-wide, for testing before the backup
#               producer exists; the run then has no rollback path
#
# The script reads top to bottom: settings, safety rails, logging, probes,
# phases in run order, flag parsing, then main. It uses only Bash, curl,
# git, and docker tooling, plus jq when present with a grep fallback.

# ---- constants: every shared value starts here ----

RUN_START="$(date +%s)" || exit 1
LOCK_DIR="./upgrade-gitlab.lock"
LOCK_HELD=0
GATE="validate"
PHASE="startup"
TARGET=""
TARGET_NOTE=""
TARGET_STOP=""
TARGET_IMAGE=""
PREV_IMAGE=""
SOS_URL="https://gitlab.com/gitlab-com/support/toolbox/gitlabsos/-/raw/cb73cacc/gitlabsos.rb"
CURRENT_VERSION=""
RUNNERS_STATE="unknown"
CONTAINER_STATE="unknown"
CURL_CONFIG=""
DIE_ACTIVE=0
PLAN_ONLY=0
SKIP_BACKUP=0
EXPECTED_EE=0
PARSER=""
LOG_FILE="${LOG_FILE:-./upgrade-gitlab.log}"
HTTP_CODE=""
HTTP_BODY=""
HB_ELAPSED=0
HB_HEALTH=""
HB_LIVE=""
HB_CPU=""
HB_MEM=""
HB_BIO=""
HB_NET=""
HB_FIN=0
HB_TOT=0
HB_DELTA=0

# ---- strictness and traps: fail on typos, clean up on every exit ----

# Exit on use of an unset variable, so a typo stops loudly instead of
# silently reading empty. Pipelines report failure when any step fails.
set -u
set -o pipefail

cleanup() {
  # Runs on every exit path. Drops the lock this run took and wipes the
  # temp file holding the admin token. Never stops the run itself.
  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
  if [ -n "$CURL_CONFIG" ] && [ -f "$CURL_CONFIG" ]; then
    rm -f "$CURL_CONFIG" || true
    CURL_CONFIG=""
  fi
}

trap cleanup EXIT
trap 'die "$GATE" "run to completion" "caught stop signal" "check the instance state, then re-run" "stopped by operator signal"' INT TERM

# ---- small text helpers: keep every log line on one line ----

one_line() {
  # Squeeze a value onto one line so it cannot break the log format.
  # Usage: one_line <text>; prints the text with newlines and tabs as spaces.
  printf '%s' "$1" | tr '\n\r\t' '   '
}

trim_edge() {
  # Drop blank space from both ends of a value. Used for tokens and
  # for table cells parsed out of command output.
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

script_dir() {
  # Print the folder holding this script, resolving PATH lookup first so
  # the default stop-list path works however the script was started.
  local src dir
  src="$(command -v "$0" 2>/dev/null || true)"
  if [ -z "$src" ]; then
    src="$0"
  fi
  dir="$(dirname "$src")" || return 1
  (cd "$dir" && pwd) || return 1
}

# ---- logging: one format everywhere, values stay single-quoted in halts ----

utc_now() {
  date -u +%FT%TZ
}

log() {
  # Add one normal line to the log file and to the screen (standard error,
  # so captured command output stays clean). Usage: log <phase> <message>.
  # Double quotes become single quotes inside the message, so the msg="..."
  # field always holds together on one line while quoted values stay grouped.
  local line clean
  clean="${2//\"/\'}"
  line="$(utc_now) phase=$1"
  if [ -n "$TARGET" ]; then
    line="$line target=$TARGET"
  fi
  line="$line msg=\"$(one_line "$clean")\""
  printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2 || true
  return 0
}

die() {
  # Stop the run with one clear line, then exit 1. Every failure in every
  # phase ends here, so the log always names the gate, what was expected,
  # what was seen, and what to do next. Runner and container state are the
  # last values the run actually observed, never fixed text. After a failure
  # is found, die() changes nothing except log and bundle writes.
  # Usage: die <gate> <expected> <observed> <action> <message>.
  local gate expected observed action message line
  if [ "$DIE_ACTIVE" = "1" ]; then
    exit 1
  fi
  DIE_ACTIVE=1
  gate="$(one_line "$1")"
  expected="$(one_line "$2")"
  observed="$(one_line "$3")"
  action="$(one_line "$4")"
  message="$(one_line "$5")"
  gate="${gate//\'/}"
  expected="${expected//\'/}"
  observed="${observed//\'/}"
  action="${action//\'/}"
  message="${message//\"/\'}"
  line="$(utc_now) phase=$PHASE"
  if [ -n "$TARGET" ]; then
    line="$line target=$TARGET"
  fi
  line="$line GATE='${gate}' EXPECTED='${expected}' OBSERVED='${observed}' ACTION='${action}'"
  line="$line RUNNERS='${RUNNERS_STATE}' CONTAINER='${CONTAINER_STATE}' msg=\"${message}\""
  printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2 || true
  # Every live failure past planning leaves a diagnostics bundle plus the
  # rollback story. Planning failures skip it (nothing was touched, so there
  # is nothing to recover), and --plan mode never writes beyond its log.
  if [ "$PLAN_ONLY" = "0" ]; then
    case "$PHASE" in
      startup|validate|plan)
        log "$PHASE" "no failure bundle: run never reached the instance-touching phases"
        ;;
      *)
        collect_failure_bundle
        ;;
    esac
  fi
  exit 1
}

# ---- probes: every health signal flows through these (story 1.3 lands here) ----

# Probe rules the whole file follows:
# - Probes only read. They change nothing except adding log lines.
# - Probes report, phases decide: a probe that returns a value prints only
#   that value and returns 1 on trouble. It never stops the run itself, so
#   callers can safely capture its output. The caller stops with full context.
# - Every curl probe carries a timeout and its output shape is checked.
# - Every scripted compose exec passes -T (no terminal), so it never hangs
#   waiting for input.
# - HTTP answers are read through http_fetch, which fills HTTP_CODE and
#   HTTP_BODY. Call it directly, never inside $(...), or the caller cannot
#   see the values it filled.

container_state() {
  # Print one word for the GitLab container: Running, Restarting,
  # Exited:<code>, missing (compose knows no such container), or
  # docker-down (the docker call itself failed). Never stops the run.
  local cid lines raw status code
  if ! cid="$(docker compose -f "$GITLAB_COMPOSE_FILE" ps -q "$COMPOSE_SERVICE" 2>/dev/null)"; then
    printf 'docker-down\n'
    return 0
  fi
  if [ -z "$cid" ]; then
    printf 'missing\n'
    return 0
  fi
  lines="$(printf '%s\n' "$cid" | wc -l)" || lines=0
  if [ "$lines" -ne 1 ]; then
    printf 'other:unexpected-ps-output\n'
    return 0
  fi
  if ! raw="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid" 2>/dev/null)"; then
    printf 'docker-down\n'
    return 0
  fi
  status="${raw%% *}"
  code="${raw##* }"
  case "$status" in
    running)
      printf 'Running\n'
      ;;
    restarting)
      printf 'Restarting\n'
      ;;
    exited)
      printf 'Exited:%s\n' "$code"
      ;;
    *)
      printf 'other:%s\n' "$status"
      ;;
  esac
  return 0
}

refresh_container() {
  # Read fresh container state into CONTAINER_STATE and log it, so every
  # HTTP result in the log sits next to the runtime state behind it.
  CONTAINER_STATE="$COMPOSE_SERVICE:$(container_state)"
  log "$PHASE" "layer0 container state: $CONTAINER_STATE"
}

container_log_tail() {
  # Print the last lines of the service log for crash evidence.
  # Usage: container_log_tail <count>; returns 1 when the log is unreadable.
  local count out
  count="$1"
  if ! out="$(docker compose -f "$GITLAB_COMPOSE_FILE" logs --tail="$count" "$COMPOSE_SERVICE" 2>&1)"; then
    log "$PHASE" "log tail call failed: $(one_line "$out")"
    return 1
  fi
  printf '%s\n' "$out"
}

log_exit_evidence() {
  # Log the last 50 service log lines as crash evidence. Best effort, always
  # succeeds; the caller stops the run right after.
  local tail line
  if ! tail="$(container_log_tail 50)"; then
    log "$PHASE" "crash evidence: service log unreadable"
    return 0
  fi
  log "$PHASE" "crash evidence: last log lines follow"
  while IFS= read -r line || [ -n "$line" ]; do
    log "$PHASE" "logtail: $(one_line "$line")"
  done <<< "$tail"
  return 0
}

http_fetch() {
  # Fetch a URL into HTTP_CODE and HTTP_BODY. Returns 0 with both filled on
  # any HTTP answer, even an error page like 404 or 503, because the status
  # itself is a signal. Returns 1 with both empty only when the server
  # cannot be reached at all (refused, timeout). Usage: http_fetch <url>
  # with an optional second argument holding a curl token file and an
  # optional third holding PUT form data (reads stay GET; only the runner
  # pause switch writes, as "paused=true" or "paused=false").
  local url cfg put raw code
  url="$1"
  cfg="${2:-}"
  put="${3:-}"
  HTTP_CODE=""
  HTTP_BODY=""
  if [ -n "$put" ] && [ -z "$cfg" ]; then
    return 1
  fi
  if [ -n "$cfg" ]; then
    if [ -n "$put" ]; then
      raw="$(curl -sS -K "$cfg" --max-time 10 -X PUT --form "$put" -w '\n%{http_code}' "$url" 2>/dev/null)" || return 1
    else
      raw="$(curl -sS -K "$cfg" --max-time 10 -w '\n%{http_code}' "$url" 2>/dev/null)" || return 1
    fi
  else
    raw="$(curl -sS --max-time 10 -w '\n%{http_code}' "$url" 2>/dev/null)" || return 1
  fi
  code="$(printf '%s' "$raw" | tail -n 1 || true)"
  HTTP_BODY="$(printf '%s' "$raw" | sed '$d' || true)"
  case "$code" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  HTTP_CODE="$code"
  return 0
}

probe_version() {
  # Print the bare version string from GET /api/v4/version (example:
  # "17.1.2"), or return 1 when the answer is missing or misshaped.
  local body ver
  http_fetch "$GITLAB_URL/api/v4/version" "$CURL_CONFIG" || return 1
  if [ "$HTTP_CODE" != "200" ]; then
    return 1
  fi
  body="$HTTP_BODY"
  if [ "$PARSER" = "jq" ]; then
    if ! ver="$(printf '%s' "$body" | jq -r '.version' 2>/dev/null)"; then
      return 1
    fi
  else
    ver="$(printf '%s' "$body" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed -e 's/^"version"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' || true)"
  fi
  if [ -z "$ver" ] || [ "$ver" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$ver"
}

probe_runners() {
  # Print one "id paused" line per runner across all result pages (example:
  # "12 false"). Prints nothing when no runners exist. Returns 1 when the
  # listing fails, a page is misshaped, or paging never ends.
  local url raw clean headers status_line code body ids next pages line id paused all_done shape
  url="$GITLAB_URL/api/v4/runners/all?per_page=100"
  pages=0
  while [ -n "$url" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt 50 ]; then
      return 1
    fi
    if ! raw="$(curl -sS -K "$CURL_CONFIG" --max-time 10 -i "$url" 2>/dev/null)"; then
      return 1
    fi
    clean="$(printf '%s' "$raw" | tr -d '\r' || true)"
    headers="$(printf '%s' "$clean" | sed -n '1,/^$/p' || true)"
    body="$(printf '%s' "$clean" | sed '1,/^$/d' || true)"
    status_line="$(printf '%s' "$headers" | head -n 1 || true)"
    code="${status_line#* }"
    code="${code%% *}"
    if [ "$code" != "200" ]; then
      return 1
    fi
    ids=""
    shape="$(printf '%s' "$body" | tr -d '[:space:]' || true)"
    case "$shape" in
      '['*']') ;;
      *) return 1 ;;
    esac
    if [ "$PARSER" = "jq" ]; then
      if ! ids="$(printf '%s' "$body" | jq -r '.[] | "\(.id) \(.paused)"' 2>/dev/null)"; then
        return 1
      fi
      if [ -n "$ids" ]; then
        line="$(printf '%s\n' "$ids" | grep -vE -e '^[0-9]+ (true|false)$' || true)"
        if [ -n "$line" ]; then
          return 1
        fi
      fi
    else
      all_done="$(printf '%s' "$body" | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+|"paused"[[:space:]]*:[[:space:]]*(true|false)' | tr -d ' \t\r' || true)"
      id=""
      paused=""
      while IFS= read -r line || [ -n "$line" ]; do
        if [ -z "$line" ]; then
          continue
        fi
        if [ -z "$id" ]; then
          case "$line" in
            '"id":'*)
              id="${line#\"id\":}"
              ;;
            *)
              return 1
              ;;
          esac
        else
          case "$line" in
            '"paused":true')
              paused="true"
              ;;
            '"paused":false')
              paused="false"
              ;;
            *)
              return 1
              ;;
          esac
          if [ -n "$ids" ]; then
            ids="$ids
"
          fi
          ids="$ids$id $paused"
          id=""
          paused=""
        fi
      done <<< "$all_done"
      if [ -n "$id" ]; then
        return 1
      fi
    fi
    if [ -n "$ids" ]; then
      printf '%s\n' "$ids"
    fi
    next="$(printf '%s' "$headers" | grep -oE '<[^>]*>;[[:space:]]*rel="next"' | head -n 1 || true)"
    if [ -z "$next" ]; then
      url=""
    else
      next="${next#<}"
      next="${next%%>*}"
      url="$(trim_edge "$next")" || return 1
    fi
  done
  return 0
}

runner_drained() {
  # Print "yes" when a runner has no running jobs, "no" when it has any,
  # or return 1 when the answer is missing or misshaped. Usage: <runner id>.
  local id body stripped
  id="$1"
  http_fetch "$GITLAB_URL/api/v4/runners/$id/jobs?status=running&per_page=1" "$CURL_CONFIG" || return 1
  if [ "$HTTP_CODE" != "200" ]; then
    return 1
  fi
  body="$HTTP_BODY"
  if [ "$PARSER" = "jq" ]; then
    if ! stripped="$(printf '%s' "$body" | jq -r 'if type == "array" then (if length == 0 then "yes" else "no" end) else "bad" end' 2>/dev/null)"; then
      return 1
    fi
    case "$stripped" in
      yes|no)
        printf '%s\n' "$stripped"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi
  stripped="$(printf '%s' "$body" | tr -d '[:space:]' || true)"
  if [ "$stripped" = "[]" ]; then
    printf 'yes\n'
    return 0
  fi
  case "$stripped" in
    '['*']')
      printf 'no\n'
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

set_runner_paused() {
  # Switch one runner paused or unpaused through the API. Usage:
  # set_runner_paused <id> <true|false>. Returns 1 when the API refuses or
  # answers anything but the requested state.
  local id want body val
  id="$1"
  want="$2"
  http_fetch "$GITLAB_URL/api/v4/runners/$id" "$CURL_CONFIG" "paused=$want" || return 1
  if [ "$HTTP_CODE" != "200" ]; then
    return 1
  fi
  body="$HTTP_BODY"
  if [ "$PARSER" = "jq" ]; then
    if ! val="$(printf '%s' "$body" | jq -r '.paused' 2>/dev/null)"; then
      return 1
    fi
  else
    val="$(printf '%s' "$body" | grep -oE '"paused"[[:space:]]*:[[:space:]]*(true|false)' | head -n 1 | tr -d ' \t\r' || true)"
    val="${val#\"paused\":}"
  fi
  if [ "$val" != "$want" ]; then
    return 1
  fi
  return 0
}

fetch_rake_status() {
  # Print the raw batched-migration table from inside the container, or
  # return 1 (logging why) when the call fails.
  local out
  if ! out="$(docker compose -f "$GITLAB_COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" gitlab-rake gitlab:background_migrations:status 2>&1)"; then
    log "$PHASE" "rake status call failed: $(one_line "$out")"
    return 1
  fi
  printf '%s\n' "$out"
}

parse_rake_status() {
  # Check the shape of a rake table and print "finished total" (example:
  # "41 42"). Needs at least one "Database: <name>" banner; every other
  # meaningful line must read "status | detail". Zero rows means clear.
  # Returns 1 on any shape the contract does not allow.
  local text line status rest stripped finished total banners
  text="$1"
  finished=0
  total=0
  banners=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      Database:*)
        rest="${line#Database:}"
        rest="$(trim_edge "$rest")" || return 1
        if [ -z "$rest" ]; then
          return 1
        fi
        banners=$((banners + 1))
        ;;
      *"|"*)
        total=$((total + 1))
        status="${line%%|*}"
        status="$(trim_edge "$status")" || return 1
        rest="${line#*|}"
        rest="$(trim_edge "$rest")" || return 1
        if [ -z "$status" ] || [ -z "$rest" ]; then
          return 1
        fi
        if [ "$status" = "finished" ]; then
          finished=$((finished + 1))
        fi
        ;;
      *)
        stripped="$(printf '%s' "$line" | tr -d '[:space:]' || true)"
        if [ -n "$stripped" ]; then
          return 1
        fi
        ;;
    esac
  done <<< "$text"
  if [ "$banners" -lt 1 ]; then
    return 1
  fi
  printf '%s %s\n' "$finished" "$total"
  return 0
}

probe_hub_tags() {
  # Print every published tag name matching one stop and edition, across
  # all Hub result pages. Usage: probe_hub_tags <major> <minor> <ce|ee>.
  # Prints nothing when no tag matches; returns 1 only when Hub itself
  # cannot be read (single attempt, no retry, no fallback).
  local major minor edition url page names next pages filter_re
  major="$1"
  minor="$2"
  edition="$3"
  filter_re="^$major\\.$minor\\.[0-9]+-$edition\\.0\$"
  url="https://hub.docker.com/v2/repositories/$GITLAB_IMAGE_REPO/tags?name=$major.$minor&page_size=100"
  pages=0
  while [ -n "$url" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt 50 ]; then
      return 1
    fi
    http_fetch "$url" || return 1
    if [ "$HTTP_CODE" != "200" ]; then
      return 1
    fi
    page="$HTTP_BODY"
    case "$page" in
      *'"results"'*)
        ;;
      *)
        return 1
        ;;
    esac
    if [ "$PARSER" = "jq" ]; then
      if ! names="$(printf '%s' "$page" | jq -r --arg re "$filter_re" '.results[].name | select(test($re))' 2>/dev/null)"; then
        return 1
      fi
      if ! next="$(printf '%s' "$page" | jq -r '.next // empty' 2>/dev/null)"; then
        return 1
      fi
    else
      names="$(printf '%s' "$page" | grep -oE "\"name\"[[:space:]]*:[[:space:]]*\"$major\\.$minor\\.[0-9]+-$edition\\.0\"" | sed -e 's/^"name"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' || true)"
      next="$(printf '%s' "$page" | grep -oE '"next"[[:space:]]*:[[:space:]]*("[^"]*"|null)' | head -n 1 | sed -e 's/^"next"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' -e 's/^"next"[[:space:]]*:[[:space:]]*null$//' || true)"
      if [ -n "$next" ]; then
        next="$(trim_edge "$next")" || return 1
      fi
    fi
    if [ -n "$names" ]; then
      printf '%s\n' "$names"
    fi
    url="$next"
  done
  return 0
}

# ---- phases in run order (unbuilt phases halt loudly by design) ----

phase_validate() {
  # Reject bad settings before anything else runs. Checks run in fixed
  # order: lock first, then required names, URL shape, token trim, optional
  # defaults, file checks, edition match. Every problem names every item.
  PHASE="validate"
  GATE="validate"
  local lock_err missing bad_paths url_host trimmed dir_of_script

  log "validate" "run starts, clock captured at epoch $RUN_START"

  if lock_err="$(mkdir "$LOCK_DIR" 2>&1)"; then
    LOCK_HELD=1
  else
    die "validate" "exclusive lock free" "lock held: $LOCK_DIR (${lock_err})" "wait for the other run, or remove a stale lock by hand" "another run holds the lock"
  fi

  missing=""
  [ -n "${GITLAB_URL:-}" ] || missing="$missing GITLAB_URL"
  [ -n "${GITLAB_ADMIN_TOKEN:-}" ] || missing="$missing GITLAB_ADMIN_TOKEN"
  [ -n "${GITLAB_SMOKE_TOKEN:-}" ] || missing="$missing GITLAB_SMOKE_TOKEN"
  [ -n "${GITLAB_COMPOSE_FILE:-}" ] || missing="$missing GITLAB_COMPOSE_FILE"
  [ -n "${COMPOSE_SERVICE:-}" ] || missing="$missing COMPOSE_SERVICE"
  if [ "$SKIP_BACKUP" = "0" ]; then
    [ -n "${BACKUP_PATH:-}" ] || missing="$missing BACKUP_PATH"
  fi
  [ -n "${SEED_PROJECT_PATH:-}" ] || missing="$missing SEED_PROJECT_PATH"
  if [ -n "$missing" ]; then
    die "validate" "all required settings set" "missing:${missing}" "export the missing settings and re-run" "required settings are missing"
  fi

  while [ "${GITLAB_URL%/}" != "$GITLAB_URL" ]; do
    GITLAB_URL="${GITLAB_URL%/}"
  done
  case "$GITLAB_URL" in
    http://*|https://*) ;;
    *)
      die "validate" "URL starting with http:// or https://" "GITLAB_URL=$GITLAB_URL" "fix GITLAB_URL and re-run" "GitLab URL has no web scheme"
      ;;
  esac
  url_host="${GITLAB_URL#http://}"
  url_host="${url_host#https://}"
  url_host="${url_host%%/*}"
  if [ -z "$url_host" ]; then
    die "validate" "URL holding a host name" "GITLAB_URL=$GITLAB_URL" "fix GITLAB_URL and re-run" "GitLab URL has no host"
  fi

  trimmed="$(trim_edge "$GITLAB_ADMIN_TOKEN")" \
    || die "validate" "trimmable admin token" "token trim failed" "re-export GITLAB_ADMIN_TOKEN and re-run" "cannot clean the admin token"
  GITLAB_ADMIN_TOKEN="$trimmed"
  trimmed="$(trim_edge "$GITLAB_SMOKE_TOKEN")" \
    || die "validate" "trimmable smoke token" "token trim failed" "re-export GITLAB_SMOKE_TOKEN and re-run" "cannot clean the smoke token"
  GITLAB_SMOKE_TOKEN="$trimmed"
  if [ -z "$GITLAB_ADMIN_TOKEN" ] || [ -z "$GITLAB_SMOKE_TOKEN" ]; then
    die "validate" "tokens holding more than blank space" "a required token is blank after trim" "re-export both tokens and re-run" "a required token is blank"
  fi

  if [ -z "${GITLAB_IMAGE_REPO:-}" ]; then
    GITLAB_IMAGE_REPO="gitlab/gitlab-ce"
  fi
  if [ -z "${LOG_FILE:-}" ]; then
    LOG_FILE="./upgrade-gitlab.log"
  fi
  if [ -z "${UPGRADE_PATH_FILE:-}" ]; then
    dir_of_script="$(script_dir)" \
      || die "validate" "script folder known" "cannot find the script folder" "pass UPGRADE_PATH_FILE by hand and re-run" "cannot find the script folder"
    UPGRADE_PATH_FILE="$dir_of_script/upgrade_path.yml"
  fi
  touch "$LOG_FILE" \
    || die "validate" "writable log file" "cannot write LOG_FILE=$LOG_FILE" "fix LOG_FILE and re-run" "log file is not writable"

  bad_paths=""
  [ -f "$GITLAB_COMPOSE_FILE" ] || bad_paths="$bad_paths GITLAB_COMPOSE_FILE=$GITLAB_COMPOSE_FILE"
  [ -f "$UPGRADE_PATH_FILE" ] || bad_paths="$bad_paths UPGRADE_PATH_FILE=$UPGRADE_PATH_FILE"
  if [ "$SKIP_BACKUP" = "0" ]; then
    [ -d "${BACKUP_PATH:-}" ] || bad_paths="$bad_paths BACKUP_PATH=${BACKUP_PATH:-}"
  fi
  if [ -n "$bad_paths" ]; then
    die "validate" "all referenced paths exist" "missing:${bad_paths}" "fix the paths and re-run" "referenced files are missing"
  fi

  case "${GITLAB_IMAGE_REPO##*/}" in
    gitlab-ce)
      EXPECTED_EE=0
      ;;
    gitlab-ee)
      EXPECTED_EE=1
      ;;
    *)
      die "validate" "image repo ending in gitlab-ce or gitlab-ee" "GITLAB_IMAGE_REPO=$GITLAB_IMAGE_REPO" "fix GITLAB_IMAGE_REPO and re-run" "image repo names an unknown edition"
      ;;
  esac

  CURL_CONFIG="$(mktemp "${TMPDIR:-/tmp}/upgrade-gitlab-curl.XXXXXX")" \
    || die "validate" "temp token file created" "mktemp failed" "check TMPDIR and re-run" "cannot create the token file"
  chmod 600 "$CURL_CONFIG" \
    || die "validate" "token file readable by owner only" "chmod 600 failed" "check TMPDIR permissions and re-run" "cannot lock down the token file"
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_ADMIN_TOKEN" >"$CURL_CONFIG" \
    || die "validate" "admin token stored outside argv" "cannot write the token file" "check TMPDIR and re-run" "cannot store the admin token"

  if command -v jq >/dev/null 2>&1; then
    PARSER="jq"
  else
    PARSER="grep"
  fi
  export PARSER

  log "validate" "settings ok: url=$GITLAB_URL repo=$GITLAB_IMAGE_REPO service=$COMPOSE_SERVICE json_reader=$PARSER"
  log "validate" "tokens: admin needs the manage_runner right, smoke needs the write_repository right"
}

extract_stops() {
  # Print "M.m|note" lines from the vendored stop file in file order, or
  # return 1 when any line breaks the pinned shape. Allowed lines are blank
  # lines, header notes (#...), the "---" marker, "- major: N", "minor: N",
  # and one "comments: text" per stop, grouped major/minor/[comments].
  local file line major minor note note_seen value bad grep_status count sq
  file="$1"
  sq="'"
  if [ ! -r "$file" ]; then
    return 1
  fi
  bad=""
  grep_status=0
  bad="$(grep -vE -e '^[[:space:]]*$' -e '^#' -e '^---[[:space:]]*$' -e '^ *- major: [0-9]+$' -e '^ *minor: [0-9]+$' -e '^ *comments: .+$' "$file" 2>/dev/null)" || grep_status=$?
  if [ "$grep_status" -gt 1 ]; then
    return 1
  fi
  if [ -n "$bad" ]; then
    value="$(printf '%s' "$bad" | head -n 1 || true)"
    log "$PHASE" "stop file breaks shape at: $(one_line "$value")"
    return 1
  fi
  major=""
  minor=""
  note=""
  note_seen=0
  count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*|'---'*)
        continue
        ;;
      *'major: '*)
        if [ -n "$major" ] && [ -z "$minor" ]; then
          return 1
        fi
        if [ -n "$major" ]; then
          printf '%s.%s|%s\n' "$major" "$minor" "$note"
          count=$((count + 1))
        fi
        major="${line##*major: }"
        minor=""
        note=""
        note_seen=0
        ;;
      *'minor: '*)
        if [ -z "$major" ] || [ -n "$minor" ]; then
          return 1
        fi
        minor="${line##*minor: }"
        ;;
      *'comments: '*)
        if [ -z "$major" ] || [ -z "$minor" ] || [ "$note_seen" = "1" ]; then
          return 1
        fi
        value="${line#*comments: }"
        value="$(trim_edge "$value")" || return 1
        case "$value" in
          '"'*'"')
            value="${value#\"}"
            value="${value%\"}"
            ;;
          "$sq"*"$sq")
            value="${value#$sq}"
            value="${value%$sq}"
            ;;
        esac
        note="$value"
        note_seen=1
        ;;
      *)
        value="$(printf '%s' "$line" | tr -d '[:space:]' || true)"
        if [ -n "$value" ]; then
          return 1
        fi
        ;;
    esac
  done < "$file"
  if [ -n "$major" ] && [ -z "$minor" ]; then
    return 1
  fi
  if [ -n "$major" ]; then
    printf '%s.%s|%s\n' "$major" "$minor" "$note"
    count=$((count + 1))
  fi
  if [ "$count" -lt 1 ]; then
    return 1
  fi
  return 0
}

find_next_stop() {
  # Print the first stop newer than the live version. Usage: find_next_stop
  # <stops text> <live major> <live minor>. Prints "M.m|note", or returns 1
  # when no newer stop exists (already at head). Every stop counts,
  # including ones whose notes call them conditional.
  local stops cmaj cmin entry stop smaj rest smin
  stops="$1"
  cmaj="$2"
  cmin="$3"
  case "$cmaj.$cmin" in
    *[!0-9.]*)
      return 1
      ;;
  esac
  while IFS= read -r entry || [ -n "$entry" ]; do
    if [ -z "$entry" ]; then
      continue
    fi
    stop="${entry%%|*}"
    smaj="${stop%%.*}"
    rest="${stop#*.}"
    smin="${rest%%.*}"
    if [ "$smaj" -gt "$cmaj" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
    if [ "$smaj" -eq "$cmaj" ] && [ "$smin" -gt "$cmin" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done <<< "$stops"
  return 1
}

normalize_version() {
  # Check a raw API version against the expected edition and print the bare
  # X.Y.z (example: "17.1.2-ee" with EE expected prints "17.1.2"). Usage:
  # normalize_version <raw> <1 when EE expected, else 0>. Returns 1 on
  # edition mismatch or unexpected shape.
  local raw want_ee base
  raw="$1"
  want_ee="$2"
  case "$raw" in
    *-ee)
      if [ "$want_ee" != "1" ]; then
        return 1
      fi
      base="${raw%-ee}"
      ;;
    *-ce)
      if [ "$want_ee" != "0" ]; then
        return 1
      fi
      base="${raw%-ce}"
      ;;
    *)
      if [ "$want_ee" != "0" ]; then
        return 1
      fi
      base="$raw"
      ;;
  esac
  if ! printf '%s' "$base" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    return 1
  fi
  printf '%s\n' "$base"
  return 0
}

resolve_plan() {
  # Fill CURRENT_VERSION, TARGET_STOP, TARGET, TARGET_NOTE, and TARGET_IMAGE
  # from the live instance, the stop file, and Hub. Dies GATE=plan on any
  # failure. Shared by the live plan phase and --plan mode so both resolve
  # the same run the same way.
  local raw stops entry stop note smaj smin names pinned edition
  refresh_container
  if [ "$CONTAINER_STATE" != "$COMPOSE_SERVICE:Running" ]; then
    die "plan" "container Running for the version read" "container=$CONTAINER_STATE" "start the instance and re-run" "instance is not running"
  fi
  if ! raw="$(probe_version)"; then
    die "plan" "live version from the version API" "version API unreadable" "check the admin token and the instance log" "cannot read the live version"
  fi
  if ! CURRENT_VERSION="$(normalize_version "$raw" "$EXPECTED_EE")"; then
    die "plan" "version shaped X.Y.z matching the expected edition" "api_version=$raw" "check GITLAB_IMAGE_REPO and the instance" "live version is unusable"
  fi
  if ! stops="$(extract_stops "$UPGRADE_PATH_FILE")"; then
    die "plan" "stop list in the pinned YAML shape" "stop file malformed, see log" "fix $UPGRADE_PATH_FILE and re-run" "stop list is unreadable"
  fi
  smaj="${CURRENT_VERSION%%.*}"
  smin="${CURRENT_VERSION#*.}"
  smin="${smin%%.*}"
  if ! entry="$(find_next_stop "$stops" "$smaj" "$smin")"; then
    die "plan" "a stop newer than the live version" "current=$CURRENT_VERSION is already at head" "no upgrade needed" "already at head, nothing to do"
  fi
  stop="${entry%%|*}"
  note="${entry#*|}"
  TARGET_STOP="$stop"
  TARGET_NOTE="$note"
  smaj="${stop%%.*}"
  smin="${stop#*.}"
  if [ "$EXPECTED_EE" = "1" ]; then
    edition="ee"
  else
    edition="ce"
  fi
  if ! names="$(probe_hub_tags "$smaj" "$smin" "$edition")"; then
    die "plan" "tag list from the Hub tags API" "Hub unreadable for stop $stop" "check the network and re-run" "cannot reach the Hub tags API"
  fi
  if [ -z "$names" ]; then
    die "plan" "at least one published $stop patch tag" "Hub lists no $edition tag for $stop" "check the stop and the repo name" "no patch tag published for this stop"
  fi
  pinned="$(printf '%s\n' "$names" | sort -t. -k3,3n | tail -n 1 || true)"
  TARGET="${pinned%%-*}"
  if ! printf '%s' "$TARGET" | grep -qE "^$smaj\\.$smin\\.[0-9]+$"; then
    die "plan" "pinned tag staying on stop $stop" "pin=$pinned" "re-run; the Hub tag list may have shifted" "pinned tag left its stop"
  fi
  TARGET_IMAGE="$GITLAB_IMAGE_REPO:$pinned"
}

check_app_health() {
  # Prove the app server answers: GET /-/health must read exactly
  # "GitLab OK" while the container runs. Logs the evidence. Returns 1 on
  # any deviation. A refused connection is resolved through container state
  # instead of being read as sickness.
  refresh_container
  if [ "$CONTAINER_STATE" != "$COMPOSE_SERVICE:Running" ]; then
    log "$PHASE" "health check: container is $CONTAINER_STATE, no HTTP probe attempted"
    return 1
  fi
  if ! http_fetch "$GITLAB_URL/-/health"; then
    refresh_container
    log "$PHASE" "health check: connection failed, container now $CONTAINER_STATE"
    return 1
  fi
  if [ "$HTTP_CODE" = "404" ]; then
    log "$PHASE" "health check: 404 while Running reads allowlist-suspect"
    return 1
  fi
  if [ "$HTTP_CODE" != "200" ] || [ "$HTTP_BODY" != "GitLab OK" ]; then
    log "$PHASE" "health check: code=$HTTP_CODE body=$(one_line "$HTTP_BODY")"
    return 1
  fi
  log "$PHASE" "health check: /-/health reads GitLab OK"
  return 0
}

check_health_gem() {
  # Prove one health_check gem page reports success: HTTP 200 with the word
  # "success" in the page. Usage: check_health_gem <path> <label>. The
  # gem's own failure message is logged as evidence. Returns 1 otherwise.
  local path label detail
  path="$1"
  label="$2"
  if ! http_fetch "$GITLAB_URL$path"; then
    refresh_container
    log "$PHASE" "$label: connection failed, container now $CONTAINER_STATE"
    return 1
  fi
  if [ "$HTTP_CODE" = "404" ]; then
    log "$PHASE" "$label: 404 while Running reads allowlist-suspect"
    return 1
  fi
  case "$HTTP_BODY" in
    *success*)
      if [ "$HTTP_CODE" = "200" ]; then
        log "$PHASE" "$label: success"
        return 0
      fi
      ;;
  esac
  detail="$(one_line "$HTTP_BODY")"
  detail="${detail:0:200}"
  log "$PHASE" "$label: code=$HTTP_CODE detail=$detail"
  return 1
}

check_rake_leftover() {
  # Prove no unfinished migrations linger from an earlier stop: the rake
  # table must read all finished (zero rows counts as clear). Logs the
  # counts. Returns 1 when anything is unfinished or the table misshapes.
  local raw counts finished total
  if ! raw="$(fetch_rake_status)"; then
    return 1
  fi
  if ! counts="$(parse_rake_status "$raw")"; then
    log "$PHASE" "leftover check: rake table breaks shape"
    return 1
  fi
  finished="${counts%% *}"
  total="${counts##* }"
  if [ "$finished" != "$total" ]; then
    log "$PHASE" "leftover check: $finished of $total finished, $((total - finished)) unfinished"
    return 1
  fi
  log "$PHASE" "leftover check: $finished of $total finished"
  return 0
}

verify_backup() {
  # Prove the backup artifact exists and is fresh: data/, secrets/, and a
  # BACKUP_CREATED_AT epoch no older than 24 h before this run started.
  # Skips loudly under --nobackup. Returns 1 when the contract breaks.
  local missing created age
  if [ "$SKIP_BACKUP" = "1" ]; then log "$PHASE" "backup verification skipped (--nobackup)"; return 0; fi
  missing=""
  [ -d "$BACKUP_PATH/data" ] || missing="$missing data/"
  [ -d "$BACKUP_PATH/secrets" ] || missing="$missing secrets/"
  [ -f "$BACKUP_PATH/BACKUP_CREATED_AT" ] || missing="$missing BACKUP_CREATED_AT"
  if [ -n "$missing" ]; then log "$PHASE" "backup check: missing under $BACKUP_PATH:$missing"; return 1; fi
  created="$(cat "$BACKUP_PATH/BACKUP_CREATED_AT" 2>/dev/null || true)"
  if ! [ "$created" -eq "$created" ] 2>/dev/null; then log "$PHASE" "backup check: BACKUP_CREATED_AT is not epoch seconds"; return 1; fi
  age=$((RUN_START - created))
  if [ "$age" -gt 86400 ]; then log "$PHASE" "backup check: backup is $age seconds old, older than 24 h"; return 1; fi
  log "$PHASE" "backup check: artifact fresh, $age seconds old"
}

preview_runners() {
  # Report what pausing would touch, without pausing anything: how many
  # runners exist and how many currently hold running jobs. Returns 1 when
  # the listing or a job query fails.
  local list count busy id rest drained
  if ! list="$(probe_runners)"; then
    log "$PHASE" "CI preview: runner listing failed"
    return 1
  fi
  count=0
  busy=0
  while IFS= read -r rest || [ -n "$rest" ]; do
    if [ -z "$rest" ]; then
      continue
    fi
    count=$((count + 1))
    id="${rest%% *}"
    if ! drained="$(runner_drained "$id")"; then
      log "$PHASE" "CI preview: job query failed for runner $id"
      return 1
    fi
    if [ "$drained" = "no" ]; then
      busy=$((busy + 1))
    fi
  done <<< "$list"
  RUNNERS_STATE="$count listed, 0 paused"
  log "$PHASE" "CI preview: would pause $count runners ($busy with running jobs)"
  return 0
}

phase_plan() {
  # Print the one-hop plan and, when the target carries a note, require the
  # operator to type it back exactly before anything may change. A decline
  # exits quietly with zero side effects: nothing has changed yet.
  PHASE="plan"
  GATE="plan"
  local note_trim answer note_log
  resolve_plan
  log "plan" "one-hop plan: current=$CURRENT_VERSION stop=$TARGET_STOP target=$TARGET image=$TARGET_IMAGE"
  note_trim="$(trim_edge "$TARGET_NOTE")" \
    || die "plan" "readable stop note" "note trim failed" "check $UPGRADE_PATH_FILE and re-run" "cannot read the stop note"
  if [ -z "$note_trim" ]; then
    log "plan" "no stop note, no acknowledgement needed"
    return 0
  fi
  log "plan" "stop note: $note_trim"
  if [ ! -t 0 ]; then
    die "plan" "a terminal for acknowledgement" "no TTY on stdin" "re-run from a terminal" "cannot ask for acknowledgement without a terminal"
  fi
  printf 'Type ACK %s to proceed: ' "$TARGET" >&2
  answer=""
  IFS= read -r answer || true
  if [ "$answer" = "ACK $TARGET" ]; then
    note_log="${note_trim:0:200}"
    log "plan" "ack stop=$TARGET at=$(utc_now) note=\"$note_log\""
    return 0
  fi
  log "plan" "operator declined the plan, leaving everything untouched"
  exit 0
}

plan_mode() {
  # Rehearse the run read-only: same resolution as a live run, then every
  # readable pre-pause check, dying in-format on the first failure. Prints
  # the one-hop plan plus the fixed checklist in stable order. Never
  # prompts, never needs a terminal, never changes anything.
  PHASE="plan"
  GATE="plan"
  local note_trim
  resolve_plan
  log "plan" "one-hop plan: current=$CURRENT_VERSION stop=$TARGET_STOP target=$TARGET image=$TARGET_IMAGE"
  note_trim="$(trim_edge "$TARGET_NOTE")" \
    || die "plan" "readable stop note" "note trim failed" "check $UPGRADE_PATH_FILE and re-run" "cannot read the stop note"
  if [ -n "$note_trim" ]; then
    log "plan" "stop note: $note_trim (shown only, never acknowledged in --plan mode)"
  fi
  if check_app_health && check_health_gem "/health_check" "health gem" && preview_runners; then
    log "plan" "check pre-health result=pass"
  else
    die "plan" "readable pre-health checks pass" "pre-health failed, see log" "fix the instance and re-run" "preview pre-health failed"
  fi
  if check_rake_leftover; then
    log "plan" "check pre-migrations-leftover result=pass"
  else
    die "plan" "no leftover unfinished migrations" "leftover check failed, see log" "let migrations finish and re-run" "preview leftover check failed"
  fi
  if verify_backup; then
    if [ "$SKIP_BACKUP" = "1" ]; then
      log "plan" "check pre-backup result=skip detail=--nobackup"
    else
      log "plan" "check pre-backup result=pass"
    fi
  else
    die "plan" "fresh backup artifact present" "backup check failed, see log" "take a fresh backup and re-run" "preview backup check failed"
  fi
  log "plan" "check proceed-version result=pending detail=runs after the container change"
  log "plan" "check proceed-migrations result=pending detail=runs after the container change"
  log "plan" "check proceed-backends result=pending detail=runs after the container change"
  log "plan" "check proceed-readiness result=pending detail=runs after the container change"
  log "plan" "check proceed-smoke-main result=pending detail=runs after the container change"
  log "plan" "check proceed-recheck-unpause result=pending detail=runs after the container change"
  log "plan" "check closeout result=pending detail=runs after the container change"
  log "plan" "preview done, nothing changed"
}

pregate_checks() {
  # Run the four read-only gate checks: app health, backend gem, migration
  # leftover, backup contract. Usage: pregate_checks <wave label for logs>.
  # Runs every check and names each failure (each check logs its own
  # evidence), then returns 1 when any failed so the caller halts once with
  # the full picture. One definition serves both gate waves so they can
  # never drift apart.
  local failed
  failed=""
  check_app_health || failed="$failed health"
  check_health_gem "/health_check" "health gem ($1)" || failed="$failed gem"
  check_rake_leftover || failed="$failed leftover"
  verify_backup || failed="$failed backup"
  if [ -n "$failed" ]; then
    log "$PHASE" "gate checks failed:$failed, see evidence above"
    return 1
  fi
  return 0
}

assert_ci_quiet() {
  # Prove every runner is paused with zero running jobs right now. Logs the
  # first offender. Returns 1 otherwise. Zero runners passes as a no-op.
  local list id paused rest drained
  if ! list="$(probe_runners)"; then
    log "$PHASE" "quiet assert: runner listing failed"
    return 1
  fi
  while IFS= read -r rest || [ -n "$rest" ]; do
    if [ -z "$rest" ]; then
      continue
    fi
    id="${rest%% *}"
    paused="${rest##* }"
    if [ "$paused" != "true" ]; then
      log "$PHASE" "quiet assert: runner $id is not paused"
      return 1
    fi
    if ! drained="$(runner_drained "$id")"; then
      log "$PHASE" "quiet assert: job query failed for runner $id"
      return 1
    fi
    if [ "$drained" != "yes" ]; then
      log "$PHASE" "quiet assert: runner $id still runs jobs"
      return 1
    fi
  done <<< "$list"
  log "$PHASE" "quiet assert: all runners paused and drained"
  return 0
}

phase_pregate() {
  # First half of the pre-gate: prove the instance is healthy, clean, and
  # backed up before CI is touched. Any failure stops here, runners intact.
  PHASE="pre"
  GATE="pre"
  if ! pregate_checks "before pause"; then
    die "pre" "healthy, clean, backed-up instance before CI is touched" "pre-pause checks failed, see log" "fix the instance and re-run" "pre-upgrade gate failed"
  fi
  log "pre" "pre-pause checks pass, CI may be quieted"
}

phase_pause() {
  # Quiet CI: pause every runner, then wait (with waiting lines logged)
  # until zero jobs still run anywhere. No timeout: the wait ends when CI
  # is silent. Only a failed query stops the run; the runner set seen here
  # is the set the drain watches.
  PHASE="pause"
  GATE="pause"
  local list count ids id rest start elapsed running drained
  if ! list="$(probe_runners)"; then
    die "pause" "runner list from the Runners API" "listing failed" "check the admin token and re-run" "cannot list runners"
  fi
  count=0
  ids=""
  while IFS= read -r rest || [ -n "$rest" ]; do
    if [ -z "$rest" ]; then
      continue
    fi
    id="${rest%% *}"
    if ! set_runner_paused "$id" "true"; then
      die "pause" "runner $id paused" "pause call failed for runner $id" "check the token rights and re-run" "cannot pause runner $id"
    fi
    count=$((count + 1))
    ids="$ids $id"
  done <<< "$list"
  if [ "$count" = "0" ]; then
    RUNNERS_STATE="none"
    log "pause" "no runners found, nothing to pause"
  else
    RUNNERS_STATE="$count paused"
    log "pause" "paused $count runners:$ids"
  fi
  start=$SECONDS
  while true; do
    running=0
    while IFS= read -r rest || [ -n "$rest" ]; do
      if [ -z "$rest" ]; then
        continue
      fi
      id="${rest%% *}"
      if ! drained="$(runner_drained "$id")"; then
        die "pause" "job counts from the Runners API" "job query failed for runner $id" "check the API and re-run" "cannot watch the drain"
      fi
      if [ "$drained" = "no" ]; then
        running=$((running + 1))
      fi
    done <<< "$list"
    elapsed=$((SECONDS - start))
    if [ "$running" = "0" ]; then
      log "pause" "drain done, zero running jobs after ${elapsed}s"
      break
    fi
    log "pause" "drain wait elapsed_s=$elapsed running=$running"
    sleep 10 || die "pause" "uninterrupted drain wait" "sleep stopped" "re-run to resume watching" "drain wait broke off"
  done
  if ! assert_ci_quiet; then
    die "pause" "every runner paused with zero running jobs" "CI not fully quiet, see log" "check CI state and re-run" "CI failed to quiet"
  fi
}

phase_pregate_final() {
  # Second half of the pre-gate: after the drain, prove the full set is
  # still green plus CI paused and drained. The last step before the run is
  # allowed to change anything.
  PHASE="pre"
  GATE="pre"
  if ! pregate_checks "after drain"; then
    die "pre" "checks still green after the drain" "post-drain checks failed, see log" "fix the instance and re-run" "final pre-mutate assert failed"
  fi
  if ! assert_ci_quiet; then
    die "pre" "CI paused and drained before any change" "CI not quiet, see log" "check CI state and re-run" "final CI assert failed"
  fi
  log "pre" "pre-gate holds, the instance may be changed"
}

wait_for_startup() {
  # After the container is recreated, wait up to 10 minutes for /-/health
  # to answer. An exited container stops the run at once with its exit code
  # plus the log tail; a restart loop past the window does the same.
  local start elapsed
  start=$SECONDS
  while true; do
    refresh_container
    case "$CONTAINER_STATE" in
      "$COMPOSE_SERVICE:Exited:"*)
        log_exit_evidence
        die "mutate" "container staying up after up -d" "container=$CONTAINER_STATE, log tail above" "fix the crash and re-run" "container exited after recreate"
        ;;
    esac
    if http_fetch "$GITLAB_URL/-/health"; then
      if [ "$HTTP_CODE" = "200" ] && [ "$HTTP_BODY" = "GitLab OK" ]; then
        log "mutate" "startup done, /-/health answers"
        return 0
      fi
    fi
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge 600 ]; then
      case "$CONTAINER_STATE" in
        "$COMPOSE_SERVICE:Exited:"*|"$COMPOSE_SERVICE:Restarting")
          log_exit_evidence
          ;;
      esac
      die "mutate" "/-/health answering within 10 minutes" "container=$CONTAINER_STATE after ${elapsed}s" "inspect the instance and re-run" "startup failed"
    fi
    log "mutate" "startup wait elapsed_s=$elapsed state=$CONTAINER_STATE"
    sleep 10 || die "mutate" "uninterrupted startup wait" "sleep stopped" "re-run to resume watching" "startup wait broke off"
  done
}

phase_mutate() {
  # Move the container to exactly the pinned image: back up the compose
  # file, rewrite the one image line inside the service block, then pull,
  # down, and up -d (never -v, never a retried up). An identical tag still
  # recreates, logged as an idempotent re-run.
  PHASE="mutate"
  GATE="mutate"
  local backup epoch esc matches svc_line svc_text lead svc_indent n line trimmed ind end_line last
  local img_count old_img old_val leading new_line new_val others
  epoch="$(date +%s)" || die "mutate" "timestamp for the backup name" "date failed" "check the system clock and re-run" "cannot stamp the backup"
  backup="$GITLAB_COMPOSE_FILE.bak-$TARGET-$epoch"
  if ! cp "$GITLAB_COMPOSE_FILE" "$backup"; then
    die "mutate" "compose file copied beside itself" "cp failed for $backup" "check file permissions and re-run" "cannot back up the compose file"
  fi
  log "mutate" "compose file backed up to $backup (kept, never auto-restored)"
  esc="$(printf '%s' "$COMPOSE_SERVICE" | sed 's/[^a-zA-Z0-9_]/\\&/g')" \
    || die "mutate" "service name usable in search" "name escape failed" "check COMPOSE_SERVICE and re-run" "cannot search the service block"
  matches="$(grep -cE "^[[:space:]]*$esc:[[:space:]]*(#.*)?$" "$GITLAB_COMPOSE_FILE" || true)"
  if [ "$matches" != "1" ]; then
    die "mutate" "exactly one $COMPOSE_SERVICE block" "blocks found: $matches" "fix the compose file or COMPOSE_SERVICE, restore $backup by hand if needed" "service block is missing or doubled"
  fi
  svc_line="$(grep -nE "^[[:space:]]*$esc:[[:space:]]*(#.*)?$" "$GITLAB_COMPOSE_FILE" | head -n 1 | cut -d: -f1 || true)"
  if [ -z "$svc_line" ]; then
    die "mutate" "service block line known" "block line unreadable" "check the compose file and re-run" "cannot find the service block"
  fi
  svc_text="$(sed -n "${svc_line}p" "$GITLAB_COMPOSE_FILE" || true)"
  lead="${svc_text%%[![:space:]]*}"
  svc_indent=${#lead}
  end_line=""
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -le "$svc_line" ]; then
      continue
    fi
    trimmed="$(printf '%s' "$line" | tr -d '[:space:]' || true)"
    if [ -z "$trimmed" ]; then
      continue
    fi
    if printf '%s' "$line" | grep -qE '^[[:space:]]*#'; then
      continue
    fi
    lead="${line%%[![:space:]]*}"
    ind=${#lead}
    if [ "$ind" -le "$svc_indent" ]; then
      end_line=$n
      break
    fi
  done < "$GITLAB_COMPOSE_FILE"
  if [ -z "$end_line" ]; then
    end_line=$((n + 1))
  fi
  last=$((end_line - 1))
  img_count="$(sed -n "${svc_line},${last}p" "$GITLAB_COMPOSE_FILE" | grep -cE '^[[:space:]]*image:' || true)"
  if [ "$img_count" != "1" ]; then
    die "mutate" "exactly one image: line in the $COMPOSE_SERVICE block" "image lines: $img_count" "fix the compose file, restore $backup by hand if needed" "service image line is missing or doubled"
  fi
  old_img="$(sed -n "${svc_line},${last}p" "$GITLAB_COMPOSE_FILE" | grep -E '^[[:space:]]*image:' || true)"
  old_val="${old_img#*image:}"
  old_val="$(trim_edge "$old_val")" \
    || die "mutate" "readable old image value" "value trim failed" "check the compose file and re-run" "cannot read the old image"
  PREV_IMAGE="$old_val"
  if [ "$old_val" = "$TARGET_IMAGE" ]; then
    log "mutate" "image already $TARGET_IMAGE, idempotent re-run, recreating anyway"
  fi
  leading="${old_img%%image:*}"
  new_line="${leading}image: $TARGET_IMAGE"
  # GNU sed edits the file in place (Linux target); the backup copy above is the undo.
  if ! sed -i "${svc_line},${last}s|^[[:space:]]*image:.*|$new_line|" "$GITLAB_COMPOSE_FILE"; then
    die "mutate" "image line rewritten" "sed failed" "restore $backup by hand and re-run" "cannot rewrite the image line"
  fi
  new_val="$(sed -n "${svc_line},${last}p" "$GITLAB_COMPOSE_FILE" | grep -E '^[[:space:]]*image:' | head -n 1 || true)"
  new_val="${new_val#*image:}"
  new_val="$(trim_edge "$new_val")" || new_val=""
  if [ "$new_val" != "$TARGET_IMAGE" ]; then
    die "mutate" "image line reading $TARGET_IMAGE" "image line reads $new_val" "restore $backup by hand and re-run" "image rewrite did not land"
  fi
  log "mutate" "image pinned to $TARGET_IMAGE"
  others="$(docker compose -f "$GITLAB_COMPOSE_FILE" config --services 2>/dev/null | grep -v -F -x "$COMPOSE_SERVICE" || true)"
  if [ -n "$others" ]; then
    log "mutate" "note: project holds other services, left for the operator: $(one_line "$others")"
  fi
  if ! docker compose -f "$GITLAB_COMPOSE_FILE" pull "$COMPOSE_SERVICE"; then
    die "mutate" "image pulled" "pull failed for $TARGET_IMAGE" "check the tag and the network, restore $backup by hand if needed" "cannot pull the image"
  fi
  log "mutate" "pulled $TARGET_IMAGE"
  if ! docker compose -f "$GITLAB_COMPOSE_FILE" down; then
    die "mutate" "project stopped" "down failed" "check docker state, restore $backup by hand if needed" "cannot stop the project"
  fi
  log "mutate" "project stopped (compose down has no service filter)"
  if ! docker compose -f "$GITLAB_COMPOSE_FILE" up -d "$COMPOSE_SERVICE"; then
    die "mutate" "service started once" "up -d failed, never retried in the down window" "check docker state, restore $backup by hand if needed" "cannot start the service"
  fi
  log "mutate" "service started, waiting for startup"
  wait_for_startup
}

emit_heartbeat() {
  # Write one migration-wait heartbeat line in the exact ordered shape. Each
  # value is quote-stripped first so the inner double quotes always hold.
  # Reads the HB_* record filled by the monitor loop.
  local c m b n line
  c="${HB_CPU//\"/}"
  m="${HB_MEM//\"/}"
  b="${HB_BIO//\"/}"
  n="${HB_NET//\"/}"
  line="$(utc_now) phase=monitor target=$TARGET msg=\"hb elapsed_s=$HB_ELAPSED health=$HB_HEALTH liveness=$HB_LIVE cpu_raw=\"$c\" mem_raw=\"$m\" bio_raw=\"$b\" net_raw=\"$n\" rake_finished=$HB_FIN rake_total=$HB_TOT rake_delta=$HB_DELTA\""
  printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2 || true
  return 0
}

hang_step() {
  # One hang-verdict step. Usage: hang_step <flat so far> <rake delta>
  # <cpu integer or X when unreadable> <block-io same: yes|no>. Prints the
  # new flat count, or HALT when 30 idle beats gather. Only real forward
  # movement resets; anything else needs proof of an idle box to count.
  local flat delta cpu same
  flat="$1"
  delta="$2"
  cpu="$3"
  same="$4"
  if [ "$delta" -gt 0 ]; then
    printf '0\n'
    return 0
  fi
  if [ "$cpu" = "0" ] && [ "$same" = "yes" ]; then
    flat=$((flat + 1))
    if [ "$flat" -ge 30 ]; then
      printf 'HALT\n'
      return 0
    fi
    printf '%s\n' "$flat"
    return 0
  fi
  printf '0\n'
  return 0
}

backend_gate() {
  # Halt at once when an answered backend sub-check is not success. Usage:
  # backend_gate <path> <name>. A refused connection only records a line:
  # dead listeners are judged by the hang verdict, not here.
  local path name detail
  path="$1"
  name="$2"
  if ! http_fetch "$GITLAB_URL$path"; then
    log "monitor" "$name sub-check unreachable this beat, watching on"
    return 0
  fi
  if [ "$HTTP_CODE" = "404" ]; then
    die "monitor" "$name sub-check reachable" "404 while Running, allowlist-suspect" "fix the monitoring allowlist and re-run" "$name check not allowlisted"
  fi
  case "$HTTP_BODY" in
    *success*)
      if [ "$HTTP_CODE" = "200" ]; then
        return 0
      fi
      ;;
  esac
  detail="$(one_line "$HTTP_BODY")"
  detail="${detail:0:200}"
  die "monitor" "$name success through the wait" "$name: code=$HTTP_CODE detail=$detail" "fix $name and re-run" "$name backend failing"
}

phase_monitor() {
  # Watch the migration wait: one heartbeat line every 10 s with app signals
  # plus finished-count deltas, until every batched migration reads finished.
  # Only Running is tolerated; an exited container stops the run with crash
  # evidence. Readiness stays out: it is expected red while migrating.
  PHASE="monitor"
  GATE="monitor"
  local start elapsed state cid stats_line tele_ok bio_same cpu_num cpu_int
  local raw counts finished total delta prev_finished prev_bio flat mig_detail stripped pipes
  start=$SECONDS
  flat=0
  prev_finished=""
  prev_bio=""
  while true; do
    elapsed=$((SECONDS - start))
    refresh_container
    state="$CONTAINER_STATE"
    case "$state" in
      "$COMPOSE_SERVICE:Running")
        ;;
      "$COMPOSE_SERVICE:Exited:"*)
        log_exit_evidence
        die "monitor" "container staying up through the wait" "container=$state, log tail above" "fix the crash and re-run" "container exited mid-wait"
        ;;
      *)
        die "monitor" "container Running through the wait" "container=$state" "inspect docker state and re-run" "container left Running state"
        ;;
    esac
    HB_CPU=""
    HB_MEM=""
    HB_BIO=""
    HB_NET=""
    if cid="$(docker compose -f "$GITLAB_COMPOSE_FILE" ps -q "$COMPOSE_SERVICE" 2>/dev/null)" && [ -n "$cid" ] \
      && stats_line="$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.BlockIO}}|{{.NetIO}}' "$cid" 2>/dev/null)" \
      && [ -n "$stats_line" ]; then
      pipes="$(printf '%s' "$stats_line" | tr -cd '|' || true)"
      if [ "${#pipes}" = "3" ]; then
        IFS='|' read -r HB_CPU HB_MEM HB_BIO HB_NET <<< "$stats_line" || true
      fi
    fi
    if [ -z "$HB_CPU" ] || [ -z "$HB_MEM" ] || [ -z "$HB_BIO" ] || [ -z "$HB_NET" ]; then
      HB_CPU="unknown"
      HB_MEM="unknown"
      HB_BIO="unknown"
      HB_NET="unknown"
      tele_ok=0
      log "monitor" "telemetry unreadable this beat, no hang credit"
    else
      tele_ok=1
    fi
    HB_HEALTH="FAIL"
    if http_fetch "$GITLAB_URL/-/health"; then
      if [ "$HTTP_CODE" = "404" ]; then
        die "monitor" "health endpoint reachable" "404 while Running, allowlist-suspect" "fix the monitoring allowlist and re-run" "health endpoint not allowlisted"
      fi
      if [ "$HTTP_CODE" = "200" ] && [ "$HTTP_BODY" = "GitLab OK" ]; then
        HB_HEALTH="OK"
      fi
    fi
    HB_LIVE="REFUSED"
    if http_fetch "$GITLAB_URL/-/liveness"; then
      if [ "$HTTP_CODE" = "200" ]; then
        stripped="$(printf '%s' "$HTTP_BODY" | tr -d '[:space:]' || true)"
        if [ "$stripped" = '{"status":"ok"}' ]; then
          HB_LIVE="200"
        else
          die "monitor" "liveness shaped 200 plus status ok" "liveness body: $(one_line "$HTTP_BODY")" "inspect the instance and re-run" "liveness body misshaped"
        fi
      elif [ "$HTTP_CODE" = "404" ]; then
        die "monitor" "liveness endpoint reachable" "404 while Running, allowlist-suspect" "fix the monitoring allowlist and re-run" "liveness endpoint not allowlisted"
      else
        die "monitor" "liveness 200" "liveness=$HTTP_CODE" "inspect the instance for deadlocked controllers and re-run" "liveness failing"
      fi
    fi
    backend_gate "/health_check/database" "database"
    backend_gate "/health_check/cache" "cache"
    mig_detail="unreadable"
    if http_fetch "$GITLAB_URL/health_check/migrations"; then
      stripped="$(one_line "$HTTP_BODY")"
      mig_detail="code=$HTTP_CODE ${stripped:0:200}"
    fi
    if ! raw="$(fetch_rake_status)"; then
      die "monitor" "readable migration table every beat" "rake call failed, see log" "check the container and re-run" "migration table unreadable"
    fi
    if ! counts="$(parse_rake_status "$raw")"; then
      die "monitor" "well-shaped migration table" "rake table breaks shape" "check the GitLab version output and re-run" "migration table misshaped"
    fi
    finished="${counts%% *}"
    total="${counts##* }"
    if [ -z "$prev_finished" ]; then
      delta=0
    else
      delta=$((finished - prev_finished))
    fi
    prev_finished="$finished"
    bio_same="no"
    if [ "$tele_ok" = "1" ] && [ -n "$prev_bio" ] && [ "$HB_BIO" = "$prev_bio" ]; then
      bio_same="yes"
    fi
    prev_bio="$HB_BIO"
    cpu_int="X"
    if [ "$tele_ok" = "1" ]; then
      cpu_num="${HB_CPU%\%}"
      cpu_num="$(printf '%s' "$cpu_num" | tr -d ' \t' || true)"
      cpu_num="${cpu_num%%.*}"
      case "$cpu_num" in
        ''|*[!0-9]*) ;;
        *) cpu_int="$cpu_num" ;;
      esac
    fi
    flat="$(hang_step "$flat" "$delta" "$cpu_int" "$bio_same")"
    HB_ELAPSED="$elapsed"
    HB_FIN="$finished"
    HB_TOT="$total"
    HB_DELTA="$delta"
    emit_heartbeat
    log "monitor" "migrations sub-check: $mig_detail (observed only, flat_streak=$flat)"
    if [ "$finished" = "$total" ]; then
      log "monitor" "migrations all finished ($finished of $total), wait ends"
      return 0
    fi
    if [ "$flat" = "HALT" ]; then
      die "monitor" "migration movement or a busy box within 5 minutes" "30 flat beats, finished=$finished/$total, cpu idle, block-io unchanged" "inspect the wedged migration, fix it, re-run" "migration wait hung"
    fi
    sleep 10 || die "monitor" "uninterrupted migration wait" "sleep stopped" "re-run to resume watching" "migration wait broke off"
  done
}

smoke_test() {
  # Prove the instance serves real git use: clone the seed project and push
  # an empty commit to main. The smoke token travels via a one-shot ask
  # helper, never on any command line. Work files are removed after.
  # Returns 1 on any failure.
  local work askpass scheme host seed clone_url out
  work="$(mktemp -d "${TMPDIR:-/tmp}/upgrade-gitlab-smoke.XXXXXX" 2>/dev/null)" || return 1
  askpass="$work/askpass.sh"
  if ! printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$SMOKE_TOKEN_FOR_GIT"\n' >"$askpass"; then
    rm -rf "$work" 2>/dev/null || true
    return 1
  fi
  if ! chmod 700 "$askpass"; then
    rm -rf "$work" 2>/dev/null || true
    return 1
  fi
  scheme="http"
  case "$GITLAB_URL" in
    https://*) scheme="https" ;;
  esac
  host="${GITLAB_URL#http://}"
  host="${host#https://}"
  seed="$SEED_PROJECT_PATH"
  while [ "${seed#/}" != "$seed" ]; do seed="${seed#/}"; done
  while [ "${seed%/}" != "$seed" ]; do seed="${seed%/}"; done
  clone_url="$scheme://oauth2@$host/$seed.git"
  if ! out="$(SMOKE_TOKEN_FOR_GIT="$GITLAB_SMOKE_TOKEN" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
      git clone --depth 1 --branch main "$clone_url" "$work/clone" 2>&1)"; then
    out="$(one_line "$out")"
    log "proceed" "smoke: clone failed: ${out:0:200}"
    rm -rf "$work" 2>/dev/null || true
    return 1
  fi
  if ! out="$(cd "$work/clone" && SMOKE_TOKEN_FOR_GIT="$GITLAB_SMOKE_TOKEN" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
      git -c user.name=upgrade-runner -c user.email=upgrade-runner@localhost commit --allow-empty -m "smoke $TARGET $RUN_START" 2>&1 \
      && SMOKE_TOKEN_FOR_GIT="$GITLAB_SMOKE_TOKEN" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
      git push origin main 2>&1)"; then
    out="$(one_line "$out")"
    log "proceed" "smoke: commit or push failed: ${out:0:200}"
    rm -rf "$work" 2>/dev/null || true
    return 1
  fi
  rm -rf "$work" 2>/dev/null || true
  log "proceed" "smoke: clone and push to $seed main passed"
  return 0
}

unpause_all() {
  # Resume every runner. Runs only on the success path, after step 6's
  # re-check passes. Dies GATE=unpause naming the runner left paused.
  local list count id rest
  GATE="unpause"
  PHASE="unpause"
  if ! list="$(probe_runners)"; then
    die "unpause" "runner list for unpause" "listing failed" "unpause runners by hand" "cannot list runners for unpause"
  fi
  count=0
  while IFS= read -r rest || [ -n "$rest" ]; do
    if [ -z "$rest" ]; then
      continue
    fi
    id="${rest%% *}"
    if ! set_runner_paused "$id" "false"; then
      die "unpause" "runner $id unpaused" "unpause call failed for runner $id" "unpause the rest by hand" "cannot unpause runner $id"
    fi
    count=$((count + 1))
  done <<< "$list"
  RUNNERS_STATE="$count unpaused"
  if [ "$count" = "0" ]; then
    log "unpause" "no runners found, nothing to unpause"
  else
    log "unpause" "unpaused $count runners (pre-existing paused runners resume too)"
  fi
}

phase_proceed() {
  # Prove the stop is done through 6 ordered steps: version, migrations,
  # backends, readiness, smoke, then re-check plus unpause-all. The first
  # failure stops the run; unpause happens only after step 6 passes.
  PHASE="proceed"
  GATE="proceed"
  local raw now counts finished total services
  if ! raw="$(probe_version)"; then
    die "proceed" "live version from the version API" "version API unreadable" "check the instance and re-run" "cannot re-read the version"
  fi
  if ! now="$(normalize_version "$raw" "$EXPECTED_EE")"; then
    die "proceed" "version shaped X.Y.z matching the expected edition" "api_version=$raw" "check the instance and re-run" "version unreadable after the stop"
  fi
  if [ "$now" != "$TARGET" ]; then
    die "proceed" "live version $TARGET" "live version $now" "inspect the container image and re-run" "version does not match the target"
  fi
  log "proceed" "step 1/6: version $now matches $TARGET"
  if ! raw="$(fetch_rake_status)"; then
    die "proceed" "readable migration table" "rake call failed, see log" "check the container and re-run" "migration table unreadable"
  fi
  if ! counts="$(parse_rake_status "$raw")"; then
    die "proceed" "well-shaped migration table" "rake table breaks shape" "check the GitLab version output and re-run" "migration table misshaped"
  fi
  finished="${counts%% *}"
  total="${counts##* }"
  if [ "$finished" != "$total" ]; then
    die "proceed" "every batched migration finished" "finished=$finished/$total" "wait for migrations and re-run" "migrations unfinished"
  fi
  log "proceed" "step 2/6: migrations all finished ($finished of $total)"
  if ! check_health_gem "/health_check" "proceed health"; then
    die "proceed" "full backend stack reporting success" "health gem failed, see log" "fix the backends and re-run" "backend stack failing"
  fi
  log "proceed" "step 3/6: backend stack success"
  if ! http_fetch "$GITLAB_URL/-/readiness?all=1"; then
    refresh_container
    die "proceed" "readiness answer" "connection failed, container now $CONTAINER_STATE" "inspect the instance and re-run" "readiness unreachable"
  fi
  if [ "$HTTP_CODE" = "404" ]; then
    die "proceed" "readiness endpoint reachable" "404 while Running, allowlist-suspect" "fix the monitoring allowlist and re-run" "readiness endpoint not allowlisted"
  fi
  if [ "$HTTP_CODE" != "200" ]; then
    die "proceed" "readiness green (HTTP 200)" "readiness=$HTTP_CODE" "inspect why the instance is not ready and re-run" "readiness failing"
  fi
  services="$(one_line "$HTTP_BODY")"
  log "proceed" "step 4/6: readiness green, services: $services"
  if ! smoke_test; then
    die "proceed" "seeded-project main clone-and-push passing" "smoke test failed, see log" "check project access, then re-run" "smoke test failing"
  fi
  log "proceed" "step 5/6: smoke test passed"
  if ! pregate_checks "before unpause"; then
    die "proceed" "full health green before unpause" "re-check failed, see log" "fix the instance and re-run" "pre-unpause re-check failed"
  fi
  unpause_all
  log "proceed" "step 6/6: re-check passed, CI unpaused"
}

replay_recorded_health() {
  # Copy the readiness and backend lines already in the log into the bundle,
  # so the bundle always carries them. Usage: replay_recorded_health <dir>.
  # Best effort; never stops the run.
  local dir found
  dir="$1"
  found="$(grep -E 'readiness|health check|health gem|backend failing|sub-check' "$LOG_FILE" 2>/dev/null || true)"
  {
    printf 'Recorded health lines replayed from the run log.\n'
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
    else
      printf '(no readiness or backend lines were recorded in this run)\n'
    fi
  } >"$dir/recorded-health.txt" 2>/dev/null || log "$PHASE" "failure bundle: cannot write recorded-health.txt"
  return 0
}

native_bundle() {
  # Collect the fallback evidence set when gitlabsos cannot run: log tail,
  # container detail, replayed health lines, best-effort rake table.
  # Usage: native_bundle <dir>. Best effort; never stops the run.
  local dir cid cid_one out
  dir="$1"
  if out="$(docker compose -f "$GITLAB_COMPOSE_FILE" logs --tail=500 "$COMPOSE_SERVICE" 2>&1)"; then
    printf '%s\n' "$out" >"$dir/compose-logs.txt" 2>/dev/null \
      || log "$PHASE" "failure bundle: cannot write compose-logs.txt"
  else
    log "$PHASE" "failure bundle: service log unreadable"
  fi
  cid="$(docker compose -f "$GITLAB_COMPOSE_FILE" ps -q "$COMPOSE_SERVICE" 2>/dev/null || true)"
  cid_one="$(printf '%s' "$cid" | head -n 1 || true)"
  if [ -n "$cid_one" ] && out="$(docker inspect "$cid_one" 2>&1)"; then
    printf '%s\n' "$out" >"$dir/inspect.json" 2>/dev/null \
      || log "$PHASE" "failure bundle: cannot write inspect.json"
  else
    log "$PHASE" "failure bundle: container inspect unreadable"
  fi
  replay_recorded_health "$dir"
  if out="$(fetch_rake_status)"; then
    printf '%s\n' "$out" >"$dir/rake-status.txt" 2>/dev/null \
      || log "$PHASE" "failure bundle: cannot write rake-status.txt"
  else
    printf 'rake status unreadable at bundle time\n' >"$dir/rake-status.txt" 2>/dev/null || true
  fi
  return 0
}

print_rollback_story() {
  # State the 4-line rollback story: backup source, image revert, restart,
  # unpause as an explicit human action. Log only; never changes anything.
  local img_line
  if [ -n "${BACKUP_PATH:-}" ]; then
    log "$PHASE" "rollback: restore data from the backup at $BACKUP_PATH"
  else
    log "$PHASE" "rollback: no backup path was set, no restore source exists"
  fi
  if [ -n "$PREV_IMAGE" ]; then
    img_line="sed -i 's|^[[:space:]]*image:.*|    image: $PREV_IMAGE|' $GITLAB_COMPOSE_FILE"
    log "$PHASE" "rollback: revert image with: $img_line"
  else
    log "$PHASE" "rollback: no image change was made, nothing to revert"
  fi
  log "$PHASE" "rollback: restart the old image: docker compose -f $GITLAB_COMPOSE_FILE down && docker compose -f $GITLAB_COMPOSE_FILE up -d $COMPOSE_SERVICE"
  log "$PHASE" "rollback: unpause runners by hand (HUMAN-ACTION, never automatic on failure)"
  return 0
}

collect_failure_bundle() {
  # Gather failure evidence into ./failure-bundle-<target>-<epoch>/: the
  # pinned gitlabsos report when fetchable and runnable, else the native
  # manifest, plus the rollback story either way. Runs inside die(), so it
  # is best effort throughout and never stops the run itself.
  local dir epoch sos_file sos_ok cid cid_lines
  epoch="$(date +%s 2>/dev/null || true)"
  if [ -z "$epoch" ]; then
    epoch="$RUN_START"
  fi
  dir="./failure-bundle-${TARGET:-notarget}-$epoch"
  if ! mkdir "$dir" 2>/dev/null; then
    log "$PHASE" "failure bundle: cannot create $dir, evidence stays in the log only"
    print_rollback_story
    return 0
  fi
  log "$PHASE" "failure bundle: collecting into $dir"
  sos_ok=0
  sos_file="$(mktemp "${TMPDIR:-/tmp}/upgrade-gitlab-sos.XXXXXX" 2>/dev/null || true)"
  if [ -n "$sos_file" ]; then
    if curl -sS --max-time 60 -o "$sos_file" "$SOS_URL" 2>/dev/null && [ -s "$sos_file" ]; then
      cid="$(docker compose -f "$GITLAB_COMPOSE_FILE" ps -q "$COMPOSE_SERVICE" 2>/dev/null || true)"
      cid_lines=0
      if [ -n "$cid" ]; then
        cid_lines="$(printf '%s\n' "$cid" | wc -l || true)"
      fi
      if [ "$cid_lines" -eq 1 ] 2>/dev/null; then
        if docker cp "$sos_file" "$cid:/tmp/gitlabsos.rb" >/dev/null 2>&1 \
          && docker compose -f "$GITLAB_COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" /opt/gitlab/embedded/bin/ruby /tmp/gitlabsos.rb -o /tmp/sos >/dev/null 2>&1 \
          && docker cp "$cid:/tmp/sos" "$dir/" >/dev/null 2>&1; then
          sos_ok=1
          log "$PHASE" "failure bundle: gitlabsos report collected"
        fi
      fi
    fi
    rm -f "$sos_file" 2>/dev/null || true
  fi
  if [ "$sos_ok" = "1" ]; then
    replay_recorded_health "$dir"
  else
    log "$PHASE" "failure bundle: gitlabsos path failed, falling back to the native manifest"
    native_bundle "$dir"
  fi
  print_rollback_story
  return 0
}

phase_closeout() {
  # Close the run out: re-prove health, confirm CI resumed, and end green.
  # A broken re-check or a still-paused runner halts like any failure, with
  # bundle plus rollback story. Only the jobs-flowing wait warns instead of
  # dying: the upgrade stands proven by the proceed gate, so a quiet CI must
  # never trigger a rollback story.
  PHASE="closeout"
  GATE="closeout"
  local list count id paused rest drained start elapsed jobs_seen
  if ! pregate_checks "close-out"; then
    die "closeout" "health still green at close-out" "close-out re-check failed, see log" "fix the instance and re-run" "close-out re-check failed"
  fi
  if ! list="$(probe_runners)"; then
    die "closeout" "runner list for the unpause confirm" "listing failed" "confirm CI by hand" "cannot confirm unpause"
  fi
  count=0
  while IFS= read -r rest || [ -n "$rest" ]; do
    if [ -z "$rest" ]; then
      continue
    fi
    id="${rest%% *}"
    paused="${rest##* }"
    if [ "$paused" != "false" ]; then
      die "closeout" "every runner unpaused" "runner $id still paused" "unpause by hand" "unpause did not stick"
    fi
    count=$((count + 1))
  done <<< "$list"
  RUNNERS_STATE="$count unpaused"
  if [ "$count" = "0" ]; then
    log "closeout" "no runners, flow check skipped"
  else
    log "closeout" "$count runners confirmed unpaused, watching for flowing jobs"
    start=$SECONDS
    while true; do
      jobs_seen=0
      while IFS= read -r rest || [ -n "$rest" ]; do
        if [ -z "$rest" ]; then
          continue
        fi
        id="${rest%% *}"
        if ! drained="$(runner_drained "$id")"; then
          die "closeout" "job counts for the flow confirm" "job query failed for runner $id" "check the API and re-run" "cannot confirm flow"
        fi
        if [ "$drained" = "no" ]; then
          jobs_seen=1
        fi
      done <<< "$list"
      if [ "$jobs_seen" = "1" ]; then
        log "closeout" "jobs flowing confirmed"
        break
      fi
      elapsed=$((SECONDS - start))
      if [ "$elapsed" -ge 120 ]; then
        log "closeout" "close-out warning: no jobs flowed within 120 s of unpause"
        log "closeout" "close-out warning: the upgrade stands proven, verify CI by hand"
        break
      fi
      log "closeout" "flow wait elapsed_s=$elapsed, no running jobs yet"
      sleep 10 || die "closeout" "uninterrupted flow wait" "sleep stopped" "confirm CI by hand" "flow wait broke off"
    done
  fi
  log "closeout" "run complete: $CURRENT_VERSION -> $TARGET, runners unpaused"
}

# ---- flag parsing ----

usage() {
  cat <<'HELP'
upgrade-gitlab.sh moves one Docker Compose GitLab exactly one required stop.

Usage:
  GITLAB_URL=... GITLAB_ADMIN_TOKEN=... ... ./upgrade-gitlab.sh [--plan] [--nobackup]

Required settings (environment values):
  GITLAB_URL            web address of this GitLab
  GITLAB_ADMIN_TOKEN    token that may pause runners (needs the manage_runner right)
  GITLAB_SMOKE_TOKEN    token that may push to the seed project (needs the write_repository right)
  GITLAB_COMPOSE_FILE   path to the docker-compose.yml file that runs GitLab
  COMPOSE_SERVICE       service name of GitLab inside that compose file
  BACKUP_PATH           folder holding the backup (may be unset with --nobackup)
  SEED_PROJECT_PATH     project path inside GitLab for the smoke test, e.g. seed/demo

Optional settings (empty counts as unset):
  GITLAB_IMAGE_REPO     image name without tag (default gitlab/gitlab-ce)
  LOG_FILE              file log lines are added to (default ./upgrade-gitlab.log)
  UPGRADE_PATH_FILE     stop list file (default upgrade_path.yml next to this script)

Flags:
  --plan      print the plan and rehearse every readable check, change nothing
  --nobackup  skip backup checks run-wide; the run then has no rollback path
  -h, --help  print this help and exit
HELP
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --plan)
        PLAN_ONLY=1
        ;;
      --nobackup)
        SKIP_BACKUP=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "validate" "known flags only (--plan --nobackup -h --help)" "flag=$arg" "run with --help" "unknown flag"
        ;;
    esac
  done
}

# ---- main: phases run in order, each gate either passes or stops the run ----

main() {
  parse_args "$@"
  phase_validate
  if [ "$PLAN_ONLY" = "1" ]; then
    plan_mode
  else
    phase_plan
    phase_pregate
    phase_pause
    phase_pregate_final
    phase_mutate
    phase_monitor
    phase_proceed
    phase_closeout
  fi
}

main "$@"
