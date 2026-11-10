#!/usr/bin/env bash
# Regression for the integrated backup gate: newest complete set wins, age
# 0..86400 s passes (exact bounds pinned under a frozen clock), anything
# else counts as missing or stale; live first wave produces once then
# re-checks (an anomalous newest fails closed even after produce), every
# other wave and --plan check only, --nobackup skips loudly; the producer
# runs zero-arg with BACKUP_DIR and ENV_FILE pinned. Sources the real
# runner for the gate cases and runs stubbed subprocesses for validate plus
# --plan end-to-end. No Docker needed. Exit 0 when every case passes, 1
# otherwise.
set -u
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")"
RUNNER="$PWD/upgrade-gitlab.sh"
REPO="$(dirname "$PWD")"
T=$(mktemp -d /tmp/backupgate.XXXXXX)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS: %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }

# ---- gate suite: sourced runner, fixture BACKUP_PATH dirs ----
LOG=$T/test.log
# shellcheck disable=SC1090
. "$RUNNER"
PHASE="pre"
LOG_FILE="$LOG"
: >"$LOG"

mkset() { # <root> <ts> [missing-member]
  mkdir -p "$1/$2"
  [ "${3:-}" = "noage" ] || : >"$1/$2/set.tar.age"
  [ "${3:-}" = "nosum" ] || : >"$1/$2/SHA256SUMS"
}

fake_producer() { # <path-to-write> <mode: ok|fail>
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$((\$(cat "$T/count" 2>/dev/null || echo 0) + 1))" >"$T/count"
[ "\$#" = "0" ] || { echo "FAIL:CONFIG:ts=-:got args" >&2; exit 1; }
[ -n "\${BACKUP_DIR:-}" ] || { echo "FAIL:CONFIG:ts=-:no BACKUP_DIR" >&2; exit 1; }
[ -n "\${ENV_FILE:-}" ] || { echo "FAIL:CONFIG:ts=-:no ENV_FILE" >&2; exit 1; }
if [ "$2" = "fail" ]; then echo "FAIL:SHIP:ts=-:boom" >&2; exit 1; fi
if [ "$2" = "empty" ]; then echo "START CONFIG ts=20261110-000000"; echo "DONE CONFIG ts=20261110-000000"; exit 0; fi
ts=\$(date -u +%Y%m%d-%H%M%S); mkdir -p "\$BACKUP_DIR/\$ts"
: >"\$BACKUP_DIR/\$ts/set.tar.age"; : >"\$BACKUP_DIR/\$ts/SHA256SUMS"
echo "START CONFIG ts=\$ts"; echo "DONE CONFIG ts=\$ts"
exit 0
EOF
  chmod +x "$1"
}

reset() { # <root>
  rm -rf "$1"; mkdir -p "$1"; rm -f "$T/count"; : >"$LOG"
  BACKUP_PATH="$1"; SKIP_BACKUP=0; PLAN_ONLY=0
  BACKUP_SCRIPT="$T/producer-ok.sh"; BACKUP_ENV_FILE="$T/backup.env"
  : >"$T/backup.env"
}
runs() { cat "$T/count" 2>/dev/null || echo 0; }

fake_producer "$T/producer-ok.sh" ok
fake_producer "$T/producer-fail.sh" fail

NOW_TS=$(date -u +%Y%m%d-%H%M%S)
STALE_TS=$(date -u -d '25 hours ago' +%Y%m%d-%H%M%S)
FUTURE_TS=$(date -u -d '1 hour' +%Y%m%d-%H%M%S)

fake_producer "$T/producer-empty.sh" empty

