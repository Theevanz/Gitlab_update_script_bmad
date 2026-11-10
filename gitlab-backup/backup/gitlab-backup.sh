#!/usr/bin/env bash
#
# gitlab-backup.sh — one command, one timestamped backup set.
#
# Pipeline: CONFIG + LOCK (pre-pipe gates) then
#   CAPTURE -> BUNDLE -> ENCRYPT -> HASH -> SHIP -> PRUNE.
# Each run seals the native GitLab tarball, the whole config volume, and the
# compose recipe into one age-encrypted blob plus one SHA-256 file, ships both
# to the NAS as a unit, and keeps the newest 2 local sets.
#
# Output grammar (AD-7): START <STAGE> ts=<ts> and DONE lines go to stdout and
# stdout carries nothing else; failures print one FAIL:<STAGE>:ts=<ts>:<detail>
# line to stderr and exit 1. ts=- exactly when the run dies before <ts> exists.
#
# Config: real environment > backup.env file > built-in POC defaults below.
# The script takes no arguments; everything arrives via the 13-variable
# registry (see backup.env.example).
#
# Layout: stage logic lives in exactly one lowercase function per stage
# (capture/bundle/encrypt/hash/ship/prune; CONFIG/LOCK are the pre-pipe gates
# with their own resolve/validate/lock functions). The remaining small
# functions are cross-cutting plumbing shared by every stage: grammar (say_*),
# failure (die), VERBOSE gating (tool), remote execution (ssh_remote), and the
# EXIT/ERR traps. CONFIG's START/DONE lines print after validation, the lock,
# and staging exist, because a config failure must leave stdout empty (Story
# 1.2) and lock contention must report ts=- (Story 1.3).
#
set -euo pipefail
shopt -s nullglob # unmatched globs expand empty so entry counts stay honest

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
TS_RE='^[0-9]{8}-[0-9]{6}$'  # <ts> shape: UTC YYYYMMDD-HHMMSS
AGE_KEY_RE='^age1[0-9a-z]+$' # NAS age recipient line shape
REGISTRY="BACKUP_DIR NAS_HOST NAS_USER NAS_DIR SSH_KEY_FILE AGE_PUBKEY_FILE GITLAB_CONTAINER GITLAB_CONFIG_DIR GITLAB_DATA_DIR COMPOSE_FILE AGE_BIN VERBOSE ENV_FILE"

TS="-"         # run timestamp; assigned once, after the lock is held
CURRENT_STAGE="CONFIG"
FAIL_EMITTED=0 # set by die(); the EXIT trap never prints a second FAIL
SHIP_STARTED=0 # set once SHIP begins; gates remote-staging cleanup
LOCK_FD=""     # flock fd; the kernel releases it on process exit

# --- grammar: stdout carries START/DONE only --------------------------------
say_start() {
  printf 'START %s ts=%s\n' "$CURRENT_STAGE" "$TS"
}

say_done() {
  printf 'DONE %s ts=%s\n' "$CURRENT_STAGE" "$TS"
}

# --- failure: exactly one FAIL line to stderr, then exit 1 ------------------
die() {
  local stage detail
  stage="$1"
  shift
  detail="$*"
  if [ -z "$detail" ]; then
    detail="unspecified failure"
  fi
  printf 'FAIL:%s:ts=%s:%s\n' "$stage" "$TS" "$detail" >&2
  FAIL_EMITTED=1
  exit 1
}

