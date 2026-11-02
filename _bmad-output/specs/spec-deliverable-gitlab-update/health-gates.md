# Health Gates

Gold standard: the official health-check page (`https://docs.gitlab.com/administration/monitoring/health_check/`). Every gate is detect-and-halt: a failing gate stops the run and names each issue in the log. No gate auto-remediates.

## Access prerequisite

Probes require the client IP on the monitoring allowlist and default to localhost. The script probes from localhost — confirmed reachable for the demo with no allowlist change required. An unreachable endpoint still halts with a logged reason: unexpected HTTP 404 while the container is Running reads allowlist-suspect (the monitoring allowlist renders 404 for non-allowlisted clients), otherwise a service failure. Probes run over plain HTTP from localhost per the docs' local URLs.

## Endpoint roles (one line each — confusing them is the classic failure)

| Endpoint | What it proves | What it does NOT prove |
|---|---|---|
| `GET /-/health` | App server is running; bypasses Rails controllers via early `BasicHealthCheck` middleware | Nothing about database, Redis, or filesystem |
| `GET /-/liveness` | Rails controllers are not deadlocked (multi-threading alive); `200 {"status":"ok"}` vs `503` | Whether the instance can serve traffic or backends are healthy |
| `GET /-/readiness` | Instance is ready to accept traffic via Rails controllers; instance-checks only by default; `503` on failure | Health of dependent services (needs `all=1`) |
| `GET /-/readiness?all=1` | Above plus dependent services (Database, Redis, Gitaly, etc.) with a per-service status; `503` on failure | Migration progress detail |
| `GET /health_check`, `/health_check/database`, `/health_check/cache`, `/health_check/migrations` | Backend stack via the `health_check` gem: database connectivity, Redis cache, migration status; `success` vs failure message | Suitability for traffic decisions — never use for load balancing or autoscaling |

Readiness and liveness checks are exempt from Rack Attack. Do not use these endpoints as an uptime measure on large deployments (autoscaling and node churn produce false negatives); for this single-node runner they are gate signals, not uptime metrics.

## Layer 0 — container runtime (below HTTP, answers when the system is down)

All five HTTP probes need a listening server: a down container yields identical connection-refused/timeout on every endpoint. So the script checks the runtime before interpreting any probe. Layer 0 answers healthy-vs-sick; this layer answers starting-vs-crashed.

| Signal | Source | Meaning |
|---|---|---|
| Container state | `docker compose ps` / `docker inspect` (Running, Restarting, Exited + exit code) | Whether the process exists at all |
| Bring-up result | Exit status of `pull` / `up -d` | Whether the new image even started |
| Log tail | `docker compose logs --tail` on failure | Crash reason when state is Exited (bad tag, failed migration, OOM) |

Rules:

- A refused connection or timeout is never read as "just another failed probe" — the script resolves it through container state first.
- Expected-down: right after `up -d`, the server is legitimately not listening yet. The script waits up to 10 minutes for `/-/health` to answer before declaring startup failed.
- Crashed: state Exited (or Restarting past the timeout) means halt with the exit code and log tail in the log — no point polling HTTP probes against a dead container.
- Every poll records Layer 0 state alongside the HTTP results, so the log shows the full picture: container Running + probes failing = sick; container Exited + probes refused = down.

## Pre-upgrade gate (before any container change)

All must hold:

- `/-/health` returns `GitLab OK` (server alive).
- `/health_check` reports `success`; on failure the log carries the gem's failure message (e.g. database unreachable).
- `/health_check/migrations` confirms no leftover unfinished migrations from a prior stop.
- Batched background migrations all `finished`, via the `gitlab-rake gitlab:background_migrations:status` table (single signal; zero rows means clear).
- Backup-contract verification passes (see `backup-contract.md`; skipped loudly under `--nobackup`).
- CI/CD paused: runners paused, new jobs blocked, running jobs finished.

## Health-during (inside each stop's migration wait)

Readiness is expected to fail while migrations run — gating health-during on readiness green would halt every healthy upgrade. Gate health-during on Layer 0 plus:

| Signal | Pass criterion | Purpose |
|---|---|---|
| Container Running | `compose ps` shows Running, not Exited/Restarting-looping | Process exists before HTTP means anything |
| Container telemetry | Recorded on every heartbeat (never gates, always observed — see below) | Runtime context for the hang verdict |
| `/-/health` | `GitLab OK` on each poll | Server still alive |
| `/-/liveness` | HTTP `200` with `{"status":"ok"}` | Controllers not deadlocked; `503` means halt |
| `/health_check/database` | `success` | Database reachable through the wait |
| `/health_check/cache` | `success` | Redis reachable through the wait |
| `/health_check/migrations` | Observed and logged over time; informational only | Migration sub-check movement does NOT feed the progress-delta signal (deltas come from the rake table alone) |
| Heartbeat log entries | Emitted every 10 s (heartbeat = stats poll interval) | Proof the monitor itself is alive while the system is down |
| Progress deltas (batched migration polls) | Successive 10 s polls compared; movement = slow, no movement for 5 minutes = hung | Distinguish slow progress from a hang |

### Migration telemetry (observability, not gating)

`docker stats` never passes or fails a gate — it rides on every heartbeat entry so a hung migration shows flat resource curves next to flat progress deltas. One line per heartbeat, from `docker stats --no-stream` (or `docker compose stats` where available) plus container start time:

| Field | Source | Why it matters |
|---|---|---|
| Status + elapsed runtime | `compose ps` state plus container `StartedAt` (now minus started = wall-clock in-migration time) | How long this stop's wait has actually run |
| CPU % | `docker stats` CPU column | Migration working (sustained CPU) vs wedged (near-zero CPU with no progress) |
| Memory usage / limit | `docker stats` MEM USAGE / LIMIT column | Leak or pressure building across a multi-day wait |
| Block I/O | `docker stats` BLOCK I/O column | Database write activity; flat I/O plus flat deltas strengthens the hung verdict |
| Network I/O | `docker stats` NET I/O column | Expected near-idle on single-node; unexpected traffic is worth logging |

Hang verdict reads telemetry *with* progress deltas, never alone: 30 consecutive 10 s heartbeats (5 minutes) with zero finished-count movement plus CPU integer-part zero plus block-I/O raw string unchanged = hung, halt; a `/-/liveness` 503 or a failing `/health_check/database` or `/health_check/cache` halts immediately without waiting out the window. Telemetry lines stay terse (single log line per 10 s heartbeat, ~8640 lines/day) so multi-day waits stay greppable.

An injected failure (disk pressure or a stalled migration) must surface as flat deltas and/or failing backend sub-checks, fire hang detection, and halt with actionable logs.

## Proceed gate (after the stop, before close-out)

All must hold, in this order:

1. Version matches the pinned tag for this stop (API value normalized per AD-3; edition re-asserted).
2. All batched background migrations report `finished` (rake table per AD-10).
3. `/health_check` reports `success` (full backend stack, not just the instance).
4. `/-/readiness?all=1` is green with per-service statuses recorded to the log — instance-ready without backend-ready is unsafe.
5. Smoke test passes: git clone + push against the seeded project's `main` branch.
6. Full upgrade health checks re-run green; then unpause all runners (success path only).

## Close-out gate (end of run)

- Full Phase 1 health checks re-run (pre-upgrade gate criteria again); runners unpaused and jobs flowing.
- On failure instead: `gitlabsos` + logs bundle collected — including the recorded `/-/readiness?all=1` per-service statuses and the `/health_check` failure messages — and the rollback story stated. Failure leaves runners paused (unpause-all is success-path only).
