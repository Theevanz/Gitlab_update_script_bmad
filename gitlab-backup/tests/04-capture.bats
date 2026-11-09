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

@test "capture runs the native backup and stages exactly its own tarball" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^START CAPTURE ts="
  printf '%s\n' "$output" | grep -q "^DONE CAPTURE ts="
  grep -F -x "exec -t gitlab-test gitlab-backup create STRATEGY=copy" "$CALLS/docker.calls"
}

@test "failed capture names the stage and publishes nothing" {
  export DOCKER_SHIM_MODE="exec-fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CAPTURE:ts=.*:.*create failed"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '20*' -type d)" ]
}

@test "capture with no tarball produced fails instead of guessing" {
  export DOCKER_SHIM_NO_TARBALL="1"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CAPTURE:"
}

@test "stale tarball is never picked up and the live volume is otherwise untouched" {
  printf 'stale payload\n' >"$GITLAB_DATA_DIR/backups/20000101-000000_gitlab_backup.tar"
  printf 'sentinel\n' >"$GITLAB_DATA_DIR/other.txt"
  mkdir -p "$GITLAB_DATA_DIR/sub"
  printf 'subdata\n' >"$GITLAB_DATA_DIR/sub/file.txt"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -n "$setdir" ]
  members="$(tar -tf "$setdir/set.tar.age")"
  [ "$(printf '%s\n' "$members" | grep -c 'gitlab_backup.tar')" -eq 1 ]
  printf '%s\n' "$members" | grep -q "20000101-000000" && return 1 || true
  [ -f "$GITLAB_DATA_DIR/backups/20000101-000000_gitlab_backup.tar" ]
  [ "$(cat "$GITLAB_DATA_DIR/other.txt")" = "sentinel" ]
  [ "$(cat "$GITLAB_DATA_DIR/sub/file.txt")" = "subdata" ]
  [ "$(find "$GITLAB_DATA_DIR/backups" -name '*_gitlab_backup.tar' | wc -l)" -eq 1 ]
}
