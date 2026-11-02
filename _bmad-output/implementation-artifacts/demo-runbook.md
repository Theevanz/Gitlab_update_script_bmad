# Demo Runbook: one-stop GitLab upgrade, live on the seeded instance

Story 4.4 evidence. The script is `runner/upgrade-gitlab.sh`; the stop list is
`runner/upgrade_path.yml`. Each run moves the instance exactly one required
stop. Run it once per stop (demo: 16.11 -> 17.1 -> 17.3 -> 17.5).

## What the demo host needs

- Linux with Docker Engine + Compose v2, and network access to GitLab (the
  instance itself), Docker Hub (tag lookup), and gitlab.com (failure bundle).
- The seeded GitLab 16.11 running from one compose file, reachable at
  `GITLAB_URL`, with the admin token (manage_runner right) and smoke token
  (write_repository right).
- A backup satisfying `backup-contract.md` (`data/`, `secrets/`,
  `BACKUP_CREATED_AT` epoch) no older than 24 h, OR `--nobackup` for a
  backup-less rehearsal (rollback story will say so).
- The seed project must exist at `SEED_PROJECT_PATH` (example: `seed/demo`)
  with a `main` branch AND a working CI config: the close-out step pushes an
  empty commit to main and then confirms jobs actually flow. Without CI, the
  run ends green with a loud warning instead of the flow confirmation.

## Settings (export once per shell)

```bash
export GITLAB_URL=https://gitlab.example.local
export GITLAB_ADMIN_TOKEN=<admin>
export GITLAB_SMOKE_TOKEN=<smoke>
export GITLAB_COMPOSE_FILE=/srv/gitlab/docker-compose.yml
export COMPOSE_SERVICE=gitlab
export BACKUP_PATH=/srv/gitlab-backup/latest
export SEED_PROJECT_PATH=seed/demo
```

## Stop 1: 16.11 -> 17.1 (carries a note, needs ACK)

```bash
./runner/upgrade-gitlab.sh --plan     # read-only rehearsal, changes nothing
./runner/upgrade-gitlab.sh            # live: prints 16.11.x -> 17.1.z + note
```

At the prompt, type exactly `ACK 17.1.z` (the printed target). Anything else
exits quietly with zero side effects. Then watch: pre-gate, runner pause +
drain, compose rewrite + recreate, heartbeat lines every 10 s, the 6-step
proceed gate, unpause, close-out. Exit 0 + `run complete` ends the stop.

## Stop 2 and 3: 17.1 -> 17.3 -> 17.5 (no notes, no prompts)

```bash
./runner/upgrade-gitlab.sh            # advances one stop, no ACK needed
./runner/upgrade-gitlab.sh            # advances the next stop
```

## Proving the hang verdict (live injection)

1. Start a run and wait for heartbeat lines (`hb elapsed_s=...`).
2. In another shell, stop postgres inside the container:
   `docker compose -f $GITLAB_COMPOSE_FILE exec -T $COMPOSE_SERVICE gitlab-ctl stop postgresql`
3. The next beat halts at once with `GATE='monitor'` naming the database
   backend, plus a failure bundle and the 4-line rollback story. Runners stay
   paused. Restart postgres, then re-run to continue (re-runs are idempotent).

A full 5-minute idle hang (30 flat beats) fires the same gate with
`migration wait hung`; a 306 s mock run proving it is kept at
`/tmp/hang-verdict-306s.log` (31 beats + verdict).

## If a run halts

- Read the single `GATE=` line: it names what was expected, seen, and what
  to do next.
- Open `./failure-bundle-<target>-<epoch>/` (gitlabsos report, or the native
  manifest: log tail, container detail, replayed health lines, rake table).
- Follow the 4 `rollback:` log lines (backup source, image-revert sed,
  restart command, unpause as HUMAN-ACTION). The script never rolls back or
  unpauses on its own after a failure.

## Known residual risks (stated, not hidden)

- `compose exec` calls carry no timeout: a fully wedged container could stall
  a rake read instead of failing it. Heartbeats visibly stop; Ctrl-C still
  halts in-format through the signal trap.
- The demo backup is hand-made per the backup contract until the follow-on
  backup producer lands; `--nobackup` exists only for pre-producer testing.