# --- traps: never leave a partial set, never print twice --------------------
on_exit() {
  local rc=$? # one line: a bare `local rc` above would reset $? to 0 and skip cleanup
  trap - ERR
  set +e
  if [ "$rc" -ne 0 ]; then
    # Local staging only — published sets are never touched, by any failure.
    if [ "$TS" != "-" ] && [ -n "${BACKUP_DIR:-}" ]; then
      if [ -d "$BACKUP_DIR/.staging-$TS" ]; then
        rm -rf -- "$BACKUP_DIR/.staging-$TS"
      fi
    fi
    # Remote staging only, best effort — cleanup never masks the original FAIL.
    if [ "$SHIP_STARTED" = 1 ] && [ -n "${NAS_DIR:-}" ] && [ "$TS" != "-" ]; then
      ssh_remote "rm -rf -- '$NAS_DIR/.staging-$TS'" >/dev/null 2>&1 || true
    fi
    if [ "$FAIL_EMITTED" = 0 ]; then
      printf 'FAIL:%s:ts=%s:%s\n' "$CURRENT_STAGE" "$TS" "exiting with status $rc" >&2
    fi
    exit 1
  fi
}

on_err() {
  if [ "$FAIL_EMITTED" = 0 ]; then
    die "$CURRENT_STAGE" "unexpected failure in: ${BASH_COMMAND:-unknown command}"
  fi
  exit 1
}

trap on_exit EXIT
trap on_err ERR

# --- tool: every external call goes through here so stdout stays grammar-only
tool() {
  if [ "${VERBOSE:-0}" = "1" ]; then
    "$@" >&2
  else
    "$@" >/dev/null 2>&1
  fi
}

# --- ssh_remote: key-auth ssh with the same chatter gating as every tool -----
ssh_remote() {
  tool ssh -i "$SSH_KEY_FILE" "$NAS_USER@$NAS_HOST" "$1"
}

# --- config: real env > backup.env file > built-in POC defaults --------------
load_env_file() {
  if [ -z "${ENV_FILE:-}" ]; then
    return 0
  fi
  if [ ! -e "$ENV_FILE" ]; then
    return 0
  fi
  if [ ! -f "$ENV_FILE" ] || [ ! -r "$ENV_FILE" ]; then
    die CONFIG "env file not readable: $ENV_FILE"
  fi
  # Snapshot live values so the file only fills what the environment left empty.
  local -A saved=()
  local v
  for v in $REGISTRY; do
    if [ -n "${!v:-}" ]; then
      saved[$v]="${!v}"
    fi
  done
  set +e
  . "$ENV_FILE"
  local src_rc=$?
  set -e
  if [ "$src_rc" != "0" ]; then
    die CONFIG "cannot load env file: $ENV_FILE"
  fi
  for v in "${!saved[@]}"; do
    printf -v "$v" '%s' "${saved[$v]}"
  done
}