# Strict producer: asserts the exact invocation contract (zero args plus
# pinned BACKUP_DIR and ENV_FILE) instead of only non-empty values.
cat >"$T/producer-strict.sh" <<'EOF'
#!/usr/bin/env bash
[ "$#" = "0" ] || { echo "FAIL:CONFIG:ts=-:got args" >&2; exit 1; }
[ "${BACKUP_DIR:-}" = "${EXPECTED_BACKUP_DIR:-__unset__}" ] || { echo "FAIL:CONFIG:ts=-:BACKUP_DIR not pinned" >&2; exit 1; }
[ "${ENV_FILE:-}" = "${EXPECTED_ENV_FILE:-__unset__}" ] || { echo "FAIL:CONFIG:ts=-:ENV_FILE not pinned" >&2; exit 1; }
ts=$(date -u +%Y%m%d-%H%M%S); mkdir -p "$BACKUP_DIR/$ts"
: >"$BACKUP_DIR/$ts/set.tar.age"; : >"$BACKUP_DIR/$ts/SHA256SUMS"
echo "START CONFIG ts=$ts"; echo "DONE CONFIG ts=$ts"
exit 0
EOF
chmod +x "$T/producer-strict.sh"

# Frozen clock for the exact freshness bounds: only a bare `date +%s`
# (the gate's check-time read) is pinned; every other date call, including
# timestamp parsing and log stamps, delegates to the real binary.
mkdir -p "$T/fakebin"
REAL_DATE="$(command -v date)"
export REAL_DATE
cat >"$T/fakebin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$#" = "1" ] && [ "$1" = "+%s" ]; then printf '%s\n' "$FAKE_NOW"; exit 0; fi
exec "$REAL_DATE" "$@"
EOF
chmod +x "$T/fakebin/date"
FAKE_NOW=$(date +%s)
export FAKE_NOW
TS_EDGE_PASS=$(date -u -d "@$((FAKE_NOW - 86400))" +%Y%m%d-%H%M%S)
TS_EDGE_FAIL=$(date -u -d "@$((FAKE_NOW - 86401))" +%Y%m%d-%H%M%S)

# 1. fresh passes, no producer run
reset "$T/r1"; mkset "$T/r1" "$NOW_TS"
verify_backup "produce" && ok "1 fresh passes" || bad "1 fresh passes"
[ "$(runs)" = "0" ] && ok "1 no producer run" || bad "1 no producer run"
grep -q "fresh, .*s old" "$LOG" && ok "1 logs fresh age" || bad "1 logs fresh age"

# 2. missing -> produce once -> pass
reset "$T/r2"
verify_backup "produce" && ok "2 missing produce passes" || bad "2 missing produce passes"
[ "$(runs)" = "1" ] && ok "2 producer ran once" || bad "2 producer ran once (got $(runs))"
grep -q "re-check passes after producer run" "$LOG" && ok "2 re-check logged" || bad "2 re-check logged"

# 3. stale -> produce once -> pass
reset "$T/r3"; mkset "$T/r3" "$STALE_TS"
verify_backup "produce" && ok "3 stale produce passes" || bad "3 stale produce passes"
[ "$(runs)" = "1" ] && ok "3 producer ran once" || bad "3 producer ran once (got $(runs))"
grep -q "stale: newest set $STALE_TS" "$LOG" && ok "3 names stale" || bad "3 names stale"

# 4. legacy-only (epoch dir + latest symlink) counts as missing -> produce
reset "$T/r4"; mkdir -p "$T/r4/1793610538/data" "$T/r4/1793610538/secrets"
echo 1 >"$T/r4/1793610538/BACKUP_CREATED_AT"; ln -s 1793610538 "$T/r4/latest"
verify_backup "produce" && ok "4 legacy produce passes" || bad "4 legacy produce passes"
grep -q "missing: no complete backup set" "$LOG" && ok "4 legacy counts missing" || bad "4 legacy counts missing"

# 5. incomplete set (one member) counts as missing
reset "$T/r5"; mkset "$T/r5" "$NOW_TS" nosum
verify_backup "check" && bad "5 incomplete fails" || ok "5 incomplete fails"
[ "$(runs)" = "0" ] && ok "5 check-only no run" || bad "5 check-only no run"
grep -q "missing: no complete backup set" "$LOG" && ok "5 incomplete counts missing" || bad "5 incomplete counts missing"

