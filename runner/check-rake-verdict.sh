#!/usr/bin/env bash
# Focused regression for the rake-table verdict: rows reading `finished` or
# `finalized` count as done; anything else blocks; malformed tables reject.
# Sources the real runner (its entry guard keeps main from running) and feeds
# parse_rake_status self-contained fixtures, plus pins for the exact leftover
# pass line and the frozen heartbeat field names. No Docker needed.
# Exit 0 when every case passes, 1 otherwise.
set -eu
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")"
RUNNER="$PWD/upgrade-gitlab.sh"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf 'PASS %s\n' "$1"
  else
    printf 'FAIL %s: expected <%s> got <%s>\n' "$1" "$2" "$3"
    fail=1
  fi
}

# Sourced load must define functions without running anything.
probe_out="$(bash -c '. ./upgrade-gitlab.sh' 2>&1)" || fail=1
check "sourced-load-silent" "" "$probe_out"

# Executed path must run main: with empty env from a temp CWD and a temp
# log, the run must reach the validate halt (exit 1 + missing-settings
# marker) without touching the repo.
exec_tmp="$(mktemp -d)"
if exec_out="$(cd "$exec_tmp" && env -i PATH="$PATH" LOG_FILE="$exec_tmp/run.log" bash "$RUNNER" 2>&1)"; then exec_code=0; else exec_code=$?; fi
check "executed-path-exit" "1" "$exec_code"
case "$exec_out" in
  *"required settings are missing"*) check "executed-path-marker" "found" "found" ;;
  *) check "executed-path-marker" "found" "absent" ;;
esac
rm -rf "$exec_tmp"

. ./upgrade-gitlab.sh

run_case() { # name fixture expected_counts expected_code
  local got code
  if got="$(parse_rake_status "$2")"; then code=0; else code=$?; fi
  check "$1-counts" "$3" "$got"
  check "$1-exit" "$4" "$code"
}

FIX_ALL_FINISHED="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
finished | BackfillB,table_b,id,[]
finished | BackfillC,table_c,id,[]
EOF
)"

# Mirrors the live 17.1 table shape (see demo-evidence-4-4/rake-status-17.1-leftovers.log).
FIX_FINISHED_PLUS_FINALIZED="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
finished | BackfillB,table_b,id,[]
finalized  | BackfillEpicBasicFieldsToWorkItemRecord,epics,id,[null]
EOF
)"

FIX_ONE_ACTIVE="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
finished | BackfillB,table_b,id,[]
active | BackfillC,table_c,id,[]
EOF
)"

FIX_ONE_FINALIZING="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
finalizing | BackfillB,table_b,id,[]
EOF
)"

FIX_ONE_PAUSED="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
paused | BackfillB,table_b,id,[]
EOF
)"

FIX_ONE_FAILED="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
failed | BackfillB,table_b,id,[]
EOF
)"

FIX_ONE_PENDING="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
pending | BackfillB,table_b,id,[]
EOF
)"

FIX_ONE_UNKNOWN="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
bogus-state | BackfillB,table_b,id,[]
EOF
)"

FIX_ZERO_ROWS="$(cat <<'EOF'
Database: main
EOF
)"

FIX_NO_BANNER="$(cat <<'EOF'
finished | BackfillA,table_a,id,[]
EOF
)"

run_case "all-finished" "$FIX_ALL_FINISHED" "3 3" "0"
run_case "finished-plus-finalized" "$FIX_FINISHED_PLUS_FINALIZED" "3 3" "0"
run_case "one-active" "$FIX_ONE_ACTIVE" "2 3" "0"
run_case "one-finalizing" "$FIX_ONE_FINALIZING" "1 2" "0"
run_case "one-paused" "$FIX_ONE_PAUSED" "1 2" "0"
run_case "one-failed" "$FIX_ONE_FAILED" "1 2" "0"
run_case "one-pending" "$FIX_ONE_PENDING" "1 2" "0"
run_case "one-unknown" "$FIX_ONE_UNKNOWN" "1 2" "0"
run_case "zero-rows" "$FIX_ZERO_ROWS" "0 0" "0"
run_case "malformed" "$FIX_NO_BANNER" "" "1"

# Verdict-string pin: the leftover pass line must use the exact `complete`
# wording. Stub the Docker probe, run the real leftover check, match stderr.
FIX_LEFTOVER_PASS="$(cat <<'EOF'
Database: main
finished | BackfillA,table_a,id,[]
finalized | BackfillB,table_b,id,[]
EOF
)"
fetch_rake_status() { printf '%s\n' "$FIX_LEFTOVER_PASS"; }
probe_tmp="$(mktemp -d)"
PHASE="probe"
TARGET=""
LOG_FILE="$probe_tmp/probe.log"
if leftover_out="$(check_rake_leftover 2>&1)"; then leftover_code=0; else leftover_code=$?; fi
check "leftover-pass-exit" "0" "$leftover_code"
case "$leftover_out" in
  *'leftover check: 2 of 2 complete (finished or finalized)'*) check "leftover-pass-line" "found" "found" ;;
  *) check "leftover-pass-line" "found" "absent" ;;
esac

# Heartbeat-field pin: the frozen rake_finished/rake_total/rake_delta names
# must appear in order on the emitted heartbeat line.
HB_CPU='1.0%' HB_MEM='1GiB / 2GiB' HB_BIO='1MB / 2MB' HB_NET='1kB / 2kB'
HB_ELAPSED=0 HB_HEALTH=OK HB_LIVE=200 HB_FIN=2 HB_TOT=2 HB_DELTA=0
if hb_out="$(emit_heartbeat 2>&1)"; then hb_code=0; else hb_code=$?; fi
check "heartbeat-exit" "0" "$hb_code"
case "$hb_out" in
  *'rake_finished=2'*'rake_total=2'*'rake_delta=0'*) check "heartbeat-fields" "found" "found" ;;
  *) check "heartbeat-fields" "found" "absent" ;;
esac
rm -rf "$probe_tmp"

if [ "$fail" = "1" ]; then
  printf 'CHECK FAILED\n'
else
  printf 'ALL CHECKS PASSED\n'
fi
exit "$fail"