resolve_config() {
  : "${ENV_FILE:=$SCRIPT_DIR/backup.env}"
  load_env_file
  : "${COMPOSE_FILE:=$SCRIPT_DIR/../../test-gitlab-server/docker-compose.yml}"
  local compose_dir
  if [[ "$COMPOSE_FILE" == */* ]]; then
    compose_dir="${COMPOSE_FILE%/*}"
  else
    compose_dir="."
  fi
  # Canonicalize so derived paths carry no /../.. segments; when the dir does
  # not exist yet, keep the raw form and let validate_config fail precisely.
  local compose_abs
  if compose_abs="$(cd -- "$compose_dir" >/dev/null 2>&1 && pwd -P)"; then
    compose_dir="$compose_abs"
    COMPOSE_FILE="$compose_dir/${COMPOSE_FILE##*/}"
  fi
  : "${BACKUP_DIR:=$compose_dir/backups}"
  : "${GITLAB_CONFIG_DIR:=$compose_dir/volumes/config}"
  : "${GITLAB_DATA_DIR:=$compose_dir/volumes/data}"
  : "${SSH_KEY_FILE:=$compose_dir/keys/id_backup_ed25519}"
  : "${AGE_PUBKEY_FILE:=$compose_dir/keys/nas.agepub}"
  : "${GITLAB_CONTAINER:=gitlab}"
  : "${NAS_HOST:=nas}"
  : "${NAS_USER:=backup}"
  : "${NAS_DIR:=/backups/gitlab}"
  : "${AGE_BIN:=$SCRIPT_DIR/vendor/age}"
  : "${VERBOSE:=0}"
  # Export the resolved registry so child processes observe resolved values,
  # not just the caller-provided environment.
  local v
  for v in $REGISTRY; do
    export "$v"
  done
}

validate_config() {
  local v
  for v in $REGISTRY; do
    if [ -z "${!v:-}" ]; then
      die CONFIG "missing required setting: $v"
    fi
  done
  if [ ! -f "$SSH_KEY_FILE" ] || [ ! -r "$SSH_KEY_FILE" ]; then
    die CONFIG "SSH_KEY_FILE not found or unreadable: $SSH_KEY_FILE"
  fi
  if [ ! -f "$AGE_PUBKEY_FILE" ] || [ ! -r "$AGE_PUBKEY_FILE" ]; then
    die CONFIG "AGE_PUBKEY_FILE not found or unreadable: $AGE_PUBKEY_FILE"
  fi
  if [ ! -f "$COMPOSE_FILE" ] || [ ! -r "$COMPOSE_FILE" ]; then
    die CONFIG "compose file not found or unreadable: $COMPOSE_FILE"
  fi
  if [ ! -d "$GITLAB_CONFIG_DIR" ] || [ ! -r "$GITLAB_CONFIG_DIR" ] || [ ! -x "$GITLAB_CONFIG_DIR" ]; then
    die CONFIG "GitLab config dir not accessible: $GITLAB_CONFIG_DIR"
  fi
  if [ ! -d "$GITLAB_DATA_DIR" ] || [ ! -r "$GITLAB_DATA_DIR" ] || [ ! -x "$GITLAB_DATA_DIR" ]; then
    die CONFIG "GitLab data dir not accessible: $GITLAB_DATA_DIR"
  fi
  if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ]; then
    die CONFIG "BACKUP_DIR not writable: $BACKUP_DIR"
  fi
  case "$NAS_DIR" in
  /*) : ;;
  *) die CONFIG "NAS_DIR must be absolute: $NAS_DIR" ;;
  esac
  # The key file holds exactly one age1 recipient line — anything else is a typo.
  local -a key_lines=()
  mapfile -t key_lines <"$AGE_PUBKEY_FILE" || die CONFIG "cannot read age public key: $AGE_PUBKEY_FILE"
  if [ "${#key_lines[@]}" != "1" ]; then
    die CONFIG "age public key must hold exactly one line: $AGE_PUBKEY_FILE"
  fi
  if [[ ! "${key_lines[0]}" =~ $AGE_KEY_RE ]]; then
    die CONFIG "age public key is not a single age1 recipient line: $AGE_PUBKEY_FILE"
  fi
  # Container presence via read-only inspect. No network probes here — an
  # unreachable NAS surfaces later as FAIL:SHIP, not FAIL:CONFIG.
  if ! tool docker inspect "$GITLAB_CONTAINER"; then
    die CONFIG "container not found: $GITLAB_CONTAINER (docker inspect failed)"
  fi
}

# --- lock: single-flight via flock; contention fails before <ts> exists ------
acquire_lock() {
  if ! exec {LOCK_FD}>"$BACKUP_DIR/.lock"; then
    die LOCK "cannot open lock file: $BACKUP_DIR/.lock"
  fi
  # The .lock file itself is never deleted; the kernel releases the lock on exit.
  if ! tool flock -n "$LOCK_FD"; then
    die LOCK "another run holds $BACKUP_DIR/.lock"
  fi
}

# --- preamble: one <ts> per run, one empty hidden staging dir ----------------
assign_ts_and_stage() {
  TS="$(date -u +%Y%m%d-%H%M%S)" || die CONFIG "cannot compute UTC timestamp"
  if [[ ! "$TS" =~ $TS_RE ]]; then
    die CONFIG "clock returned bad timestamp: $TS"
  fi
  if [ -e "$BACKUP_DIR/.staging-$TS" ] || [ -e "$BACKUP_DIR/$TS" ]; then
    die CONFIG "timestamp collision: $TS already exists in $BACKUP_DIR"
  fi
  if ! tool mkdir -- "$BACKUP_DIR/.staging-$TS"; then
    die CONFIG "cannot create staging dir: $BACKUP_DIR/.staging-$TS"
  fi
}

# --- CAPTURE: exactly one native tarball, produced by this run's own create --
capture() {
  local ts staging backup_src
  ts="$1"
  CURRENT_STAGE="CAPTURE"
  say_start
  staging="$BACKUP_DIR/.staging-$ts"
  backup_src="$GITLAB_DATA_DIR/backups"
  if [ ! -d "$backup_src" ]; then
    die CAPTURE "GitLab backups dir not found: $backup_src"
  fi
  # Snapshot first so a stale tarball can never be mistaken for our own output.
  local -a before_files=()
  before_files=("$backup_src"/*_gitlab_backup.tar)
  # The official mechanism; the live data volume is otherwise untouched.
  if ! tool docker exec -t "$GITLAB_CONTAINER" gitlab-backup create STRATEGY=copy; then
    die CAPTURE "gitlab-backup create failed in container $GITLAB_CONTAINER"
  fi
  local -a after_files=()
  after_files=("$backup_src"/*_gitlab_backup.tar)
  local f b seen new_count produced
  new_count=0
  produced=""
  for f in "${after_files[@]}"; do
    seen=0
    for b in "${before_files[@]}"; do
      if [ "$f" = "$b" ]; then
        seen=1
        break
      fi
    done
    if [ "$seen" = 0 ]; then
      produced="$f"
      new_count=$((new_count + 1))
    fi
  done
  if [ "$new_count" != "1" ]; then
    die CAPTURE "expected exactly one new tarball in $backup_src (found $new_count)"
  fi
  # mv reads the finished tarball out of the data bind; that single file is the
  # only thing ever read out of the live volume (cp is outside the toolset).
  if ! tool mv -- "$produced" "$staging/"; then
    die CAPTURE "cannot stage tarball: $produced"
  fi
  local -a staged=()
  staged=("$staging"/*)
  if [ "${#staged[@]}" != "1" ]; then
    die CAPTURE "staging holds ${#staged[@]} files after capture (expected 1)"
  fi
  say_done
}

# stage_copy: copy one member with tar (BUNDLE's domain tool). cp is outside
# the closed utility set, so tar carries every staged copy; the archive bytes
# stay inside the pipe in both modes, so stdout stays grammar-only.
stage_copy() {
  local src_dir member dst_dir
  src_dir="$1"
  member="$2"
  dst_dir="$3"
  if [ "${VERBOSE:-0}" = "1" ]; then
    tar -cf - -C "$src_dir" "$member" | tar -xf - -C "$dst_dir"
  else
    tar -cf - -C "$src_dir" "$member" 2>/dev/null | tar -xf - -C "$dst_dir" 2>/dev/null
  fi
}

# --- BUNDLE: tarball + whole config + recipe -> one set archive --------------
bundle() {
  local ts staging
  ts="$1"
  CURRENT_STAGE="BUNDLE"
  say_start
  staging="$BACKUP_DIR/.staging-$ts"
  local -a tars=()
  tars=("$staging"/*_gitlab_backup.tar)
  if [ "${#tars[@]}" != "1" ]; then
    die BUNDLE "expected exactly one tarball in staging (found ${#tars[@]})"
  fi
  local tarball_base compose_base compose_dir
  tarball_base="${tars[0]##*/}"
  compose_base="${COMPOSE_FILE##*/}"
  if [[ "$COMPOSE_FILE" == */* ]]; then
    compose_dir="${COMPOSE_FILE%/*}"
  else
    compose_dir="."
  fi
  if [ ! -f "$COMPOSE_FILE" ] || [ ! -r "$COMPOSE_FILE" ]; then
    die BUNDLE "compose file vanished mid-run: $COMPOSE_FILE"
  fi
  if [ ! -f "$compose_dir/.env" ]; then
    die BUNDLE "missing .env beside compose file: $compose_dir/.env"
  fi
  if [ ! -r "$compose_dir/.env" ]; then
    die BUNDLE "unreadable .env beside compose file: $compose_dir/.env"
  fi
  if ! tool mkdir -- "$staging/config"; then
    die BUNDLE "cannot create $staging/config"
  fi
  # The config volume is the unit: the whole tree, no file pick-list.
  if ! stage_copy "$GITLAB_CONFIG_DIR" "." "$staging/config"; then
    die BUNDLE "cannot stage config volume from $GITLAB_CONFIG_DIR"
  fi
  if ! stage_copy "$compose_dir" "$compose_base" "$staging"; then
    die BUNDLE "cannot stage compose file: $compose_base"
  fi
  if ! stage_copy "$compose_dir" ".env" "$staging"; then
    die BUNDLE "cannot stage .env"
  fi
  # Every staged copy must be byte-identical to its source.
  if ! tool cmp -s -- "$compose_dir/$compose_base" "$staging/$compose_base"; then
    die BUNDLE "staged copy differs: $compose_base"
  fi
  if ! tool cmp -s -- "$compose_dir/.env" "$staging/.env"; then
    die BUNDLE "staged copy differs: .env"
  fi
  local had_globstar had_dotglob
  had_globstar=0
  had_dotglob=0
  shopt -q globstar && had_globstar=1
  shopt -q dotglob && had_dotglob=1
  shopt -s globstar dotglob
  local f rel
  for f in "$GITLAB_CONFIG_DIR"/**; do
    rel="${f#$GITLAB_CONFIG_DIR/}"
    if [ -d "$f" ] && [ ! -L "$f" ]; then
      if [ ! -d "$staging/config/$rel" ]; then
        die BUNDLE "staged copy differs: config/$rel missing"
      fi
    elif [ -e "$f" ]; then
      if ! tool cmp -s -- "$f" "$staging/config/$rel"; then
        die BUNDLE "staged copy differs: config/$rel"
      fi
    fi
  done
  if [ "$had_globstar" = 0 ]; then
    shopt -u globstar
  fi
  if [ "$had_dotglob" = 0 ]; then
    shopt -u dotglob
  fi
  # Plain tar, relative members, no compression: the set archive.
  if ! (cd "$staging" && tool tar -cf set.tar "$tarball_base" config/ "$compose_base" .env); then
    die BUNDLE "cannot assemble set.tar"
  fi
  say_done
}

# --- ENCRYPT: one age invocation seals the set, then plaintexts are wiped ----
encrypt() {
  local ts staging
  ts="$1"
  CURRENT_STAGE="ENCRYPT"
  say_start
  staging="$BACKUP_DIR/.staging-$ts"
  if [ ! -f "$staging/set.tar" ]; then
    die ENCRYPT "set.tar missing from staging"
  fi
  if ! command -v "$AGE_BIN" >/dev/null 2>&1; then
    die ENCRYPT "age binary not found or not executable: $AGE_BIN"
  fi
  # The single seal: binary age, no armor, cwd inside staging.
  if ! (cd "$staging" && tool "$AGE_BIN" -R "$AGE_PUBKEY_FILE" -o set.tar.age set.tar); then
    die ENCRYPT "age failed to seal set.tar"
  fi
  if [ ! -f "$staging/set.tar.age" ]; then
    die ENCRYPT "age produced no set.tar.age"
  fi
  local -a tars=()
  tars=("$staging"/*_gitlab_backup.tar)
  if [ "${#tars[@]}" != "1" ]; then
    die ENCRYPT "expected exactly one tarball to wipe (found ${#tars[@]})"
  fi
  # Wipe exactly the plaintext set; every rm is checked.
  local compose_base w
  compose_base="${COMPOSE_FILE##*/}"
  local -a wipe=()
  wipe=("${tars[0]}" "$staging/config" "$staging/$compose_base" "$staging/.env" "$staging/set.tar")
  for w in "${wipe[@]}"; do
    if ! tool rm -rf -- "$w"; then
      die ENCRYPT "cannot wipe plaintext: $w"
    fi
  done
  local -a leftovers=()
  leftovers=("$staging"/*)
  if [ "${#leftovers[@]}" != "1" ] || [ ! -f "$staging/set.tar.age" ]; then
    die ENCRYPT "staging holds leftovers after wipe"
  fi
  say_done
}

# --- HASH: one hash over the sealed blob, then atomic publish ----------------
# (Named `hash` per the stage-function contract; it shadows the bash builtin,
# which this script never uses.)
hash() {
  local ts staging
  ts="$1"
  CURRENT_STAGE="HASH"
  say_start
  staging="$BACKUP_DIR/.staging-$ts"
  if [ ! -f "$staging/set.tar.age" ]; then
    die HASH "set.tar.age missing from staging"
  fi
  # Entry gate: HASH owns SHA256SUMS, so the build folder must hold ONLY
  # set.tar.age. A planted leftover or a pre-existing (e.g. corrupt)
  # SHA256SUMS fails here, before anything is written or published.
  local -a staged=()
  staged=("$staging"/*)
  if [ "${#staged[@]}" != "1" ]; then
    die HASH "staging holds ${#staged[@]} entries at entry (expected only set.tar.age)"
  fi
  local -a staged_dots=()
  staged_dots=("$staging"/.*)
  local sd
  for sd in "${staged_dots[@]}"; do
    case "${sd##*/}" in
    . | ..) : ;;
    *) die HASH "unexpected entry in staging: ${sd##*/}" ;;
    esac
  done
  # One line — 64 lowercase hex, two spaces, bare name, newline — written with
  # cwd inside staging. sha256sum's stdout is the hash line (captured to the
  # file, never ours); only its stderr follows the standard VERBOSE gate. The
  # gate dups a saved fd onto stderr: reopening /dev/stderr here would
  # truncate a redirected stderr, while a dup keeps the single hash invocation
  # a single line for the CM-1 counter-metric.
  if [ "${VERBOSE:-0}" = "1" ]; then
    exec 9>&2
  else
    exec 9>/dev/null
  fi
  (cd "$staging" && sha256sum set.tar.age >SHA256SUMS.tmp 2>&9) || die HASH "cannot hash set.tar.age"
  exec 9>&-
  local -a sum_lines=()
  mapfile -t sum_lines <"$staging/SHA256SUMS.tmp" || die HASH "cannot read SHA256SUMS"
  if [ "${#sum_lines[@]}" != "1" ]; then
    die HASH "SHA256SUMS has ${#sum_lines[@]} lines (expected 1)"
  fi
  if [[ ! "${sum_lines[0]}" =~ ^[0-9a-f]{64}"  "set\.tar\.age$ ]]; then
    die HASH "SHA256SUMS malformed"
  fi
  if ! tool mv -- "$staging/SHA256SUMS.tmp" "$staging/SHA256SUMS"; then
    die HASH "cannot write SHA256SUMS"
  fi
  # Publish gate: exactly two entries, named exactly, and self-verified.
  local -a members=()
  members=("$staging"/*)
  if [ "${#members[@]}" != "2" ]; then
    die HASH "staging holds ${#members[@]} entries at publish gate (expected exactly set.tar.age + SHA256SUMS)"
  fi
  if [ ! -f "$staging/set.tar.age" ] || [ ! -f "$staging/SHA256SUMS" ]; then
    die HASH "staging members are not exactly set.tar.age + SHA256SUMS"
  fi
  local -a dots=()
  dots=("$staging"/.*)
  local d
  for d in "${dots[@]}"; do
    case "${d##*/}" in
    . | ..) : ;;
    *) die HASH "unexpected entry in staging: ${d##*/}" ;;
    esac
  done
  if ! (cd "$staging" && tool sha256sum -c SHA256SUMS); then
    die HASH "SHA256SUMS self-verification failed"
  fi
  # One atomic rename publishes the set; already-published sets are never moved.
  if [ -e "$BACKUP_DIR/$ts" ]; then
    die HASH "publish target exists: $ts"
  fi
  if ! (cd "$BACKUP_DIR" && tool mv -- ".staging-$ts" "$ts"); then
    die HASH "cannot publish $ts"
  fi
  say_done
}

