# gitlab-update

POC: upgrade a Docker Compose GitLab safely, one required stop per run, with proof it worked.

Three parts, each standalone:

| Dir | Does |
|---|---|
| `runner/` | Upgrades GitLab one stop. Gates, mutates, monitors, proves. |
| `gitlab-backup/` | Produces one encrypted, verified backup set. Feeds the runner's gate. |
| `test-gitlab-server/` | Seeded demo GitLab to run it all against. |

## Functional requirements

**runner/ — upgrade-gitlab.sh**

- Resolves live version (API) → next stop (vendored YAML) → latest patch (Hub tags).
- Operator ACKs exact target. `--plan` rehearses read-only, changes nothing.
- Pre-gate: health green, migrations finished, backup fresh (≤24h), CI paused + drained.
- Mutates: compose backup, sed pin, pull, down/up.
- Monitors: 10s heartbeats. Hang = 5 min flat progress + idle box. Backend 503 halts fast.
- Proves: version match, rake finished, health, readiness, clone-push smoke test, unpause.
- Close-out: re-checks on success; failure bundle + rollback story on failure.
- One `die()`: uniform halts, lock, secrets never on argv.

**gitlab-backup/ — gitlab-backup.sh**

- Captures: native tarball + whole config volume + compose + `.env`.
- Seals: one tar, one `age` encryption. No plaintext leaves host.
- Hashes: one SHA-256 over the blob.
- Ships blob + hash to NAS as one unit; re-verifies remote hash.
- Prunes: newest 2 local sets survive, only after verified ship.
- Any failure: exit 1, no partials anywhere.

**test-gitlab-server/**

- Pinned compose GitLab + seed data + `healthcheck.sh` probe.
- Prints demo-shell exports; pairs with the runbook in `_bmad-output/`.

## Health checks

**Docker first (Layer 0), HTTP second.** Container state before trusting any probe: `compose ps` + `inspect` (Running / Restarting / Exited + code). Refused/timeout resolves through container state, never reads as "probe failed." 10-min grace for `/-/health` after `up -d`. Exited = halt with exit code + log tail. 404-while-Running = allowlist-suspect.

**Docker telemetry** rides every 10s heartbeat (`docker stats --no-stream`, one sample): CPU, mem, block I/O, net I/O. Never gates alone — feeds the hang verdict: 5 min flat rake progress + CPU ~0 + block I/O unchanged = wedged, halt.

Each endpoint proves one thing:

| Endpoint | Proves |
|---|---|
| `/-/health` | Server alive (`GitLab OK`) |
| `/-/liveness` | Controllers not deadlocked (200 vs 503) |
| `/health_check`, `/database`, `/cache` | Backends reachable (`success`) |
| `/-/readiness?all=1` | Ready for traffic, per-service statuses |
| rake `background_migrations:status` | All migrations `finished` |

Gates:

- **Pre:** all green + backup fresh + CI paused/drained. Else no touch.
- **During:** readiness expected red, never gated. Gate on health + liveness + db + cache. Liveness 503 or backend fail halts at once.
- **Proceed (in order):** version match → rake finished → `/health_check` → readiness all=1 → clone-push smoke → re-check, then unpause.
- **Close-out:** full re-check on success; failure bundle + rollback story on failure. Runners stay paused on failure.

(`test-gitlab-server/healthcheck.sh` mirrors this standalone: container running + 4 endpoints + admin API auth, exit 0/1.)

## Setup

Needs: docker + compose v2, curl, git, 10GB free.

```bash
cd test-gitlab-server
cp .env.example .env        # set GITLAB_ROOT_PASSWORD
./setup.sh                  # pulls ~1.3GB, boots ~5-10 min, seeds tokens + seed/demo
```

Paste the exports `setup.sh` prints, then from `runner/`:

```bash
./upgrade-gitlab.sh --plan  # rehearse, changes nothing
./upgrade-gitlab.sh         # live: one stop
```

Backup (feeds the gate; runner auto-runs it if missing/stale):

```bash
cd ../gitlab-backup/backup
cp backup.env.example backup.env   # point paths, NAS host, key files
./gitlab-backup.sh                 # one set: <BACKUP_DIR>/<ts>/
```