# 6. future ts fails as stale in check mode, no produce
reset "$T/r6"; mkset "$T/r6" "$FUTURE_TS"
verify_backup "check" && bad "6 future fails" || ok "6 future fails"
grep -q "in the future" "$LOG" && ok "6 future named" || bad "6 future named"
[ "$(runs)" = "0" ] && ok "6 no run" || bad "6 no run"

# 7. plan mode missing: no run, would-run logged, cause names missing
reset "$T/r7"; PLAN_ONLY=1
verify_backup "check" && bad "7 plan fails" || ok "7 plan fails"
[ "$(runs)" = "0" ] && ok "7 plan no run" || bad "7 plan no run"
grep -q "would run the backup producer once" "$LOG" && ok "7 would-run logged" || bad "7 would-run logged"
case "${BACKUP_FAIL_CAUSE:-}" in missing:*) ok "7 cause names missing";; *) bad "7 cause names missing ($BACKUP_FAIL_CAUSE)";; esac

# 7b. plan mode ignores produce mode (double guard)
reset "$T/r7b"; PLAN_ONLY=1
verify_backup "produce" && bad "7b plan+produce fails" || ok "7b plan+produce fails"
[ "$(runs)" = "0" ] && ok "7b plan+produce no run" || bad "7b plan+produce no run"

# 8. nobackup: loud skip, no check, no run (even empty root)
reset "$T/r8"; SKIP_BACKUP=1
verify_backup "produce" && ok "8 nobackup passes" || bad "8 nobackup passes"
[ "$(runs)" = "0" ] && ok "8 no run" || bad "8 no run"
grep -q "skipped (--nobackup)" "$LOG" && ok "8 loud skip" || bad "8 loud skip"

# 9. producer failure: fail, exactly one attempt, no retry
reset "$T/r9"; BACKUP_SCRIPT="$T/producer-fail.sh"
verify_backup "produce" && bad "9 producer-fail fails" || ok "9 producer-fail fails"
[ "$(runs)" = "1" ] && ok "9 exactly one attempt" || bad "9 exactly one attempt (got $(runs))"
grep -q "producer run failed" "$LOG" && ok "9 failure logged" || bad "9 failure logged"
grep -q "FAIL:SHIP" "$LOG" && ok "9 FAIL line captured" || bad "9 FAIL line captured"

# 10. newest-complete selection: newer incomplete ignored, older fresh used
reset "$T/r10"; mkset "$T/r10" "$NOW_TS"; mkset "$T/r10" "$FUTURE_TS" nosum
verify_backup "check" && ok "10 picks newest complete" || bad "10 picks newest complete"

# 11. unparsable ts (matches shape, not a date) counts as missing
reset "$T/r11"; mkset "$T/r11" "20261345-999999"
verify_backup "check" && bad "11 bad-ts fails" || ok "11 bad-ts fails"
grep -q "unparsable timestamp" "$LOG" && ok "11 bad-ts named" || bad "11 bad-ts named"

# 12. newest_backup_set empty root returns 1
reset "$T/r12"
newest_backup_set >/dev/null 2>&1 && bad "12 empty root" || ok "12 empty root"

# 13. produce late in a run still passes the re-check (RUN_START backdated 5 min)
reset "$T/r13"
RUN_START=$((RUN_START - 300))
verify_backup "produce" && ok "13 late produce passes" || bad "13 late produce passes"
[ "$(runs)" = "1" ] && ok "13 producer ran once" || bad "13 producer ran once (got $(runs))"

# 14. future complete shadows older fresh: newest-only, no fallback
reset "$T/r14"; mkset "$T/r14" "$NOW_TS"; mkset "$T/r14" "$FUTURE_TS"
verify_backup "check" && bad "14 shadow fails" || ok "14 shadow fails"
grep -q "in the future" "$LOG" && ok "14 future named" || bad "14 future named"
[ "$(runs)" = "0" ] && ok "14 no run" || bad "14 no run"

