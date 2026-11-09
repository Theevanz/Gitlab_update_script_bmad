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

@test "bundle packs tarball, config, and recipe with relative members only" {
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^START BUNDLE ts="
  printf '%s\n' "$output" | grep -q "^DONE BUNDLE ts="
  setdir="$(find "$BACKUP_DIR" -maxdepth 1 -type d -name '20*')"
  members="$(tar -tf "$setdir/set.tar.age")"
  printf '%s\n' "$members" | grep -q "^/" && return 1 || true
  [ "$(printf '%s\n' "$members" | wc -l)" -eq 6 ]
  norm="$(printf '%s\n' "$members" | sed 's/^[0-9-]*_gitlab_backup.tar/TARBALL/' | sort)"
  want="$(printf '%s\n' "TARBALL" "config/" "config/gitlab.rb" "config/gitlab-secrets.json" "docker-compose.yml" ".env" | sort)"
  [ "$norm" = "$want" ]
}

@test "missing .env beside the compose file fails naming the file" {
  rm "$COMPOSE_DIR/.env"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:BUNDLE:ts=.*missing .env"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -name '20*' -type d)" ]
}

@test "mismatched staged copy fails the bundle" {
  install_cmp_shim
  export CMP_SHIM_MODE="fail"
  run --separate-stderr bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q "^FAIL:BUNDLE:ts=.*differs"
}

@test "zero tarballs in staging fails the bundle" {
  ts="20330101-010101"
  mkdir -p "$BACKUP_DIR/.staging-$ts"
  run wb_stage bundle "$ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^FAIL:BUNDLE:ts=$ts:.*exactly one tarball"
}

@test "two tarballs in staging fails the bundle" {
  ts="20330101-010101"
  mkdir -p "$BACKUP_DIR/.staging-$ts"
  printf 'one\n' >"$BACKUP_DIR/.staging-$ts/20330101-010101_gitlab_backup.tar"
  printf 'two\n' >"$BACKUP_DIR/.staging-$ts/20330101-010102_gitlab_backup.tar"
  run wb_stage bundle "$ts"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^FAIL:BUNDLE:ts=$ts:.*exactly one tarball"
}
