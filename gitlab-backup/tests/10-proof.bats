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

@test "full run yields a complete set locally and remotely with newest-2 history" {
  mkdir -p "$BACKUP_DIR/20200101-000000" "$BACKUP_DIR/20200202-000000"
  printf 'old\n' >"$BACKUP_DIR/20200101-000000/set.tar.age"
  printf 'old\n' >"$BACKUP_DIR/20200101-000000/SHA256SUMS"
  printf 'old\n' >"$BACKUP_DIR/20200202-000000/set.tar.age"
  printf 'old\n' >"$BACKUP_DIR/20200202-000000/SHA256SUMS"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  ts="$(printf '%s\n' "$output" | grep "^DONE CONFIG" | sed 's/.*ts=\([^ ]*\).*/\1/')"
  [ -f "$BACKUP_DIR/$ts/set.tar.age" ]
  [ -f "$BACKUP_DIR/$ts/SHA256SUMS" ]
  (cd "$BACKUP_DIR/$ts" && sha256sum -c SHA256SUMS)
  [ -f "$SANDBOX_REMOTE$NAS_DIR/$ts/set.tar.age" ]
  [ -f "$SANDBOX_REMOTE$NAS_DIR/$ts/SHA256SUMS" ]
  (cd "$SANDBOX_REMOTE$NAS_DIR/$ts" && sha256sum -c SHA256SUMS)
  [ ! -e "$BACKUP_DIR/20200101-000000" ]
  [ -d "$BACKUP_DIR/20200202-000000" ]
  [ "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' | wc -l)" -eq 2 ]
  want="$(printf 'START CONFIG ts=%s\nDONE CONFIG ts=%s BACKUP_DIR=%s\nSTART CAPTURE ts=%s\nDONE CAPTURE ts=%s\nSTART BUNDLE ts=%s\nDONE BUNDLE ts=%s\nSTART ENCRYPT ts=%s\nDONE ENCRYPT ts=%s\nSTART HASH ts=%s\nDONE HASH ts=%s\nSTART SHIP ts=%s\nDONE SHIP ts=%s\nSTART PRUNE ts=%s\nDONE PRUNE ts=%s' "$ts" "$ts" "$BACKUP_DIR" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts" "$ts")"
  [ "$output" = "$want" ]
}

@test "sweep: config failure leaves nothing behind" {
  export AGE_PUBKEY_FILE="$SANDBOX/keys/does-not-exist"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CONFIG:"
  [ -z "$(find "$BACKUP_DIR" -mindepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')" ]
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR" ]
}

@test "sweep: lock failure leaves nothing behind" {
  export FLOCK_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:LOCK:"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')" ]
}

@test "sweep: capture failure leaves nothing behind" {
  export DOCKER_SHIM_MODE="exec-fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:CAPTURE:"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')" ]
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR" ]
}

@test "sweep: bundle failure leaves nothing behind" {
  rm "$COMPOSE_DIR/.env"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:BUNDLE:"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')" ]
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR" ]
}

@test "sweep: encrypt failure leaves nothing behind" {
  export AGE_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:ENCRYPT:"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')" ]
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR" ]
}

@test "sweep: hash failure leaves nothing behind" {
  ts="20330101-010101"
  staging="$BACKUP_DIR/.staging-$ts"
  mkdir -p "$staging"
  printf 'fake blob\n' >"$staging/set.tar.age"
  printf '0000000000000000000000000000000000000000000000000000000000000000  set.tar.age\n' >"$staging/SHA256SUMS"
  run wb_stage hash "$ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^FAIL:HASH:"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '.staging-*')" ]
  [ ! -e "$BACKUP_DIR/$ts" ]
}

@test "sweep: ship failure keeps the local set and leaves no remote trace" {
  export RSYNC_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:SHIP:"
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -f "$setdir/set.tar.age" ]
  [ -f "$setdir/SHA256SUMS" ]
  (cd "$setdir" && sha256sum -c SHA256SUMS)
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR" ]
}

@test "sweep: prune failure keeps every set whole" {
  install_rm_shim
  export RM_SHIM_MODE="fail-outside-staging"
  mkdir -p "$BACKUP_DIR/20200101-000000" "$BACKUP_DIR/20200202-000000"
  printf 'old\n' >"$BACKUP_DIR/20200101-000000/set.tar.age"
  printf 'old\n' >"$BACKUP_DIR/20200101-000000/SHA256SUMS"
  printf 'old\n' >"$BACKUP_DIR/20200202-000000/set.tar.age"
  printf 'old\n' >"$BACKUP_DIR/20200202-000000/SHA256SUMS"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  export RM_SHIM_MODE="ok"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:PRUNE:"
  [ -d "$BACKUP_DIR/20200101-000000" ]
  [ -d "$BACKUP_DIR/20200202-000000" ]
  [ ! -d "$SANDBOX_REMOTE$NAS_DIR/20200101-000000" ] || true
}
