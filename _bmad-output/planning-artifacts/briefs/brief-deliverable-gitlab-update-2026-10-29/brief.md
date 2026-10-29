---
title: "Product Brief: GitLab Stepwise Upgrade Runner (Docker, Bash)"
status: final
created: 2026-10-29
updated: 2026-10-29
---

# Product Brief: GitLab Stepwise Upgrade Runner (Docker, Bash)

## Executive Summary

Upgrading GitLab across major versions cannot be done in one jump: every instance must pass through a
documented chain of required stops, waiting for background database migrations to finish at each one, or
the schema breaks. In practice this is a manual, error-prone sequence of pinned installs, migration waits,
and health checks — with multi-day migrations on terabyte-scale instances where nobody can tell slow
progress from a hang.

This project builds a small, explainable Bash script that carries a Docker-based GitLab instance through its
full upgrade path, one required stop at a time, with health checks during each migration (liveness vs. hang)
and a proceed-gate after each stop (safe to continue or halt). The script follows the official GitLab upgrade
guidance as its gold standard — the credible path, not the happy path.

The primary audience is the author's intern mentor, an industry expert grading coding detail and technology
understanding. The learning outcome outranks feature count: every line must be explainable, every technology
choice defended, and the script stays deliberately small — no helper functions that obscure rather than
clarify. A follow-on deliverable (a backup script) plugs into a backup contract defined here.

## The Problem

Anyone running an old GitLab (16.x) that needs to reach a current release (17.x) faces three compounding
difficulties. First, the upgrade path is non-obvious: required stops are defined in `upgrade_path.yml`
(major.minor only — no patch versions, no conditional-stop logic), and the exact patch for each stop must be
resolved separately (docs rule: always the latest `X.Y.z`, via Docker Hub tags or the packages page). No
archive scraping is needed for this range. Second, each stop has a mandatory gate — all batched background
migrations `finished`
— skipping this gate corrupts the schema for the next stop. Third, large-instance migrations run for days with
no built-in signal distinguishing slow progress from a hang, while the system stays down.

Today this is done by hand: pin an image version, recreate the container, poll migration status, eyeball logs,
repeat. It works once, for one person, and teaches nothing. Community bash assistants, Ansible roles, and the
GitLab Environment Toolkit cover adjacent ground (provisioning, single flows) rather than stepwise gated
Docker upgrades. The gap this fills is a learning-grade, auditable runner that makes each step visible and
each gate explicit.

## The Solution

A POSIX Bash script (plus `curl`, with `jq` where available and a `grep` fallback) that upgrades a
single-node Docker GitLab instance through its required stops. Bash is deliberate: the task is orchestrating
`docker`/`gitlab-rake` subprocesses where Bash is the native grammar, every line is auditable, and an opaque
binary would fail the grading criterion — explainability. The run mirrors the official docs'
sequence — Phase 1 (Before you upgrade) → Phase 2 (the Docker upgrade page) → Phase 3 (After the upgrade) —
with the required-stop loop and per-stop gates inside Phase 2. (Background: the GitLab Docker image is
Omnibus packaged in a container — same concepts, container runtime instead of package manager.)

**Phase 1 — Before you upgrade (script: two steps, in page order):**

