source "$BATS_TEST_DIRNAME/test_helper.bash"

bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
}

teardown() {
  sandbox_teardown
}

@test "lock contention fails with exactly one FAIL:LOCK line and no stdout" {
  install_docker_shim
  install_flock_shim
  export FLOCK_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  ! printf '%s\n' "$output" | grep -q "START"
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:LOCK:ts=-:another run holds"
}

@test "real lock contention refuses the second run" {
  need_tool flock
  need_tool sleep
  install_docker_shim
  flock -n "$BACKUP_DIR/.lock" sleep 20 &
  holder="$!"
  sleep 1
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l)" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:LOCK:ts=-:"
}

@test "one timestamp is reused for staging, publish, and remote paths" {
  install_all_shims
  export RSYNC_SHIM_MODE="mirror"
  export SSH_SHIM_MODE="exec"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  ts="$(printf '%s\n' "$output" | grep "^DONE CONFIG" | sed 's/.*ts=\([^ ]*\).*/\1/')"
  [ -n "$ts" ]
  [ -d "$BACKUP_DIR/$ts" ]
  [ -d "$SANDBOX_REMOTE$NAS_DIR/$ts" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
}

@test "pre-existing staging dir aborts the run" {
  install_docker_shim
  install_flock_shim
  install_date_shim
  export DATE_SHIM_TS="20330101-010101"
  mkdir -p "$BACKUP_DIR/.staging-20330101-010101"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=20330101-010101:.*collision"
}

@test "pre-existing set dir aborts the run" {
  install_docker_shim
  install_flock_shim
  install_date_shim
  export DATE_SHIM_TS="20330101-010101"
  mkdir -p "$BACKUP_DIR/20330101-010101"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=20330101-010101:.*collision"
}

@test "failure after staging removes the build folder and frees the next run" {
  install_all_shims
  export DOCKER_SHIM_MODE="exec-fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CAPTURE:"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '20[0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]')" ]
  [ -f "$BACKUP_DIR/.lock" ]
  export DOCKER_SHIM_MODE="ok"
  export RSYNC_SHIM_MODE="mirror"
  export SSH_SHIM_MODE="exec"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
}

@test "every FAIL detail reads as plain words" {
  install_all_shims
  export AGE_PUBKEY_FILE="$SANDBOX/keys/does-not-exist"
  bash "$SCRIPT_UNDER_TEST" >/dev/null 2>"$SANDBOX/f1.txt" || true
  export AGE_PUBKEY_FILE="$SANDBOX/keys/nas.agepub"
  export DOCKER_SHIM_MODE="exec-fail"
  bash "$SCRIPT_UNDER_TEST" >/dev/null 2>"$SANDBOX/f2.txt" || true
  export DOCKER_SHIM_MODE="ok"
  export FLOCK_SHIM_MODE="fail"
  bash "$SCRIPT_UNDER_TEST" >/dev/null 2>"$SANDBOX/f3.txt" || true
  f=""
  for f in "$SANDBOX/f1.txt" "$SANDBOX/f2.txt" "$SANDBOX/f3.txt"; do
    line="$(cat "$f")"
    case "$line" in
    FAIL:*) : ;;
    *) return 1 ;;
    esac
    detail="$(printf '%s' "$line" | cut -d: -f4-)"
    [[ "$detail" == *" "* ]]
    [[ "$detail" =~ [a-z] ]]
  done
}
