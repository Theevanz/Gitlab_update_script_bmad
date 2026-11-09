# test_helper.bash — shared fixtures for the gitlab-backup BATS suite.
#
# Every .bats file starts with:
#   source "$BATS_TEST_DIRNAME/test_helper.bash"
# which works under real BATS and under the offline probe runner alike.
#
# NOTE: keep every .bats file (and this helper) free of unbalanced braces
# inside strings and comments — the offline probe runner pairs braces naively.
# Spell out digit runs ([0-9][0-9]) instead of brace quantifiers in test greps.

SCRIPT_UNDER_TEST="$BATS_TEST_DIRNAME/../backup/gitlab-backup.sh"
ORIG_PATH="$PATH"

# A plausible-but-fake age recipient used only as fixture key material.
VALID_AGE_KEY="age1ql3z7hj432v2jl2z8alunwwun8hm4s4"

# --- sandbox: an isolated run root per test ----------------------------------
sandbox_setup() {
  SANDBOX="$(mktemp -d)"
  CALLS="$SANDBOX/calls"
  COMPOSE_DIR="$SANDBOX/compose"
  mkdir -p "$COMPOSE_DIR/volumes/config" "$COMPOSE_DIR/volumes/data/backups"
  mkdir -p "$COMPOSE_DIR/backups" "$SANDBOX/keys" "$SANDBOX/bin" "$CALLS"
  printf 'services:\n  gitlab:\n    image: gitlab-test\n' >"$COMPOSE_DIR/docker-compose.yml"
  printf 'FAKEVAR=1\n' >"$COMPOSE_DIR/.env"
  printf 'external_url "http://gitlab.test"\n' >"$COMPOSE_DIR/volumes/config/gitlab.rb"
  printf 'dummy-secret\n' >"$COMPOSE_DIR/volumes/config/gitlab-secrets.json"
  printf '%s\n' "$VALID_AGE_KEY" >"$SANDBOX/keys/nas.agepub"
  printf 'fake-ssh-key\n' >"$SANDBOX/keys/id_backup_ed25519"
  export BACKUP_DIR="$COMPOSE_DIR/backups"
  export COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
  export GITLAB_CONFIG_DIR="$COMPOSE_DIR/volumes/config"
  export GITLAB_DATA_DIR="$COMPOSE_DIR/volumes/data"
  export GITLAB_CONTAINER="gitlab-test"
  export NAS_HOST="nas.test"
  export NAS_USER="backup"
  export NAS_DIR="/backups/gitlab"
  export SSH_KEY_FILE="$SANDBOX/keys/id_backup_ed25519"
  export AGE_PUBKEY_FILE="$SANDBOX/keys/nas.agepub"
  export AGE_BIN="$SANDBOX/bin/age"
  export VERBOSE="0"
  export ENV_FILE="$SANDBOX/nonexistent.env"
  export CALLS SANDBOX
  export SANDBOX_REMOTE="$SANDBOX/remote"
  export SHIM_CALLS="$CALLS"
  export SHIM_DATA_DIR="$GITLAB_DATA_DIR"
  export DOCKER_SHIM_MODE="ok"
  export AGE_SHIM_MODE="ok"
  export RSYNC_SHIM_MODE="ok"
  export SSH_SHIM_MODE="ok"
  export FLOCK_SHIM_MODE="ok"
  unset DOCKER_SHIM_NO_TARBALL SSH_SHIM_SCRIPT RSYNC_SHIM_CORRUPT RSYNC_SHIM_DROP DATE_SHIM_TS
  PATH="$SANDBOX/bin:$ORIG_PATH"
  export PATH
}

sandbox_teardown() {
  rm -rf "$SANDBOX"
  # The rm above may have run through the rm shim (now deleted with the
  # sandbox); drop bash's hashed path so later rm calls re-resolve cleanly.
  hash -r
}

# --- guards -------------------------------------------------------------------
need_tool() {
  command -v "$1" >/dev/null 2>&1 || skip "needs $1 on PATH"
}

