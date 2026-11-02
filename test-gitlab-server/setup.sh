#!/usr/bin/env bash
# One-command fake GitLab 16.11 seed for the upgrade demo.
# Run: ./test-gitlab-server/setup.sh   (from the repo root)
# Safe to re-run: keeps working tokens and the seed project, refreshes the backup.
set -eu
cd "$(dirname "$0")"

say() { printf '%s\n' "$*"; }
halt() { printf 'SETUP-HALT: %s\n' "$*" >&2; exit 1; }

[ -f .env ] || halt "missing .env — run: cp .env.example .env, then set GITLAB_ROOT_PASSWORD"
set -a
. ./.env
set +a
: "${GITLAB_URL:?set GITLAB_URL in .env}"
case "${GITLAB_ROOT_PASSWORD:-}" in ''|'change-me-before-up') halt "set a real GITLAB_ROOT_PASSWORD in .env";; esac
[ "${#GITLAB_ROOT_PASSWORD}" -ge 8 ] || halt "GITLAB_ROOT_PASSWORD too short (min 8 chars)"
case "$GITLAB_URL" in *":${GITLAB_HTTP_PORT:-8080}/"*|*":${GITLAB_HTTP_PORT:-8080}") ;; *) halt "GITLAB_URL port mismatches GITLAB_HTTP_PORT (${GITLAB_HTTP_PORT:-8080})";; esac

command -v docker >/dev/null 2>&1 || halt "docker CLI not found"
docker compose version >/dev/null 2>&1 || halt "docker compose v2 not found"
command -v curl >/dev/null 2>&1 || halt "curl not found"
command -v git >/dev/null 2>&1 || halt "git not found"
docker info >/dev/null 2>&1 || halt "docker daemon not running"

free_kb=$(df -kP . | awk 'NR==2{print $4}')
[ "${free_kb:-0}" -ge 10485760 ] || halt "need >=10GB free disk, have about $((free_kb / 1024 / 1024))GB"

if [ -n "$(docker compose ps -q 2>/dev/null || true)" ]; then
  say "compose project already exists — skipping port-busy check (docker reports real conflicts on up)"
else
  for p in "${GITLAB_HTTP_PORT:-8080}" "${GITLAB_HTTPS_PORT:-8443}" "${GITLAB_SSH_PORT:-2222}"; do
    case "$p" in ''|*[!0-9]*) halt "bad port '$p' — set numeric GITLAB_*_PORT in .env";; esac
    code=0
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${p}/" 2>/dev/null || code=$?
    [ "$code" -eq 7 ] || halt "port ${p} seems busy (curl exit ${code}) — stop the blocker or override GITLAB_*_PORT in .env"
  done
fi

say "==> compose up (pulls ~1.3GB on first run)"
mkdir -p volumes/config volumes/logs volumes/data
docker compose up -d || halt "compose up failed (pull, ports, or name clash — see docker output above)"

say "==> waiting up to 10 min for first boot"
i=0
# NOTE: the /-/ probes 404 unless the client IP is in monitoring_whitelist
# (see docker-compose.yml). Host-side curls arrive via the Docker bridge
# gateway (172.x), not localhost, so the whitelist must cover 172.16.0.0/12.
until curl -sf --max-time 10 "$GITLAB_URL/-/health" >/dev/null 2>&1 \
  && curl -sf --max-time 10 "$GITLAB_URL/-/liveness" >/dev/null 2>&1 \
  && curl -sf --max-time 10 "$GITLAB_URL/-/readiness" >/dev/null 2>&1 \
  && curl -sf --max-time 10 "$GITLAB_URL/health_check" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then docker compose logs --tail=30 gitlab || true; halt "boot timed out after 10 min (log tail above)"; fi
  sleep 10
done
say "==> healthy"