# --- SHIP: blob + hash to the NAS as one unit, re-verified before success ----
ship() {
  local ts published remote_staging remote_final
  ts="$1"
  CURRENT_STAGE="SHIP"
  say_start
  published="$BACKUP_DIR/$ts"
  if [ ! -d "$published" ]; then
    die SHIP "published set missing: $published"
  fi
  # Nothing is sent unless the local set still verifies.
  if ! (cd "$published" && tool sha256sum -c SHA256SUMS); then
    die SHIP "local re-verification failed for $ts"
  fi
  SHIP_STARTED=1 # from here the EXIT trap also sweeps remote staging
  remote_staging="$NAS_DIR/.staging-$ts"
  remote_final="$NAS_DIR/$ts"
  # Contents-mirror into remote staging; the trailing slashes carry the
  # contents, not the directory itself.
  if ! tool rsync -a -e "ssh -i $SSH_KEY_FILE" "$published/" "$NAS_USER@$NAS_HOST:$remote_staging/"; then
    die SHIP "rsync to $NAS_HOST failed for $ts"
  fi
  # Presence first, then hash, then the remote rename — in that order.
  if ! ssh_remote "test -f '$remote_staging/set.tar.age' && test -f '$remote_staging/SHA256SUMS'"; then
    die SHIP "missing-member: remote set incomplete in $remote_staging"
  fi
  if ! ssh_remote "(cd '$remote_staging' && sha256sum -c SHA256SUMS)"; then
    die SHIP "hash-mismatch: remote verification failed in $remote_staging"
  fi
  if ! ssh_remote "test ! -e '$remote_final'"; then
    die SHIP "remote set already exists: $remote_final"
  fi
  if ! ssh_remote "mv '$remote_staging' '$remote_final'"; then
    die SHIP "remote publish failed: $remote_staging"
  fi
  say_done
}

