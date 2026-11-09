source "$BATS_TEST_DIRNAME/test_helper.bash"

setup() {
  sandbox_setup
}

teardown() {
  sandbox_teardown
}

@test "runbook documents the restore procedure and operator responsibilities" {
  book="$BATS_TEST_DIRNAME/../docs/restore.md"
  [ -f "$book" ]
  grep -q -i "restore" "$book"
  grep -q -F "set.tar.age" "$book"
  grep -q -F "SHA256SUMS" "$book"
  grep -q -F "age --decrypt" "$book"
  grep -q -i "private key" "$book"
  grep -q -i "nas" "$book"
  grep -q -i "schedul" "$book"
  grep -q -i "retention" "$book"
  grep -q -i "pinned version" "$book"
}

@test "counter-metric: no per-artifact hashes, sidecars, or per-file logic after the seal" {
  script="$BATS_TEST_DIRNAME/../backup/gitlab-backup.sh"
  [ "$(grep -c '>SHA256SUMS.tmp' "$script")" -eq 1 ]
  [ "$(grep -c 'sha256sum -c' "$script")" -eq 3 ]
  ! grep -r -i "manifest" "$BATS_TEST_DIRNAME/../backup/"
}
