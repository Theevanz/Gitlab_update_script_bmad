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

@test "encrypt seals the set and stages it for hashing" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^START ENCRYPT ts="
  printf '%s\n' "$output" | grep -q "^DONE ENCRYPT ts="
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -f "$setdir/set.tar.age" ]
  [ -f "$setdir/SHA256SUMS" ]
}

@test "no plaintext survives anywhere after the seal" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  leftovers="$(find "$BACKUP_DIR" -name '*_gitlab_backup.tar' -o -name 'set.tar' -o -name '.env' | wc -l)"
  [ "$leftovers" -eq 0 ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$GITLAB_DATA_DIR/backups" -name '*_gitlab_backup.tar')" ]
}

@test "failed age run names the stage and publishes nothing" {
  export AGE_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:ENCRYPT:ts=.*age failed"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '20*' -type d)" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
}

@test "failed wipe names the stage" {
  install_rm_shim
  export RM_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  export RM_SHIM_MODE="ok"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:ENCRYPT:ts=.*wipe"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '20*' -type d)" ]
}

@test "encryption is exactly one age invocation" {
  export AGE_BIN="age"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$CALLS/age.calls")" -eq 1 ]
  grep -F -x -- "-R $AGE_PUBKEY_FILE -o set.tar.age set.tar" "$CALLS/age.calls"
}

@test "no private key material or path exists in the repo or the script" {
  root="$BATS_TEST_DIRNAME/.."
  ! grep -rE "AGE-SECRET-KEY|BEGIN [A-Z ]*PRIVATE KEY" "$root/backup" "$root/tests" "$root/docs" 2>/dev/null
  refs="$(grep -o 'AGE_[A-Z_]*FILE' "$root/backup/gitlab-backup.sh" | sort -u)"
  [ "$refs" = "AGE_PUBKEY_FILE" ]
  ! grep -q "AGE_PRIVATE" "$root/backup/gitlab-backup.sh"
}
