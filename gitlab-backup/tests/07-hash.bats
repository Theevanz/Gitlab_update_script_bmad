source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  sandbox_setup
  install_all_shims
  export RSYNC_SHIM_MODE="mirror"
  export SSH_SHIM_MODE="exec"
}

teardown() {
  sandbox_teardown
}

@test "hash writes one exact hash line and publishes atomically" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^START HASH ts="
  printf '%s\n' "$output" | grep -q "^DONE HASH ts="
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  [ -n "$setdir" ]
  [ "$(wc -l <"$setdir/SHA256SUMS")" -eq 1 ]
  [ "$(wc -c <"$setdir/SHA256SUMS")" -eq 78 ]
  grep -E -x "[0-9a-f][0-9a-f]*  set.tar.age" "$setdir/SHA256SUMS"
  [ "$(tail -c 1 "$setdir/SHA256SUMS" | od -An -c | tr -d ' ')" = '\n' ]
  (cd "$setdir" && sha256sum -c SHA256SUMS)
}

@test "third entry at the publish gate fails the hash" {
  ts="20330101-010101"
  staging="$BACKUP_DIR/.staging-$ts"
  mkdir -p "$staging"
  printf 'fake blob\n' >"$staging/set.tar.age"
  (cd "$staging" && sha256sum set.tar.age >SHA256SUMS)
  printf 'leftover\n' >"$staging/leftover.txt"
  run wb_stage hash "$ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^FAIL:HASH:ts=$ts:"
  [ ! -e "$BACKUP_DIR/$ts" ]
}

@test "corrupt hash file fails the hash" {
  ts="20330101-010101"
  staging="$BACKUP_DIR/.staging-$ts"
  mkdir -p "$staging"
  printf 'fake blob\n' >"$staging/set.tar.age"
  printf '0000000000000000000000000000000000000000000000000000000000000000  set.tar.age\n' >"$staging/SHA256SUMS"
  run wb_stage hash "$ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^FAIL:HASH:ts=$ts:"
  [ ! -e "$BACKUP_DIR/$ts" ]
}

@test "published set holds exactly the blob plus hash and older sets are untouched" {
  old="$BACKUP_DIR/20200101-000000"
  mkdir -p "$old"
  printf 'old blob\n' >"$old/set.tar.age"
  printf 'old sums\n' >"$old/SHA256SUMS"
  before="$(sha256sum "$old/set.tar.age" "$old/SHA256SUMS")"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*' ! -name '20200101-000000')"
  [ "$(find "$setdir" -maxdepth 1 -type f | wc -l)" -eq 2 ]
  (cd "$setdir" && sha256sum -c SHA256SUMS)
  [ -z "$(find "$BACKUP_DIR" -name '*.bak')" ]
  after="$(sha256sum "$old/set.tar.age" "$old/SHA256SUMS")"
  [ "$before" = "$after" ]
}
