# test-gitlab-server — seeded GitLab for the upgrade demo (currently 17.5.5)

Everything lives in this folder: compose file, volumes, backup, settings.

## Quick start

```bash
cd test-gitlab-server
cp .env.example .env
# set GITLAB_ROOT_PASSWORD in .env
./setup.sh
```

First run pulls ~1.3GB and boots ~5–10 min. Re-runs are safe.

## Layout

- `docker-compose.yml` — pinned `gitlab/gitlab-ce:17.5.5-ce.0` (`container_name: test-gitlab-server`)
- `volumes/{config,logs,data}` — bind-mounted GitLab data (all in this folder)
- `backups/` — legacy hand-made seed (`1793610538` + `latest`) plus `gitlab-backup` pipeline sets (`<YYYYMMDD-HHMMSS>/` holding `set.tar.age` + `SHA256SUMS`)
- `keys/` — backup transport key (Ed25519 private, 600) + NAS age public file; private material must never be committed
- `.env` — real settings incl. tokens (gitignored, never commit)
- `healthcheck.sh` — liveness probe: container + 4 health endpoints + admin API auth (exit 0 = healthy, 1 = unhealthy)

## Demo shell

`setup.sh` prints the exports at the end; paste them, then follow
`_bmad-output/implementation-artifacts/demo-runbook.md`. The exports are:

```bash
# run from test-gitlab-server/ (tokens live in .env after setup.sh)
export GITLAB_URL="$(grep '^GITLAB_URL=' .env | cut -d= -f2-)"
export GITLAB_ADMIN_TOKEN=<from .env>
export GITLAB_SMOKE_TOKEN=<from .env>
export GITLAB_COMPOSE_FILE=$PWD/docker-compose.yml
export COMPOSE_SERVICE=gitlab
export BACKUP_PATH=$PWD/backups
export SEED_PROJECT_PATH=seed/demo
# optional: producer paths (the runner defaults resolve the same checkout)
export BACKUP_SCRIPT=$PWD/../gitlab-backup/backup/gitlab-backup.sh
export BACKUP_ENV_FILE=$PWD/../gitlab-backup/backup/backup.env
```

`BACKUP_PATH` is the sets root: the gate reads `<YYYYMMDD-HHMMSS>/`
pipeline sets directly under it. The legacy `backups/latest` seed no
longer satisfies the gate and is ignored.

## Backup gate

- Fresh set (both members present, at most 24 h old): the gate passes
  and the producer never runs.
- Missing or stale: on a live run the first pre-gate wave (before pause)
  runs the producer once, zero-arg, then re-checks; the gate passes only
  if the re-check is green. The runner pins `BACKUP_DIR` to `BACKUP_PATH`
  for that run, so the new set lands where the gate checks.
- `--plan` never runs the producer: rehearsal reports the live run would
  run it, then halts naming the backup cause.
- `--nobackup` skips backup loudly with no check and no run.
- Later waves (after the drain, before unpause, close-out) are
  check-only: a set that goes stale mid-run halts, never produces.

## Teardown

```bash
cd test-gitlab-server
docker compose down                          # keep data
docker compose down && rm -rf volumes/ backups/   # full wipe
```

## Notes

- No GitLab Runner here: pause is a no-op and close-out takes the
  documented loud-warning path instead of jobs-flowing confirmation.
- Admin token uses `api` scope (covers the manage_runner right the
  runner needs); smoke token uses read/write_repository.
- Full wipe deletes local pipeline sets too (`backups/`), while `keys/`,
  `.env`, and NAS copies survive.