# --- PRUNE: newest 2 local sets survive, whole units only ---------------------
prune() {
  local ts
  ts="$1"
  CURRENT_STAGE="PRUNE"
  say_start
  # Dirname sort without `sort` (closed toolset): glob expansion under LC_ALL=C
  # already yields byte order, which is chronological for fixed-format names.
  # The trailing slash matches directories only, so stray files can never be
  # victims; .staging-*, .lock, and non-timestamp names never match either.
  local saved_lc
  saved_lc="${LC_ALL:-}"
  LC_ALL=C
  local -a sets=()
  sets=("$BACKUP_DIR"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]/)
  if [ -n "$saved_lc" ]; then
    LC_ALL="$saved_lc"
  else
    unset LC_ALL
  fi
  local -a victims=()
  local count v
  count="${#sets[@]}"
  if [ "$count" -gt 2 ]; then
    victims=("${sets[@]:0:$((count - 2))}")
  fi
  for v in "${victims[@]}"; do
    if ! tool rm -rf -- "$v"; then
      die PRUNE "cannot remove old set: $v"
    fi
  done
  say_done
}

# --- main: gates, then the six pipe stages in order ---------------------------
main() {
  if [ "$#" != "0" ]; then
    die CONFIG "this script takes no arguments (got $#: $*)"
  fi
  resolve_config
  validate_config
  acquire_lock
  assign_ts_and_stage
  CURRENT_STAGE="CONFIG"
  say_start
  printf 'DONE CONFIG ts=%s BACKUP_DIR=%s\n' "$TS" "$BACKUP_DIR"
  capture "$TS"
  bundle "$TS"
  encrypt "$TS"
  hash "$TS"
  ship "$TS"
  prune "$TS"
}

# Sourcing the script with GITLAB_BACKUP_LIB=1 loads the stage functions without
# running the pipeline, so white-box tests can invoke one stage in isolation.
if [ "${GITLAB_BACKUP_LIB:-0}" != "1" ]; then
  main "$@"
fi