api() { curl -sf --max-time 15 -H "PRIVATE-TOKEN: $GITLAB_ADMIN_TOKEN" "$@"; }
set_env() {
  esc=$(printf '%s' "$2" | sed 's/[&|\]/\\&/g')
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$esc|" .env
  else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
mk_token() { # name ruby_scopes -> prints plaintext token
  err=$(mktemp /tmp/seed-token.XXXXXX)
  out=$(docker compose exec -T gitlab gitlab-rails runner \
    "u=User.find_by_username!('root'); t=u.personal_access_tokens.create!(name:'$1', scopes:$2, expires_at: 365.days.from_now); puts t.token" \
    2>"$err" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\r ') || true
  if [ -z "${out:-}" ]; then tail -n 5 "$err" >&2; rm -f "$err"; halt "$1 token creation returned empty"; fi
  rm -f "$err"
  printf '%s' "$out"
}

if ! curl -sf --max-time 15 -H "PRIVATE-TOKEN: ${GITLAB_ADMIN_TOKEN:-x}" "$GITLAB_URL/api/v4/runners/all?per_page=1" >/dev/null 2>&1; then
  say "==> creating admin token"
  GITLAB_ADMIN_TOKEN=$(mk_token seed-admin '[:api]')
  set_env GITLAB_ADMIN_TOKEN "$GITLAB_ADMIN_TOKEN"
fi
if ! curl -sf --max-time 15 -H "PRIVATE-TOKEN: ${GITLAB_SMOKE_TOKEN:-x}" "$GITLAB_URL/api/v4/user" >/dev/null 2>&1; then
  say "==> creating smoke token"
  GITLAB_SMOKE_TOKEN=$(mk_token seed-smoke '[:read_repository, :write_repository]')
  set_env GITLAB_SMOKE_TOKEN "$GITLAB_SMOKE_TOKEN"
fi

say "==> seed group + project"
api -X POST "$GITLAB_URL/api/v4/groups" --data-urlencode "name=seed" --data-urlencode "path=seed" >/dev/null 2>&1 \
  || api "$GITLAB_URL/api/v4/groups/seed" >/dev/null 2>&1 \
  || halt "cannot create or find group 'seed'"
GID=$(api "$GITLAB_URL/api/v4/groups/seed" | grep -o '"id":[0-9][0-9]*' | head -n 1 | grep -o '[0-9][0-9]*')
[ -n "${GID:-}" ] || halt "group 'seed' has no id"
if ! api "$GITLAB_URL/api/v4/projects/seed%2Fdemo" >/dev/null 2>&1; then
  api -X POST "$GITLAB_URL/api/v4/projects" \
    -d "name=demo&path=demo&namespace_id=$GID&initialize_with_readme=true&default_branch=main" >/dev/null \
    || halt "cannot create project seed/demo"
fi
CI_FILE="$GITLAB_URL/api/v4/projects/seed%2Fdemo/repository/files/.gitlab-ci.yml"
CI_CONTENT='stages: [test]
smoke:
  stage: test
  script: ["echo fake-ci-ok"]
'
if ! api -X POST "$CI_FILE" --data-urlencode "branch=main" --data-urlencode "content=$CI_CONTENT" --data-urlencode "commit_message=seed ci" >/dev/null 2>&1; then
  api -X PUT "$CI_FILE" --data-urlencode "branch=main" --data-urlencode "content=$CI_CONTENT" --data-urlencode "commit_message=seed ci" >/dev/null 2>&1 \
    || halt "cannot write .gitlab-ci.yml to seed/demo"
fi

say "==> smoke clone + push as the runner will"
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
AUTH_URL=$(printf '%s' "$GITLAB_URL" | sed "s|://|://oauth2:${GITLAB_SMOKE_TOKEN}@|")
redact() { [ -f "$1" ] || return 0; sed "s|oauth2:[^@]*@|oauth2:REDACTED@|g" "$1" | tail -n 3 >&2; }
git clone -q "$AUTH_URL/seed/demo.git" "$PROBE/demo" 2>"$PROBE/clone.err" || { redact "$PROBE/clone.err"; halt "smoke clone failed"; }
(cd "$PROBE/demo" && git -c user.email=seed@local -c user.name=seed commit -q --allow-empty -m probe \
  && git push -q origin main 2>"$PROBE/push.err") || { redact "$PROBE/push.err"; halt "smoke push failed"; }
rm -rf "$PROBE"
trap - EXIT

say "==> hand-made backup (stated, not hidden)"
NOW=$(date +%s)
CREATED=$(cat backups/latest/BACKUP_CREATED_AT 2>/dev/null || echo 0)
case "$CREATED" in ''|*[!0-9]*) CREATED=0;; esac
if [ $((NOW - CREATED)) -le 86400 ] && [ -d backups/latest/data ] && [ -d backups/latest/secrets ]; then
  say "backup still fresh, keeping it"
else
  BDIR="backups/$NOW"
  mkdir -p "$BDIR/data" "$BDIR/secrets"
  printf 'hand-made fake backup for the demo (stated, not hidden)\n' > "$BDIR/data/README"
  cp .env.example "$BDIR/secrets/env.example"
  printf '%s' "$NOW" > "$BDIR/BACKUP_CREATED_AT"
  ln -sfn "$NOW" backups/latest
fi

say "==> seed complete. Paste into the demo shell:"
ABS=$(pwd)
printf 'export GITLAB_URL=%q\nexport GITLAB_ADMIN_TOKEN=%q\nexport GITLAB_SMOKE_TOKEN=%q\nexport GITLAB_COMPOSE_FILE=%q\nexport COMPOSE_SERVICE=gitlab\nexport BACKUP_PATH=%q\nexport SEED_PROJECT_PATH=seed/demo\n' \
  "$GITLAB_URL" "$GITLAB_ADMIN_TOKEN" "$GITLAB_SMOKE_TOKEN" "$ABS/docker-compose.yml" "$ABS/backups/latest"
