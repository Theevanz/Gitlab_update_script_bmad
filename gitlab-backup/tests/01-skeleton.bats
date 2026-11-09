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

grammar_ok() {
  local line="$1"
  [[ "$line" =~ ^(START|DONE)[[:space:]][A-Z]+[[:space:]]ts=[^[:space:]]+([[:space:]].*)?$ ]]
}

all_lines_grammar() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grammar_ok "$line" || return 1
  done <<<"$1"
  return 0
}

@test "repo tree holds the script, env example, vendor pin, and BATS skeleton" {
  root="$BATS_TEST_DIRNAME/.."
  [ -f "$root/backup/gitlab-backup.sh" ]
  [ -f "$root/backup/backup.env.example" ]
  [ -f "$root/backup/vendor/age.SHA256" ]
  grep -q "1.3.2" "$root/backup/vendor/age.SHA256"
  v=""
  for v in BACKUP_DIR NAS_HOST NAS_USER NAS_DIR SSH_KEY_FILE AGE_PUBKEY_FILE GITLAB_CONTAINER GITLAB_CONFIG_DIR GITLAB_DATA_DIR COMPOSE_FILE AGE_BIN VERBOSE ENV_FILE; do
    grep -q "^$v=" "$root/backup/backup.env.example"
  done
  found=""
  found="$(find "$root/tests" -maxdepth 1 -name '*.bats' | wc -l)"
  [ "$found" -ge 1 ]
}

@test "bare run with no env file and no env overrides exits 0 with grammar-only stdout" {
  poc="$SANDBOX/poc"
  mkdir -p "$poc/gitlab-backup/backup/vendor" "$poc/test-gitlab-server/keys"
  mkdir -p "$poc/test-gitlab-server/volumes/config" "$poc/test-gitlab-server/volumes/data/backups"
  mkdir -p "$poc/test-gitlab-server/backups"
  cp "$SCRIPT_UNDER_TEST" "$poc/gitlab-backup/backup/gitlab-backup.sh"
  cp "$SANDBOX/bin/age" "$poc/gitlab-backup/backup/vendor/age"
  printf 'services:\n  gitlab:\n    image: gitlab-test\n' >"$poc/test-gitlab-server/docker-compose.yml"
  printf 'FAKEVAR=1\n' >"$poc/test-gitlab-server/.env"
  printf 'external_url "http://gitlab.test"\n' >"$poc/test-gitlab-server/volumes/config/gitlab.rb"
  printf '%s\n' "$VALID_AGE_KEY" >"$poc/test-gitlab-server/keys/nas.agepub"
  printf 'fake-ssh-key\n' >"$poc/test-gitlab-server/keys/id_backup_ed25519"
  export SHIM_DATA_DIR="$poc/test-gitlab-server/volumes/data"
  v=""
  for v in BACKUP_DIR NAS_HOST NAS_USER NAS_DIR SSH_KEY_FILE AGE_PUBKEY_FILE GITLAB_CONTAINER GITLAB_CONFIG_DIR GITLAB_DATA_DIR COMPOSE_FILE AGE_BIN VERBOSE ENV_FILE; do
    unset "$v"
  done
  run bash "$poc/gitlab-backup/backup/gitlab-backup.sh"
  [ "$status" -eq 0 ]
  all_lines_grammar "$output"
  printf '%s\n' "$output" | head -n 1 | grep -q "^START CONFIG ts="
  printf '%s\n' "$output" | grep -q "^DONE CONFIG ts=.* BACKUP_DIR=$poc/test-gitlab-server/backups$"
}

@test "env file wins over built-in defaults" {
  mkdir -p "$SANDBOX/file-backups"
  printf 'BACKUP_DIR=%s\n' "$SANDBOX/file-backups" >"$SANDBOX/custom.env"
  export ENV_FILE="$SANDBOX/custom.env"
  unset BACKUP_DIR
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^DONE CONFIG ts=.* BACKUP_DIR=$SANDBOX/file-backups$"
}

@test "real env wins over the env file" {
  mkdir -p "$SANDBOX/file-backups" "$SANDBOX/env-backups"
  printf 'BACKUP_DIR=%s\n' "$SANDBOX/file-backups" >"$SANDBOX/custom.env"
  export ENV_FILE="$SANDBOX/custom.env"
  export BACKUP_DIR="$SANDBOX/env-backups"
  run bash "$SCRIPT_UNDER_TEST"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^DONE CONFIG ts=.* BACKUP_DIR=$SANDBOX/env-backups$"
}

@test "tool chatter is silent by default" {
  export DOCKER_SHIM_MODE="chatty"
  bash "$SCRIPT_UNDER_TEST" >"$SANDBOX/out.txt" 2>"$SANDBOX/err.txt"
  status="$?"
  [ "$status" -eq 0 ]
  ! grep -q "chatter" "$SANDBOX/err.txt"
  all_lines_grammar "$(cat "$SANDBOX/out.txt")"
}

@test "VERBOSE=1 sends tool chatter to stderr" {
  export DOCKER_SHIM_MODE="chatty"
  export VERBOSE="1"
  bash "$SCRIPT_UNDER_TEST" >"$SANDBOX/out.txt" 2>"$SANDBOX/err.txt"
  status="$?"
  [ "$status" -eq 0 ]
  grep -q "chatter" "$SANDBOX/err.txt"
  all_lines_grammar "$(cat "$SANDBOX/out.txt")"
}

@test "stdout carries only grammar lines" {
  bash "$SCRIPT_UNDER_TEST" >"$SANDBOX/out.txt" 2>"$SANDBOX/err.txt"
  status="$?"
  [ "$status" -eq 0 ]
  [ -s "$SANDBOX/out.txt" ]
  all_lines_grammar "$(cat "$SANDBOX/out.txt")"
}
