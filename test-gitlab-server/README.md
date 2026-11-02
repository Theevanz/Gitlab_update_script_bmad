# test-gitlab-server — fake seeded GitLab 16.11 for the upgrade demo

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

- `docker-compose.yml` — pinned `gitlab/gitlab-ce:16.11.10-ce.0`
- `volumes/{config,logs,data}` — bind-mounted GitLab data (all in this folder)
- `backups/<stamp>/` + `backups/latest` — hand-made backup (stated, not hidden)
- `.env` — real settings incl. tokens (gitignored, never commit)
- `healthcheck.sh` — liveness probe: container + 4 health endpoints + admin API auth (exit 0 = healthy, 1 = unhealthy)

## Demo shell

`setup.sh` prints the 7 exports at the end; paste them, then follow
`_bmad-output/implementation-artifacts/demo-runbook.md`. The 7 exports are:

```bash
# run from test-gitlab-server/ (tokens live in .env after setup.sh)
export GITLAB_URL="$(grep '^GITLAB_URL=' .env | cut -d= -f2-)"
export GITLAB_ADMIN_TOKEN=<from .env>
export GITLAB_SMOKE_TOKEN=<from .env>
export GITLAB_COMPOSE_FILE=$PWD/docker-compose.yml
export COMPOSE_SERVICE=gitlab
export BACKUP_PATH=$PWD/backups/latest
export SEED_PROJECT_PATH=seed/demo
```

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
