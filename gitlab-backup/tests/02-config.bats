source "$BATS_TEST_DIRNAME/test_helper.bash"

bats_require_minimum_version 1.5.0

setup() {
  sandbox_setup
}

teardown() {
  sandbox_teardown
}

@test "missing key file fails fast with FAIL:CONFIG naming the input" {
  export AGE_PUBKEY_FILE="$SANDBOX/keys/does-not-exist"
  start="$SECONDS"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  elapsed=$((SECONDS - start))
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:.*AGE_PUBKEY_FILE"
  [ -z "$output" ]
  [ "$elapsed" -lt 5 ]
  [ -z "$(ls -A "$BACKUP_DIR")" ]
  [ ! -e "$BACKUP_DIR/.lock" ]
}

@test "missing ssh key fails with FAIL:CONFIG naming the input" {
  export SSH_KEY_FILE="$SANDBOX/keys/does-not-exist"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:.*SSH_KEY_FILE"
  [ -z "$output" ]
}

@test "empty age key file fails with FAIL:CONFIG" {
  printf '' >"$SANDBOX/keys/nas.agepub"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:"
}

@test "two-line age key file fails with FAIL:CONFIG" {
  printf '%s\n%s\n' "$VALID_AGE_KEY" "$VALID_AGE_KEY" >"$SANDBOX/keys/nas.agepub"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:"
}

@test "wrong-prefix age key file fails with FAIL:CONFIG" {
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabg873o0X6PzHo6x0pk\n' >"$SANDBOX/keys/nas.agepub"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:"
}

@test "unwritable BACKUP_DIR fails with FAIL:CONFIG" {
  export BACKUP_DIR="$SANDBOX/does-not-exist"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:.*BACKUP_DIR"
}

@test "missing container fails with FAIL:CONFIG" {
  export GITLAB_CONTAINER="definitely-not-a-container"
  export DOCKER_SHIM_MODE="inspect-fail"
  install_docker_shim
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:.*container"
}

@test "explicitly emptied variable falls through to the env file" {
  mkdir -p "$SANDBOX/file-backups"
  printf 'BACKUP_DIR=%s\n' "$SANDBOX/file-backups" >"$SANDBOX/custom.env"
  export ENV_FILE="$SANDBOX/custom.env"
  export BACKUP_DIR=""
  install_all_shims
  export RSYNC_SHIM_MODE="mirror"
  export SSH_SHIM_MODE="exec"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^DONE CONFIG ts=.* BACKUP_DIR=$SANDBOX/file-backups$"
}

@test "unresolvable BACKUP_DIR fails naming BACKUP_DIR" {
  mkdir -p "$SANDBOX/nowhere"
  touch "$SANDBOX/nowhere/docker-compose.yml"
  export COMPOSE_FILE="$SANDBOX/nowhere/docker-compose.yml"
  unset BACKUP_DIR
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:.*BACKUP_DIR"
}

@test "directory as env file fails with FAIL:CONFIG" {
  mkdir -p "$SANDBOX/not-a-file.env"
  export ENV_FILE="$SANDBOX/not-a-file.env"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:ts=-:"
}
