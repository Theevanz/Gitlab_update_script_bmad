# Sprint Plan — deliverable-gitlab-update

- Generated: 11-02-2026 11:43
- Project: deliverable-gitlab-update
- Readiness gate: **PASS**
- Epic source: `_bmad-output/planning-artifacts/epics.md`
- Tracking file: `_bmad-output/implementation-artifacts/sprint-status.yaml` (validated: format OK)

## Intent and motivation

Upgrading a Docker-based GitLab across majors (16.x → 17.x) cannot be done in one jump:
every instance must pass through a documented chain of required stops and wait for
batched background migrations to finish at each one, or the schema corrupts. In practice
this is a manual, error-prone sequence of pinned installs, migration polls, and eyeballed
logs, with large-instance migrations running for days and no built-in signal separating
slow progress from a hang.

This sprint builds a small, explainable Bash runner that carries a single-node Docker
Compose GitLab exactly one required stop per run, with health checks during each
migration wait (liveness vs. hang) and a proceed-gate after each stop (safe to continue
or halt). The run mirrors the official GitLab upgrade guidance Phase 1 → Phase 2 →
Phase 3 as its gold standard.

The forcing function is a learning mandate: the intern mentor grades coding detail and
technology understanding, so explainability outranks feature count — every line and
every technology choice must be presentable without notes.

Sources: `brief.md` (Executive Summary, Problem, Solution),
`SPEC.md` (Why, Success signal).

## Context and contract

**Capabilities (from `SPEC.md`):**

- CAP-1: next required stop with exact pinned image (one hop, no skipped stop, no floating tag)
- CAP-2: pre-upgrade health + backup-contract verification before any container change
- CAP-3: exactly one required stop per run, one migration window each
- CAP-4: slow-vs-hung distinction via 10 s heartbeats with telemetry + progress deltas
- CAP-5: proceed-gate (version, migrations finished, backends, readiness all=1, clone-and-push smoke)
- CAP-6: close-out with re-verified health, or diagnostics bundle + rollback story on failure

**Architecture (from `ARCHITECTURE-SPINE.md`, AD-1–AD-16):**

Gated sequential pipeline, fail-fast, no branches around gates, no state file, every
phase re-derives state from the live instance:

`validate → plan (+ note ACK) → pre-gate → pause/drain → mutate → monitor → proceed (unpause at step 6) → close-out`

Key decisions: single self-contained Bash file + vendored `upgrade_path.yml` (AD-1);
one stop per run (AD-2); version from live API with normalization (AD-3); stop list via
grep/sed over pinned YAML shape (AD-4); every stop normal, notes ACKed up front (AD-5);
env-var config with strict startup validation, mkdir lock, curl `-K` secrets (AD-6);
Layer-0-first channel discipline (AD-7); one `die()` halt contract (AD-8); compose
backup + in-place sed + pull/down/up (AD-9); rake table as single migration signal
(AD-10); seeded runs + read-only `--plan` verification, no unit harness (AD-11);
failure bundle fetched at failure time with native fallback (AD-12); Runners API
pause, unpause-all on success only (AD-13); Hub tags latest-patch pin, fail-closed
(AD-14); backup verification against pinned demo layout (AD-15); hang verdict from
deltas + telemetry with fast backend halts (AD-16).

**Structural seed:** `runner/upgrade-gitlab.sh` + `runner/upgrade_path.yml`.
**Stack:** Bash 3.2+ (POSIX-sh subset) + curl (+jq with grep fallback) + git +
docker/compose CLIs only; no Python.

**Out of scope (must not generate work):** backup implementation (follow-on
deliverable; this runner only verifies the contract), zero-downtime/multi-node/Helm,
maintenance mode (Premium+), Geo/external Gitaly/Elasticsearch/K8s agents, Runner
binary upgrades, retry/resume within a stop, troubleshooting detail beyond the bundle
+ rollback statement, archive scraping, secrets manager.

## Readiness gate: PASS

**Inventory scanned:**

- `_bmad-output/planning-artifacts/briefs/brief-deliverable-gitlab-update-2026-10-29/brief.md`
- `_bmad-output/specs/spec-deliverable-gitlab-update/SPEC.md`, `upgrade-procedure.md`, `health-gates.md`, `backup-contract.md`
- `_bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md`, `BUILD-NOTES.md`
- `_bmad-output/planning-artifacts/epics.md` (FR1–FR4, FR6–FR19; FR5 removed/merged into FR7; NFR1–NFR10)
- `docs/` (project_knowledge): absent, skipped gracefully — no decisions depend on it
- No UX artifact: correct, Bash CLI with no UI; the only operator interaction (`Type ACK <stop> to proceed:`) is covered by FR4/AD-5

**Checks:**

- Traceability: every FR maps to at least one story per the epics coverage map; every story traces back to FRs/NFRs/ADs; no orphan stories, no uncovered FRs. CAP-1–CAP-6 all bound in the architecture map.
- Epic shape: 4 epics in pipeline order, each delivers operator value, no forward dependencies; stories are independently completable increments (Epic 1 demos end-to-end once 1.4–1.7 land; Story 4.4 is the final seeded-instance proof).
- Recorded decisions: all probe contracts (byte-identical jq/grep pairs), log/die formats, GATE vocabulary, hang-counter pseudocode, failure-path exec lines, and env validation order are recorded in the spine, `BUILD-NOTES.md`, or `health-gates.md` — nothing is assumed.
- Conflicts: none blocking. Two reconciled wordings noted, not resolved silently: (1) brief Phase 2 mentions maintenance mode / Runner upgrades, while SPEC + `upgrade-procedure.md` explicitly scope both out (Free-tier demo; Runners API quiet only) — the procedure doc is the binding refinement; (2) `health-gates.md` lists `/health_check/migrations` alongside the rake table for the pre-gate, while epics/AD-10 make the rake table the single migration signal — Story 2.3's `/health_check` success + rake all-finished covers both readings with no invented decision.