# 15. stale in live check-only mode (late wave): fails, no produce
reset "$T/r15"; mkset "$T/r15" "$STALE_TS"
verify_backup "check" && bad "15 stale check fails" || ok "15 stale check fails"
[ "$(runs)" = "0" ] && ok "15 no run" || bad "15 no run"
grep -q "stale: newest set $STALE_TS" "$LOG" && ok "15 names stale" || bad "15 names stale"

# 16. missing in live check-only mode (late wave): fails, no produce
reset "$T/r16"
verify_backup "check" && bad "16 missing check fails" || ok "16 missing check fails"
[ "$(runs)" = "0" ] && ok "16 no run" || bad "16 no run"
grep -q "missing: no complete backup set" "$LOG" && ok "16 names missing" || bad "16 names missing"

# 17. future in produce mode: runs once, re-check still fails closed
reset "$T/r17"; mkset "$T/r17" "$FUTURE_TS"
verify_backup "produce" && bad "17 future produce fails" || ok "17 future produce fails"
[ "$(runs)" = "1" ] && ok "17 producer ran once" || bad "17 producer ran once (got $(runs))"
grep -q "in the future" "$LOG" && ok "17 future named" || bad "17 future named"
grep -q "re-check passes after producer run" "$LOG" && bad "17 no re-check pass" || ok "17 no re-check pass"

# 18. producer exits 0 but creates no set: re-check fails, one attempt
reset "$T/r18"; BACKUP_SCRIPT="$T/producer-empty.sh"
verify_backup "produce" && bad "18 empty produce fails" || ok "18 empty produce fails"
[ "$(runs)" = "1" ] && ok "18 exactly one attempt" || bad "18 exactly one attempt (got $(runs))"
grep -q "missing: no complete backup set" "$LOG" && ok "18 re-check names missing" || bad "18 re-check names missing"
grep -q "re-check passes after producer run" "$LOG" && bad "18 no re-check pass" || ok "18 no re-check pass"

# 19. producer receives pinned BACKUP_DIR and ENV_FILE plus zero args
reset "$T/r19"
export EXPECTED_BACKUP_DIR="$T/r19" EXPECTED_ENV_FILE="$T/backup.env"
BACKUP_SCRIPT="$T/producer-strict.sh"
verify_backup "produce" && ok "19 strict pin passes" || bad "19 strict pin passes"
grep -q "re-check passes after producer run" "$LOG" && ok "19 re-check logged" || bad "19 re-check logged"

# 20. exactly 86400s old passes (frozen clock, inclusive bound)
reset "$T/r20"; mkset "$T/r20" "$TS_EDGE_PASS"
PATH="$T/fakebin:$PATH" verify_backup "check" && ok "20 edge 86400 passes" || bad "20 edge 86400 passes"
grep -q "fresh, 86400s old" "$LOG" && ok "20 exact age logged" || bad "20 exact age logged"

# 21. exactly 86401s old fails as stale (frozen clock, exclusive bound)
reset "$T/r21"; mkset "$T/r21" "$TS_EDGE_FAIL"
PATH="$T/fakebin:$PATH" verify_backup "check" && bad "21 edge 86401 fails" || ok "21 edge 86401 fails"
grep -q "86401s old, older than 24 h" "$LOG" && ok "21 exact age named" || bad "21 exact age named"

# ---- validate suite: subprocess tests for producer paths + stubbed --plan ----
base_env() { # prints common env assignments; caller adds the rest
  printf 'GITLAB_URL=http://fake.invalid GITLAB_ADMIN_TOKEN=tok1 GITLAB_SMOKE_TOKEN=tok2 '
  printf 'GITLAB_COMPOSE_FILE=%s COMPOSE_SERVICE=gitlab SEED_PROJECT_PATH=seed/demo ' "$REPO/test-gitlab-server/docker-compose.yml"
}

run_case() { # <name> <workdir> <extra-env...> -- <args...>
  local name=$1 wd=$2; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  mkdir -p "$wd"; ( cd "$wd" && env $(base_env) "${envs[@]}" LOG_FILE="$wd/run.log" bash "$RUNNER" "$@" >"$wd/out.txt" 2>&1; echo "$?" >"$wd/rc" )
}

