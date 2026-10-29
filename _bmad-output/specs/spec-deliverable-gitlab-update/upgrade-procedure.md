# Upgrade Procedure

Phased step order the script mirrors, per the official GitLab upgrade guidance. Phase content is the contract; page prose stays on the docs pages.

## Phase 1 — Before you upgrade

Step 1, gather pre-upgrade information (read-only recon — learn, don't touch):

1. Detect current version; review the release/maintenance policy and the upgrade notes for every version to be passed (compatibility, deprecations).
2. Check OS compatibility with the target version.
3. Determine the upgrade path: next required stop after the detected current version from vendored `upgrade_path.yml` (major.minor only, no patch versions, no conditional-stop logic), then resolve the target to its latest patch (`X.Y.z` rule via Docker Hub tags API or packages page) and pin the exact image tag; every stop is taken as a normal stop including conditional ones. One stop per run: the operator re-runs to advance further. Demo: start at 16.11 latest patch, follow required stops toward the current 17.x chain — 2–3 real stops across the major boundary over repeated runs, never one jump. A `comments:` note on the target is shown with the plan and operator-acknowledged before any container change.
4. Create the rollback plan and verify the backup exists per `backup-contract.md`. Halt if absent.

Step 2, perform pre-upgrade steps (shortly before the upgrade — act):

1. Rerun the upgrade health checks (general config, migration status, secrets, database health, UI and CI checks per the docs). If any check fails: halt, write each issue to the log for a human to fix, re-run.
2. Pause CI/CD pipelines and jobs: pause runners, block new jobs, wait until all jobs finish.

## Phase 2 — Upgrade (one required stop per run)

The current stop, following the Docker upgrade page exactly:

1. Pause CI/CD pipelines and jobs (per Phase 1). (Maintenance mode is out of scope: Premium/Ultimate feature, Free-tier demo.)
2. Upgrade GitLab Runner to the target version. (Binary/container runner upgrades are out of scope for this deliverable; CI is quieted through the Runners API only.)
3. Upgrade GitLab itself via Compose: back up `docker-compose.yml`, edit it to the pinned image tag for this stop, then `docker compose pull`, `docker compose down`, and `docker compose up -d` (never `-v`). (The Docker Engine stop/remove/run path is the documented alternative for non-Compose installs — not taken here.)
4. Monitor health-during: heartbeat log, progress deltas, `/-/liveness`.
5. Wait for all batched background migrations `finished` (mandatory gate — leave time between stops; the next run re-checks before planning); re-run DB diagnostics immediately before each stop.
6. Verify health-after: version match, full backend checks, `/-/readiness?all=1`, smoke tests; then unpause CI and rerun the full upgrade health checks.

## Phase 3 — After the upgrade (close-out)

1. Rerun the full Phase 1 health checks; confirm runners unpaused and jobs flowing.
2. On failure: collect a `gitlabsos` + logs bundle and state the rollback story. (Troubleshooting/rollback detail and the Support handoff live on their own docs pages — referenced, not reimplemented.)