**Generator warnings (accepted, no rerun needed):** two `unparsed Epic/Story-like heading`
notices for the document title (`# deliverable-gitlab-update - Epic Breakdown`) and the
`## Epic List` section header — neither is an epic or story, so the omission is correct.

## Sprint tracking

- Epics: 4 | Stories: 17 | Retrospectives: 4 | Total entries: 25
- Status breakdown: `backlog` 21 (4 epics + 17 stories), `optional` 4 (retrospectives)
- Upgraded from disk: none (fresh file, no story files on disk yet)
- Dropped orphans / illegal / legacy-mapped: none

### Epic 1: Safe Upgrade Planning (`epic-1`: backlog)

Operator validates the environment and previews the exact one-stop plan without
changing anything. Foundation epic: 1.1–1.3 are substrate; the epic demos end-to-end
via `--plan` once 1.4–1.7 land.

| Story | Key | Status |
|---|---|---|
| 1.1 Script skeleton with loud, consistent halts | `1-1-script-skeleton-with-loud-consistent-halts` | backlog |
| 1.2 Strict startup configuration and single-run lock | `1-2-strict-startup-configuration-and-single-run-lock` | backlog |
| 1.3 Probe library with Layer-0-first discipline | `1-3-probe-library-with-layer-0-first-discipline` | backlog |
| 1.4 Stop-list extraction from vendored YAML | `1-4-stop-list-extraction-from-vendored-yaml` | backlog |
| 1.5 Current version detection and next-stop lookup | `1-5-current-version-detection-and-next-stop-lookup` | backlog |
| 1.6 Latest-patch pin via Hub tags API | `1-6-latest-patch-pin-via-hub-tags-api` | backlog |
| 1.7 Plan print, note acknowledgement, and read-only --plan | `1-7-plan-print-note-acknowledgement-and-read-only-plan` | backlog |
| Retrospective | `epic-1-retrospective` | optional |

### Epic 2: Pre-Upgrade Protection (`epic-2`: backlog)

Runner verifies the instance is healthy, backed up, and quiet before touching it.
Runtime order: backup verification (2.1) + health pre-checks (2.3) first, then pause
and drain (2.2), then the final all-green assert (2.3).

| Story | Key | Status |
|---|---|---|
| 2.1 Backup-contract verification | `2-1-backup-contract-verification` | backlog |
| 2.2 CI quiet via Runners API | `2-2-ci-quiet-via-runners-api` | backlog |
| 2.3 Pre-upgrade health gate (final pre-mutate assert) | `2-3-pre-upgrade-health-gate-final-pre-mutate-assert` | backlog |
| Retrospective | `epic-2-retrospective` | optional |

### Epic 3: One-Stop Upgrade with Hang-Aware Monitoring (`epic-3`: backlog)

Runner advances the instance exactly one required stop and watches the migration wait
with heartbeats and progress deltas, halting on hang instead of waiting silently.

| Story | Key | Status |
|---|---|---|
| 3.1 One-stop container mutation | `3-1-one-stop-container-mutation` | backlog |
| 3.2 Migration-wait monitor with heartbeat telemetry | `3-2-migration-wait-monitor-with-heartbeat-telemetry` | backlog |
| 3.3 Hang detection with fast backend halts | `3-3-hang-detection-with-fast-backend-halts` | backlog |
| Retrospective | `epic-3-retrospective` | optional |

### Epic 4: Proof of Done and Close-Out (`epic-4`: backlog)

Runner proves the stop is complete through the ordered proceed gate, resumes CI only
on success, and closes every run with re-verified health or a diagnostics bundle plus
rollback story.

| Story | Key | Status |
|---|---|---|
| 4.1 Ordered proceed gate (proof of done) | `4-1-ordered-proceed-gate-proof-of-done` | backlog |
| 4.2 Recheck, unpause, and success close-out | `4-2-recheck-unpause-and-success-close-out` | backlog |
| 4.3 Failure bundle and rollback story | `4-3-failure-bundle-and-rollback-story` | backlog |
| 4.4 Demonstrated proof on the seeded instance | `4-4-demonstrated-proof-on-the-seeded-instance` | backlog |
| Retrospective | `epic-4-retrospective` | optional |

Implementation order is epic order (1 → 2 → 3 → 4); within an epic, story-number
order, except Epic 2 runtime interleaving noted above (implement 2.1, 2.2, 2.3; at
runtime 2.3's pre-checks run both before and after 2.2).

## Next steps

1. Review `_bmad-output/implementation-artifacts/sprint-status.yaml` — the
   deterministic source of truth for sprint state.
2. Start implementation with `bmad-build` on Story 1.1 (skeleton + halt contract);
   epics transition to `in-progress` automatically when their first story starts.
3. Rerun this skill (`run sprint planning`) anytime epics change to refresh tracking —
   advanced statuses are preserved, never downgraded.