# V1: defaults resolve, validate passes (dies later at plan container check)
mkdir -p "$T/v1/backups"
run_case v1 "$T/v1" BACKUP_PATH="$T/v1/backups" -- --plan
[ "$(cat $T/v1/rc)" = "1" ] && grep -q "GATE='plan'" "$T/v1/run.log" && ok "V1 validate passes with defaults" || bad "V1 validate passes with defaults"
grep -q "backup producer: script=.*gitlab-backup/backup/gitlab-backup.sh" "$T/v1/run.log" && ok "V1 default script logged" || bad "V1 default script logged"

# V2: bogus BACKUP_SCRIPT dies at validate naming it
mkdir -p "$T/v2/backups"
run_case v2 "$T/v2" BACKUP_PATH="$T/v2/backups" BACKUP_SCRIPT=/nonexistent/producer.sh -- --plan
grep -q "GATE='validate'.*BACKUP_SCRIPT=/nonexistent/producer.sh" "$T/v2/run.log" && ok "V2 bogus script dies at validate" || bad "V2 bogus script dies at validate"

# V3: missing BACKUP_ENV_FILE passes validate with fallback log
mkdir -p "$T/v3/backups"
run_case v3 "$T/v3" BACKUP_PATH="$T/v3/backups" BACKUP_ENV_FILE="$T/v3/no-such.env" -- --plan
grep -q "GATE='plan'" "$T/v3/run.log" && ok "V3 missing env file passes validate" || bad "V3 missing env file passes validate"
grep -q "falls back to environment" "$T/v3/run.log" && ok "V3 fallback logged" || bad "V3 fallback logged"

# V4: --nobackup skips all backup validation (no BACKUP_PATH, bogus script)
run_case v4 "$T/v4" BACKUP_SCRIPT=/nonexistent/producer.sh -- --plan --nobackup
grep -q "GATE='plan'" "$T/v4/run.log" && ok "V4 nobackup skips validation" || bad "V4 nobackup skips validation"

# V5: BACKUP_ENV_FILE present-but-a-directory dies at validate
mkdir -p "$T/v5/backups" "$T/v5/asdir"
run_case v5 "$T/v5" BACKUP_PATH="$T/v5/backups" BACKUP_ENV_FILE="$T/v5/asdir" -- --plan
grep -q "GATE='validate'.*BACKUP_ENV_FILE=$T/v5/asdir" "$T/v5/run.log" && ok "V5 bad env file dies at validate" || bad "V5 bad env file dies at validate"

# V6: missing BACKUP_PATH dies at validate naming it
mkdir -p "$T/v6"
( cd "$T/v6" && env -u BACKUP_PATH -u BACKUP_SCRIPT -u BACKUP_ENV_FILE $(base_env) LOG_FILE="$T/v6/run.log" bash "$RUNNER" --plan >"$T/v6/out.txt" 2>&1; echo "$?" >"$T/v6/rc" )
grep -q "GATE='validate'.*missing: BACKUP_PATH" "$T/v6/run.log" && ok "V6 missing BACKUP_PATH dies at validate" || bad "V6 missing BACKUP_PATH dies at validate"

# V7: BACKUP_PATH pointing at a file dies at validate naming it
mkdir -p "$T/v7"; : >"$T/v7/afile"
run_case v7 "$T/v7" BACKUP_PATH="$T/v7/afile" -- --plan
grep -q "GATE='validate'.*BACKUP_PATH=$T/v7/afile" "$T/v7/run.log" && ok "V7 file BACKUP_PATH dies at validate" || bad "V7 file BACKUP_PATH dies at validate"