# --- docker double ------------------------------------------------------------
# Modes via DOCKER_SHIM_MODE: ok (default) | inspect-fail | exec-fail | chatty.
# DOCKER_SHIM_NO_TARBALL=1 makes exec succeed while producing nothing.
install_docker_shim() {
  cat >"$SANDBOX/bin/docker" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/docker.calls"
mode="${DOCKER_SHIM_MODE:-ok}"
if [ "$mode" = "chatty" ]; then
  echo "docker chatter on stdout"
  echo "docker chatter on stderr" >&2
fi
if [ "$1" = "inspect" ]; then
  if [ "$mode" = "inspect-fail" ]; then
    echo "Error: No such container" >&2
    exit 1
  fi
  echo '[{"Name":"/gitlab-test"}]'
  exit 0
fi
if [ "$1" = "exec" ]; then
  if [ "$mode" = "exec-fail" ]; then
    echo "backup failed" >&2
    exit 1
  fi
  if [ "${DOCKER_SHIM_NO_TARBALL:-0}" != "1" ]; then
    datadir="${GITLAB_DATA_DIR:-${SHIM_DATA_DIR:-/nonexistent}}"
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    printf 'fake gitlab backup payload %s\n' "$stamp" \
      >"$datadir/backups/${stamp}_gitlab_backup.tar"
  fi
  exit 0
fi
echo "docker shim: unexpected args: $*" >&2
exit 1
SHIM
  chmod +x "$SANDBOX/bin/docker"
}

# --- age double -----------------------------------------------------------------
# Records every call; copies input to output instead of sealing (crypto is the
# real binary's job). Modes via AGE_SHIM_MODE: ok (default) | fail.
install_age_shim() {
  cat >"$SANDBOX/bin/age" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/age.calls"
if [ "${AGE_SHIM_MODE:-ok}" = "fail" ]; then
  echo "age: boom" >&2
  exit 1
fi
out=""
in=""
keyfile=""
while [ $# -gt 0 ]; do
  case "$1" in
  -R)
    keyfile="$2"
    shift 2
    ;;
  -o)
    out="$2"
    shift 2
    ;;
  *)
    in="$1"
    shift
    ;;
  esac
done
if [ -z "$out" ] || [ -z "$in" ] || [ ! -f "$keyfile" ]; then
  exit 1
fi
cp "$in" "$out"
SHIM
  chmod +x "$SANDBOX/bin/age"
}

# --- rsync double ---------------------------------------------------------------
# Modes via RSYNC_SHIM_MODE: ok (default) | fail | mirror.
# mirror mode copies src contents into the mapped remote root for plumbing tests.
# RSYNC_SHIM_CORRUPT=1 flips a byte in the mirrored blob (proves hash-mismatch
# for real); RSYNC_SHIM_DROP=<name> skips one mirrored member (proves
# missing-member for real).
install_rsync_shim() {
  cat >"$SANDBOX/bin/rsync" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/rsync.calls"
mode="${RSYNC_SHIM_MODE:-ok}"
if [ "$mode" = "fail" ]; then
  echo "rsync: boom" >&2
  exit 1
fi
if [ "$mode" = "mirror" ]; then
  n=$#
  src="${!n}"
  n=$((n - 1))
  nsrc="${!n}"
  dst_path="$src"
  dst_path="${dst_path#*:}"
  mkdir -p "$SANDBOX_REMOTE$dst_path"
  cp -a "${nsrc}." "$SANDBOX_REMOTE$dst_path/"
  if [ -n "${RSYNC_SHIM_DROP:-}" ]; then
    rm -f "$SANDBOX_REMOTE$dst_path/$RSYNC_SHIM_DROP"
  fi
  if [ "${RSYNC_SHIM_CORRUPT:-0}" = "1" ]; then
    printf 'X' | dd of="$SANDBOX_REMOTE$dst_path/set.tar.age" bs=1 seek=0 conv=notrunc 2>/dev/null
  fi
fi
exit 0
SHIM
  chmod +x "$SANDBOX/bin/rsync"
}