Step 1, gather pre-upgrade information (read-only recon — learn, don't touch):
1. Detect current version; review the release/maintenance policy and the upgrade notes for every version
   to be passed (compatibility, deprecations).
2. Check OS compatibility with the target version.
3. Determine the upgrade path: stop list from vendored `upgrade_path.yml` (major.minor only), then resolve
   each stop to its latest patch (`X.Y.z` rule via Docker Hub tags API or packages page) and pin exact
   image tags. Demo range: 16.x → 17.x — several sequential upgrades, never one jump.
4. Create the rollback plan and verify the backup exists (backup contract, see Scope). Halt if absent.

Step 2, perform pre-upgrade steps (shortly before the upgrade — act):
1. Rerun the upgrade health checks (general config, migration status, secrets, database health, UI and CI
   checks per the docs). If any check fails: halt, write each issue to the log for a human to fix, re-run.
   The script never upgrades a sick instance and never auto-remediates.
2. Pause CI/CD pipelines and jobs: pause runners, block new jobs, wait until all jobs finish.

**Phase 2 — Upgrade (script: stop loop, one iteration per required stop, Docker Compose procedure):**
Per stop, following the Docker upgrade page exactly:
1. Consider maintenance mode; pause CI/CD pipelines and jobs (per Phase 1).
2. Upgrade GitLab Runner to the target version.
3. Upgrade GitLab itself via Compose: edit `docker-compose.yml` to the pinned image tag, then
   `docker compose pull && docker compose up -d`. (The Docker Engine stop/remove/run path is the documented
   alternative for non-Compose installs — not taken here.)
4. Monitor health-during: heartbeat log, progress deltas, `/-/liveness`.
5. Wait for all batched background migrations `finished` (mandatory gate — leave time between stops);
   re-run DB diagnostics immediately before each stop.
6. Verify health-after: version match, `/-/readiness?all=1`, smoke tests; then unpause CI, turn off
   maintenance mode, and rerun the full upgrade health checks.

**Phase 3 — After the upgrade (script: close-out):**
1. Rerun the full Phase 1 health checks; confirm runners unpaused and jobs flowing.
2. On failure: collect a `gitlabsos` + logs bundle and state the rollback story. (Troubleshooting/rollback
   detail and the Support handoff live on their own docs pages — referenced, not reimplemented.)

## Who This Serves

- **Primary: the author**, an intern learning infrastructure scripting — needs a script small enough to
  fully understand and present, with each technology choice defensible under expert questioning (why Bash,
  why this phase order, why these health endpoints).
- **Evaluator: the intern mentor**, an industry expert — needs evidence of detailed coding craft and genuine
  technology understanding, not feature volume. Reads the brief, the code, and the demo; probes the halts,
  the endpoint choices, and the backup contract.
- **Secondary: future operators** of small Docker-based GitLab instances who want an auditable upgrade
  runner they can read before trusting.

## What Makes This Different

Honesty first: this is not competing with enterprise upgrade tooling, and its moat is not technical. The
differentiator is the constraint set: Bash-only (hard constraint — no Python, auditable line by line),
connected-environment Docker Compose single-node (the author's proven setup), and gating rigor
(detect-and-halt everywhere, liveness-vs-hang detection for long migrations). If
the advantage is discipline and explainability rather than novelty, the brief says so.

## Success Criteria

- The script carries a seeded Docker GitLab through 2–3 real required stops with zero unexplained behavior:
  every halt, wait, and proceed decision is logged with its reason.
- DONE-per-stop is demonstrated, not asserted: health-during shows heartbeat + progress deltas distinguishing
  slow from hung; health-after shows version match, background migrations all `finished`, `/-/readiness?all=1`
  green, and a git clone+push smoke test passing.
- One deliberately injected failure (disk pressure or a stalled migration) proves hang detection fires and
  the script halts with actionable logs.
- The author can present every line and every technology choice to the mentor without notes — this is
  assessed in the demo, not in CI.

## Scope

**In (this deliverable):** single-node GitLab on Docker Compose, upgrades with downtime, connected
environment; POSIX Bash + curl (+jq with grep fallback); vendored `upgrade_path.yml` for the 16.x → 17.x
demo range (2–3 real stops, no archive scraping — all stops in range) with latest-patch resolution per stop;
the three phases above (pre-flight → stop loop → close-out);
detect-and-halt behavior with issues reported to the log; backup *verification* against the documented
contract below (~15 lines: artifact check, freshness check, halt); demo with seeded sample data + one
injected failure.

**Explicitly out:** backup implementation (follow-on deliverable — the demo uses a hand-made backup
satisfying the contract, stated not hidden); zero-downtime / multi-node / Helm upgrades; other topologies
and optional components (Geo, external Gitaly, Elasticsearch, K8s agents — documented as known-but-out-of-scope);
auto-remediation of bad health.

**The backup contract (for the follow-on deliverable):** it must produce Docker volume snapshots plus
secrets/config copies at a known path, with a timestamp the upgrade script can freshness-check. The upgrade
script is the consumer that defines this contract; the backup project fulfills it.

## Vision

If this succeeds, the author has a presented, mentor-approved upgrade runner plus a second deliverable (the
backup script) that fulfills a defined contract — two small, fully understood tools instead of one large,
half-understood one. The pattern generalizes: health-first ordering, detect-and-halt gating, and
consumer-defined contracts are habits that transfer to any infrastructure automation the author builds next.
The script itself stays small on purpose; growth means more documented gates, never more magic.
