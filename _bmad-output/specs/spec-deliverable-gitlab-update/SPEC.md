---
id: SPEC-deliverable-gitlab-update
companions:
  - upgrade-procedure.md
  - health-gates.md
  - backup-contract.md
sources:
  - _bmad-output/planning-artifacts/briefs/brief-deliverable-gitlab-update-2026-10-29/brief.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# GitLab Stepwise Upgrade Runner (Docker, Bash)

## Why

Upgrading a Docker-based GitLab across major versions (16.x → 17.x) cannot be done in one jump: every instance must pass through a documented chain of required stops and wait for batched background migrations to finish at each one, or the schema corrupts — yet in practice this is a manual, error-prone sequence of pinned installs, migration polls, and eyeballed logs, with terabyte-scale migrations running for days and no built-in signal separating slow progress from a hang. This spec exists to produce a small, explainable Bash runner that makes each step visible and each gate explicit. The forcing function is a learning mandate: the author's intern mentor grades coding detail and technology understanding, so explainability outranks feature count and every line must be presentable without notes.

## Capabilities

- **CAP-1**
  - **intent:** Operator obtains the next required stop with its exact pinned image, so no required stop is skipped and no version floats.
  - **success:** Printed plan shows the one hop from detected current to the next required stop per `upgrade_path.yml`, and the target is an exact `X.Y.z` latest-patch tag resolvable to a published image.
- **CAP-2**
  - **intent:** Script verifies pre-upgrade health and backup-contract compliance before changing anything, so a sick or unbacked-up instance is never upgraded (outside `--nobackup` testing).
  - **success:** With any failing health check or (without `--nobackup`) a backup artifact missing or older than 24 hours, the run halts before any container change and the log names each failing item.
- **CAP-3**
  - **intent:** Script advances the instance exactly one required stop per run, so the stop gets its own migration window.
  - **success:** Each run changes the container image exactly once, to the planned target, with one migration wait; the operator re-runs to advance further, never two stops in a single run.
- **CAP-4**
  - **intent:** Operator can distinguish slow migration progress from a hang during each stop's wait.
  - **success:** Health-during emits a heartbeat with runtime telemetry (status, elapsed time, CPU, memory, block/network I/O) every 10 s, plus `/-/health` OK plus `/-/liveness` 200 plus backend sub-checks with progress deltas across the wait; no deltas and flat telemetry for 5 minutes means hung; a refused connection resolves through container state (starting vs crashed), and an injected stall triggers a halt with an actionable log instead of silent waiting.
- **CAP-5**
  - **intent:** Script allows continuation past a stop only when that stop is demonstrably done.
  - **success:** Proceed-gate passes only with version match, all batched background migrations `finished`, `/health_check` success, `/-/readiness?all=1` green with per-service statuses, and the seeded-project `main` clone-and-push smoke test passing; otherwise the run halts.
- **CAP-6**
  - **intent:** Script closes out every run with re-verified health, or with a diagnostics bundle plus rollback story on failure, so the run stays auditable.
  - **success:** A passing run ends with the full health re-check, runners unpaused, and jobs flowing; a failing run produces a `gitlabsos` + logs bundle and states the rollback story.

## Constraints

- POSIX Bash plus `curl`, with `jq` where available and a `grep` fallback; no Python — line-by-line auditability is the grading criterion.
- Single-node Docker Compose with downtime, in a connected environment; the Docker Engine stop/remove/run path is the documented alternative for non-Compose installs — not taken here.
- Maintenance mode is out of scope: it is a Premium/Ultimate feature and the demo runs on the Free tier; the instance is quiesced by downtime plus paused CI plus container recreation instead.
- The official GitLab upgrade guidance Phase 1 → Phase 2 → Phase 3 ordering is the gold-standard sequence the script mirrors.
- Detect-and-halt everywhere with each issue written to the log for a human to fix; the script never upgrades a sick instance and never auto-remediates.
- Backup verification is limited to ~15 lines against the contract in `backup-contract.md`; backup implementation belongs to the follow-on deliverable.
- Runner binary/container upgrades are out of scope; CI is quieted through the Runners API only.
- Script stays deliberately small with no obscuring helpers; every line and every technology choice must be defensible under expert questioning.
- Health gates follow the official health-check endpoint semantics: comprehensive `/health_check` checks for monitoring only, readiness for traffic decisions, liveness for deadlock detection, localhost plus allowlist for access.

## Non-goals

- Backup implementation — the demo uses a hand-made backup satisfying the contract, stated not hidden.
- Zero-downtime, multi-node, and Helm upgrades.
- Maintenance mode (Premium/Ultimate feature; Free-tier demo).
- Other topologies and optional components: Geo, external Gitaly, Elasticsearch, K8s agents.
- Auto-remediation of bad health; troubleshooting/rollback detail and Support handoff beyond the failure bundle and rollback statement.
- Archive scraping for stops outside the demo range; competing with enterprise upgrade tooling on novelty.

## Success signal

A seeded Docker GitLab is carried from 16.11 through the required stops to the current 17.x chain, one stop per run, with DONE-per-stop demonstrated (10 s heartbeats with telemetry, version match, migrations `finished`, `/health_check` success, readiness `all=1` green, seeded-project `main` clone-and-push), one injected failure proves the 5-minute hang detection halts with actionable logs, and the author presents every line and choice to the mentor without notes.