# --- ssh double -------------------------------------------------------------------
# Modes via SSH_SHIM_MODE: ok (default) | fail | exec | scripted.
# exec mode runs the remote command locally with NAS_DIR mapped into the sandbox,
# proving the remote command strings are correct shell. scripted mode consumes
# outcomes (ok|fail, one per line) from $SSH_SHIM_SCRIPT in call order.
install_ssh_shim() {
  cat >"$SANDBOX/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/ssh.calls"
mode="${SSH_SHIM_MODE:-ok}"
if [ "$mode" = "scripted" ] && [ -f "${SSH_SHIM_SCRIPT:-}" ]; then
  outcome="$(head -n 1 "$SSH_SHIM_SCRIPT")"
  tail -n +2 "$SSH_SHIM_SCRIPT" >"$SSH_SHIM_SCRIPT.tmp"
  mv "$SSH_SHIM_SCRIPT.tmp" "$SSH_SHIM_SCRIPT"
  if [ "$outcome" = "fail" ]; then
    echo "ssh: boom" >&2
    exit 1
  fi
  exit 0
fi
if [ "$mode" = "fail" ]; then
  echo "ssh: boom" >&2
  exit 1
fi
if [ "$mode" = "exec" ]; then
  cmd="$4"
  mapped="$(printf '%s' "$cmd" | sed "s|$NAS_DIR|$SANDBOX_REMOTE$NAS_DIR|g")"
  sh -c "$mapped"
  exit $?
fi
exit 0
SHIM
  chmod +x "$SANDBOX/bin/ssh"
}

# --- flock double ---------------------------------------------------------------
# The script calls the real flock via PATH; tests shadow it so lock mechanics
# (not kernel exclusion) run everywhere. Modes via FLOCK_SHIM_MODE:
# ok (default) | fail. Real two-process exclusion is covered by a guarded test
# using the real binary instead of this shim.
install_flock_shim() {
  cat >"$SANDBOX/bin/flock" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/flock.calls"
if [ "${FLOCK_SHIM_MODE:-ok}" = "fail" ]; then
  echo "flock: failed to get lock" >&2
  exit 1
fi
exit 0
SHIM
  chmod +x "$SANDBOX/bin/flock"
}

# --- date double ------------------------------------------------------------------
# DATE_SHIM_TS pins the clock for collision tests. Installed selectively —
# never part of install_all_shims.
install_date_shim() {
  cat >"$SANDBOX/bin/date" <<'SHIM'
#!/usr/bin/env bash
if [ -n "${DATE_SHIM_TS:-}" ]; then
  printf '%s\n' "$DATE_SHIM_TS"
  exit 0
fi
command -p date "$@"
SHIM
  chmod +x "$SANDBOX/bin/date"
}

# --- cmp double -------------------------------------------------------------------
# Transparent passthrough unless CMP_SHIM_MODE=fail. Installed selectively.
install_cmp_shim() {
  cat >"$SANDBOX/bin/cmp" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/cmp.calls"
if [ "${CMP_SHIM_MODE:-ok}" = "fail" ]; then
  echo "cmp: boom" >&2
  exit 1
fi
command -p cmp "$@"
SHIM
  chmod +x "$SANDBOX/bin/cmp"
}

# --- rm double ------------------------------------------------------------------
# Transparent passthrough unless RM_SHIM_MODE=fail (every call fails) or
# fail-outside-staging (only removals outside .staging-* fail, so the ENCRYPT
# plaintext wipe passes while PRUNE victim removal fails). Installed
# selectively.
install_rm_shim() {
  cat >"$SANDBOX/bin/rm" <<'SHIM'
#!/usr/bin/env bash
calls="${CALLS:-${SHIM_CALLS:-/dev/null}}"
echo "$*" >>"$calls/rm.calls"
if [ "${RM_SHIM_MODE:-ok}" = "fail" ]; then
  echo "rm: boom" >&2
  exit 1
fi
if [ "${RM_SHIM_MODE:-ok}" = "fail-outside-staging" ]; then
  outside_staging=0
  for arg in "$@"; do
    case "$arg" in
    -*) : ;;
    *)
      case "$arg" in
      *.staging-*) : ;;
      *) outside_staging=1 ;;
      esac
      ;;
    esac
  done
  if [ "$outside_staging" = 1 ]; then
    echo "rm: boom" >&2
    exit 1
  fi
fi
command -p rm "$@"
SHIM
  chmod +x "$SANDBOX/bin/rm"
}

install_all_shims() {
  install_docker_shim
  install_age_shim
  install_rsync_shim
  install_ssh_shim
  install_flock_shim
}

# wb_stage runs one stage function in an isolated bash via the library guard:
# wb_stage <func> <ts> -- registry variables pass through the environment.
wb_stage() {
  GITLAB_BACKUP_LIB=1 bash -c 'source "$0"; TS="$1"; "$2" "$1"' "$SCRIPT_UNDER_TEST" "$2" "$1"
}
