source "$BATS_TEST_DIRNAME/test_helper.bash"

bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
  install_all_shims
}

teardown() {
  sandbox_teardown
}

@test "ship mirrors contents and verifies in order with absolute remote paths" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^START SHIP ts="
  printf '%s\n' "$output" | grep -q "^DONE SHIP ts="
  [ "$(wc -l <"$CALLS/rsync.calls")" -eq 1 ]
  rsync_line="$(cat "$CALLS/rsync.calls")"
  printf '%s' "$rsync_line" | grep -q -F -- "-a -e ssh -i $SSH_KEY_FILE"
  src=""
  dst=""
  for w in $rsync_line; do src="$dst"; dst="$w"; done
  [[ "$src" == */ ]]
  [[ "$dst" == */ ]]
  [[ "$dst" == backup@nas.test:/backups/gitlab/.staging-* ]]
  [ "$(wc -l <"$CALLS/ssh.calls")" -eq 4 ]
  presence="$(grep -n -F "test -f" "$CALLS/ssh.calls" | head -n 1 | cut -d: -f1)"
  verify="$(grep -n -F "sha256sum -c SHA256SUMS" "$CALLS/ssh.calls" | head -n 1 | cut -d: -f1)"
  rename="$(grep -n -F "mv '" "$CALLS/ssh.calls" | head -n 1 | cut -d: -f1)"
  [ "$presence" -lt "$verify" ]
  [ "$verify" -lt "$rename" ]
  grep -q -F "(cd '/backups/gitlab/.staging-" "$CALLS/ssh.calls"
  ! grep -E "test -[fe] '[^/]|cd '[^/]|mv '[^/]" "$CALLS/ssh.calls"
}

@test "local re-verify failure sends nothing" {
  ts="20330101-010101"
  pub="$BACKUP_DIR/$ts"
  mkdir -p "$pub"
  printf 'fake blob\n' >"$pub/set.tar.age"
  printf '0000000000000000000000000000000000000000000000000000000000000000  set.tar.age\n' >"$pub/SHA256SUMS"
  run wb_stage ship "$ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^FAIL:SHIP:ts=$ts:.*re-verification"
  [ ! -e "$CALLS/rsync.calls" ]
}

@test "missing remote member fails and sweeps remote staging" {
  export RSYNC_SHIM_MODE="mirror"
  export RSYNC_SHIM_DROP="SHA256SUMS"
  export SSH_SHIM_MODE="exec"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:SHIP:ts=.*missing-member"
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -f "$setdir/set.tar.age" ]
  [ -f "$setdir/SHA256SUMS" ]
  [ -z "$(find "$SANDBOX_REMOTE$NAS_DIR" -mindepth 1 2>/dev/null)" ]
}

@test "remote hash mismatch fails with no remote set left behind" {
  export RSYNC_SHIM_MODE="mirror"
  export RSYNC_SHIM_CORRUPT="1"
  export SSH_SHIM_MODE="exec"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:SHIP:ts=.*hash-mismatch"
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -f "$setdir/set.tar.age" ]
  [ -f "$setdir/SHA256SUMS" ]
  [ -z "$(find "$SANDBOX_REMOTE$NAS_DIR" -mindepth 1 2>/dev/null)" ]
}

@test "existing remote set aborts before the remote rename" {
  install_date_shim
  export DATE_SHIM_TS="20330101-010101"
  export RSYNC_SHIM_MODE="mirror"
  export SSH_SHIM_MODE="exec"
  mkdir -p "$SANDBOX_REMOTE$NAS_DIR/20330101-010101"
  printf 'already here\n' >"$SANDBOX_REMOTE$NAS_DIR/20330101-010101/marker.txt"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:SHIP:ts=20330101-010101:.*already exists"
  [ "$(cat "$SANDBOX_REMOTE$NAS_DIR/20330101-010101/marker.txt")" = "already here" ]
  [ ! -e "$SANDBOX_REMOTE$NAS_DIR/.staging-20330101-010101" ]
}

@test "rsync failure leaves no partial remote set and keeps the local one" {
  export RSYNC_SHIM_MODE="fail"
  export SSH_SHIM_MODE="exec"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:SHIP:ts=.*rsync"
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -f "$setdir/set.tar.age" ]
  [ -f "$setdir/SHA256SUMS" ]
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR" ]
}

@test "real endpoint receives a verifying set" {
  if [ -z "${TEST_SSH_ENDPOINT:-}" ] || [ -z "${TEST_SSH_KEY:-}" ] || [ -z "${TEST_NAS_DIR:-}" ]; then
    skip "no TEST_SSH_ENDPOINT fixture"
  fi
  mkdir -p "$SANDBOX/realbin"
  cp "$SANDBOX/bin/docker" "$SANDBOX/bin/age" "$SANDBOX/realbin/"
  PATH="$SANDBOX/realbin:$ORIG_PATH"
  export PATH
  need_tool flock
  need_tool rsync
  need_tool ssh
  export NAS_HOST="${TEST_SSH_ENDPOINT%%:*}"
  export NAS_USER="${TEST_SSH_USER:-backup}"
  export NAS_DIR="$TEST_NAS_DIR"
  export SSH_KEY_FILE="$TEST_SSH_KEY"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  ts="$(printf '%s\n' "$output" | grep "^DONE SHIP" | sed 's/.*ts=\([^ ]*\).*/\1/')"
  ssh -i "$TEST_SSH_KEY" "$NAS_USER@$NAS_HOST" "(cd '$TEST_NAS_DIR/$ts' && sha256sum -c SHA256SUMS)"
  status="$?"
  [ "$status" -eq 0 ]
}
