source "$BATS_TEST_DIRNAME/test_helper.bash"

bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
  install_all_shims
  export RSYNC_SHIM_MODE="mirror"
  export SSH_SHIM_MODE="exec"
}

teardown() {
  sandbox_teardown
}

make_old_set() {
  d="$BACKUP_DIR/$1"
  mkdir -p "$d"
  printf 'old blob %s\n' "$1" >"$d/set.tar.age"
  printf 'old sums %s\n' "$1" >"$d/SHA256SUMS"
}

@test "three sets collapse to the newest two, deleted whole" {
  make_old_set "20200101-000000"
  make_old_set "20200202-000000"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^DONE PRUNE ts="
  [ ! -e "$BACKUP_DIR/20200101-000000" ]
  [ -d "$BACKUP_DIR/20200202-000000" ]
  [ "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' | wc -l)" -eq 2 ]
}

@test "failed ship runs no prune and keeps every local set" {
  make_old_set "20200101-000000"
  make_old_set "20200202-000000"
  export RSYNC_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:SHIP:"
  ! printf '%s\n' "$output" | grep -q "DONE PRUNE"
  [ -d "$BACKUP_DIR/20200101-000000" ]
  [ -d "$BACKUP_DIR/20200202-000000" ]
  [ "$(cat "$BACKUP_DIR/20200101-000000/set.tar.age")" = "old blob 20200101-000000" ]
}

@test "two or fewer sets prune nothing" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^DONE PRUNE ts="
  [ "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' | wc -l)" -eq 1 ]
}

@test "dirname order wins over mtime" {
  make_old_set "20200202-000000"
  make_old_set "20200101-000000"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/20200101-000000" ]
  [ -d "$BACKUP_DIR/20200202-000000" ]
}

@test "prune never touches the NAS" {
  mkdir -p "$SANDBOX_REMOTE$NAS_DIR/20200101-000000"
  printf 'remote old\n' >"$SANDBOX_REMOTE$NAS_DIR/20200101-000000/set.tar.age"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX_REMOTE$NAS_DIR/20200101-000000/set.tar.age")" = "remote old" ]
}

@test "staging dirs, lock file, and odd names are never victims" {
  mkdir -p "$BACKUP_DIR/.staging-xyz"
  printf 'x\n' >"$BACKUP_DIR/.staging-xyz/file.txt"
  printf 'notes\n' >"$BACKUP_DIR/notes.txt"
  mkdir -p "$BACKUP_DIR/12345"
  make_old_set "20200101-000000"
  make_old_set "20200202-000000"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_DIR/.staging-xyz/file.txt" ]
  [ -f "$BACKUP_DIR/notes.txt" ]
  [ -d "$BACKUP_DIR/12345" ]
  [ -f "$BACKUP_DIR/.lock" ]
}
