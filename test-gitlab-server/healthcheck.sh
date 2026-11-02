#!/usr/bin/env bash
# Quick health check for the test GitLab server.
# Run: ./test-gitlab-server/healthcheck.sh   (from the repo root)
# Exit 0 = healthy, 1 = something is wrong.
set -eu
cd "$(dirname "$0")"

[ -f .env ] && { set -a; . ./.env; set +a; }
: "${GITLAB_URL:=http://localhost:8080}"

fail=0
check() { # name command...
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'OK    %s\n' "$name"
  else printf 'FAIL  %s\n' "$name"; fail=1; fi
}

if [ -n "$(docker compose ps -q --status running gitlab 2>/dev/null)" ]; then
  printf 'OK    container running\n'
else
  printf 'FAIL  container running\n'; fail=1
fi
# NOTE: the monitoring probes 404 unless the client IP is in monitoring_whitelist
# (see docker-compose.yml). Host-side curls arrive via the Docker bridge
# gateway (172.x), not localhost, so the whitelist must cover 172.16.0.0/12.
check "GET /-/health" curl -sf --max-time 10 "$GITLAB_URL/-/health"
check "GET /-/liveness" curl -sf --max-time 10 "$GITLAB_URL/-/liveness"
check "GET /-/readiness" curl -sf --max-time 10 "$GITLAB_URL/-/readiness"
check "GET /health_check" curl -sf --max-time 10 "$GITLAB_URL/health_check"

if [ -n "${GITLAB_ADMIN_TOKEN:-}" ]; then
  check "API auth (admin token)" curl -sf --max-time 15 \
    -H "PRIVATE-TOKEN: $GITLAB_ADMIN_TOKEN" "$GITLAB_URL/api/v4/user"
else
  printf 'SKIP  API auth (no GITLAB_ADMIN_TOKEN in .env)\n'
fi

[ "$fail" -eq 0 ] && echo "healthy" || echo "unhealthy"
exit "$fail"