# V8: BACKUP_SCRIPT present but non-executable dies at validate naming it
mkdir -p "$T/v8/backups"; : >"$T/v8/noexec.sh"; chmod 644 "$T/v8/noexec.sh"
run_case v8 "$T/v8" BACKUP_PATH="$T/v8/backups" BACKUP_SCRIPT="$T/v8/noexec.sh" -- --plan
grep -q "GATE='validate'.*BACKUP_SCRIPT=$T/v8/noexec.sh" "$T/v8/run.log" && ok "V8 non-executable script dies at validate" || bad "V8 non-executable script dies at validate"

# P1: stubbed --plan end-to-end: missing backup halts naming cause + would-run, producer never runs
mkdir -p "$T/p1/bin" "$T/p1/backups"
cat >"$T/p1/bin/curl" <<'EOF'
#!/usr/bin/env bash
# stub: last arg is the URL; -i flag selects raw mode (probe_runners)
raw=0; url=""
for a in "$@"; do case "$a" in -i) raw=1;; http*|https*) url="$a";; esac; done
case "$url" in
  */api/v4/version) body='{"version":"17.5.5"}'; code=200 ;;
  *hub.docker.com*) body='{"results":[{"name":"17.8.1-ce.0"}],"next":null}'; code=200 ;;
  */-/health) body='GitLab OK'; code=200 ;;
  */health_check) body='GitLab health check success'; code=200 ;;
  */api/v4/runners/*) printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n[]'; exit 0 ;;
  *) echo "stub-curl: unexpected $url" >&2; exit 1 ;;
esac
if [ "$raw" = "1" ]; then printf 'HTTP/1.1 %s OK\r\n\r\n%s' "$code" "$body"; else printf '%s\n%s' "$body" "$code"; fi
EOF
cat >"$T/p1/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose -f "*" ps -q gitlab") echo fakecid ;;
  "inspect -f "*" fakecid") echo "running 0" ;;
  "compose -f "*" exec -T gitlab gitlab-rake"*) printf 'Database: main\n' ;;
  *) echo "stub-docker: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/p1/bin/curl" "$T/p1/bin/docker"
cat >"$T/p1/sentinel.sh" <<EOF
#!/usr/bin/env bash
touch "$T/p1/RAN-MARKER"; echo "sentinel must not run in plan" >&2; exit 1
EOF
chmod +x "$T/p1/sentinel.sh"
: >"$T/p1/backup.env"
( cd "$T/p1" && env $(base_env) BACKUP_PATH="$T/p1/backups" BACKUP_SCRIPT="$T/p1/sentinel.sh" BACKUP_ENV_FILE="$T/p1/backup.env" \
  LOG_FILE="$T/p1/run.log" PATH="$T/p1/bin:$PATH" bash "$RUNNER" --plan >"$T/p1/out.txt" 2>&1; echo "$?" >"$T/p1/rc" )
[ "$(cat $T/p1/rc)" = "1" ] && ok "P1 plan exits 1" || bad "P1 plan exits 1"
grep -q "GATE='plan'" "$T/p1/run.log" && ok "P1 halts at plan gate" || bad "P1 halts at plan gate"
grep -q "missing: no complete backup set" "$T/p1/run.log" && ok "P1 halt names missing cause" || bad "P1 halt names missing cause"
grep -q "would run the backup producer once, then re-check" "$T/p1/run.log" && ok "P1 would-run action" || bad "P1 would-run action"
[ ! -e "$T/p1/RAN-MARKER" ] && ok "P1 producer never runs in plan" || bad "P1 producer never runs in plan"
grep -q "check pre-health result=pass" "$T/p1/run.log" && ok "P1 reached backup via green pre-checks" || bad "P1 reached backup via green pre-checks"

# P2: same stubs, fresh set present -> plan passes fully, producer never runs
FRESH_TS=$(date -u +%Y%m%d-%H%M%S)
mkdir -p "$T/p1/backups/$FRESH_TS"
: >"$T/p1/backups/$FRESH_TS/set.tar.age"; : >"$T/p1/backups/$FRESH_TS/SHA256SUMS"
( cd "$T/p1" && env $(base_env) BACKUP_PATH="$T/p1/backups" BACKUP_SCRIPT="$T/p1/sentinel.sh" BACKUP_ENV_FILE="$T/p1/backup.env" \
  LOG_FILE="$T/p1/run2.log" PATH="$T/p1/bin:$PATH" bash "$RUNNER" --plan >"$T/p1/out2.txt" 2>&1; echo "$?" >"$T/p1/rc2" )
[ "$(cat $T/p1/rc2)" = "0" ] && ok "P2 plan passes with fresh set" || bad "P2 plan passes with fresh set"
grep -q "check pre-backup result=pass" "$T/p1/run2.log" && ok "P2 backup check passes" || bad "P2 backup check passes"
grep -q "preview done, nothing changed" "$T/p1/run2.log" && ok "P2 preview completes" || bad "P2 preview completes"
[ ! -e "$T/p1/RAN-MARKER" ] && ok "P2 producer never runs when fresh" || bad "P2 producer never runs when fresh"

# P3: stubbed --plan with stale set halts naming stale + would-run, producer never runs
mkdir -p "$T/p3/backups"; mkset "$T/p3/backups" "$STALE_TS"
cat >"$T/p3/sentinel.sh" <<EOF
#!/usr/bin/env bash
touch "$T/p3/RAN-MARKER"; echo "sentinel must not run in plan" >&2; exit 1
EOF
chmod +x "$T/p3/sentinel.sh"
: >"$T/p3/backup.env"
( cd "$T/p3" && env $(base_env) BACKUP_PATH="$T/p3/backups" BACKUP_SCRIPT="$T/p3/sentinel.sh" BACKUP_ENV_FILE="$T/p3/backup.env" \
  LOG_FILE="$T/p3/run.log" PATH="$T/p1/bin:$PATH" bash "$RUNNER" --plan >"$T/p3/out.txt" 2>&1; echo "$?" >"$T/p3/rc" )
[ "$(cat $T/p3/rc)" = "1" ] && ok "P3 plan exits 1" || bad "P3 plan exits 1"
grep -q "GATE='plan'" "$T/p3/run.log" && ok "P3 halts at plan gate" || bad "P3 halts at plan gate"
grep -q "stale: newest set $STALE_TS" "$T/p3/run.log" && ok "P3 halt names stale cause" || bad "P3 halt names stale cause"
grep -q "would run the backup producer once, then re-check" "$T/p3/run.log" && ok "P3 would-run action" || bad "P3 would-run action"
[ ! -e "$T/p3/RAN-MARKER" ] && ok "P3 producer never runs in plan" || bad "P3 producer never runs in plan"

# P4: stubbed --plan --nobackup with empty backups passes, backup skipped, producer never runs
mkdir -p "$T/p4/backups"
cat >"$T/p4/sentinel.sh" <<EOF
#!/usr/bin/env bash
touch "$T/p4/RAN-MARKER"; echo "sentinel must not run under nobackup" >&2; exit 1
EOF
chmod +x "$T/p4/sentinel.sh"
: >"$T/p4/backup.env"
( cd "$T/p4" && env $(base_env) BACKUP_PATH="$T/p4/backups" BACKUP_SCRIPT="$T/p4/sentinel.sh" BACKUP_ENV_FILE="$T/p4/backup.env" \
  LOG_FILE="$T/p4/run.log" PATH="$T/p1/bin:$PATH" bash "$RUNNER" --plan --nobackup >"$T/p4/out.txt" 2>&1; echo "$?" >"$T/p4/rc" )
[ "$(cat $T/p4/rc)" = "0" ] && ok "P4 plan nobackup passes" || bad "P4 plan nobackup passes"
grep -q "check pre-backup result=skip" "$T/p4/run.log" && ok "P4 backup check skipped" || bad "P4 backup check skipped"
grep -q "preview done, nothing changed" "$T/p4/run.log" && ok "P4 preview completes" || bad "P4 preview completes"
[ ! -e "$T/p4/RAN-MARKER" ] && ok "P4 producer never runs under nobackup" || bad "P4 producer never runs under nobackup"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
