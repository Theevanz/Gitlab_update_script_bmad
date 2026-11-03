---
title: 'Run the live demo hops with hang injection and capture Story 4.4 evidence (phase 2)'
type: 'chore'
created: '2026-11-02'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context: []
baseline_commit: 'c5bea08ba34fe02aa2f4160c8b5c05e0826b0518'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 4.4's code, runbook, and 16.11 seed are live, but the deferred proof (real upgrade hops plus an injected hang plus captured evidence) has never run — 4.4 sits in review with no demonstrated DONE-per-stop.

**Approach:** The user executes the demo-runbook flow on the host (backup refresh, read-only rehearsal, three hops with a postgres-stop injection on stop 1, re-run to continue) while the agent captures per-run logs, the monitor-gate failure bundle, and a 4.4 evidence summary, then clears the deferred entry and moves 4.4 to done.

## Boundaries & Constraints

**Always:** Export all 7 settings per shell before any run; run `--plan` rehearsal before going live; ACK every prompted note exactly as printed — expect prompts on stops 1 AND 3 (17.5 carries a note, so the runbook's "no prompts" line for stop 3 is stale); inject exactly once, on stop 1's first attempt, by stopping postgres during heartbeat lines, then restart postgres and re-run to continue; keep runners paused until a success path unpauses them; hold a backup no older than 24 h at demo time (re-run `setup.sh` first — it is idempotent); capture every run's full log plus the failure bundle plus an evidence summary under `demo-evidence-4-4/`; the user runs all docker/compose/script commands on the host and the agent verifies from logs and files (the agent sandbox has no Docker socket).

**Never:** No edits to `runner/`, `upgrade_path.yml`, the frozen specs, or the runbook flow — zero code changes; no second injection and no full 5-minute idle-hang wait (the postgres-stop fast path proves the same gate); no `--nobackup` evidence runs; no Runner installation (the zero-runner loud-warning close-out stands); no secrets rotation or history rewrite here (that deferred entry stays); never commit `.env`, tokens, or the drifted compose pin; never wipe volumes or backups before evidence is captured and reviewed; never "fix" the compose-file image drift mid-demo (16.11 → 17.5 drift is expected mutation evidence).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Backup refresh | Seed idle at 16.11, backup possibly stale | `setup.sh` re-run green, backup fresh (≤24 h), `healthcheck.sh` 6/6 | Setup halt → fix per its halt line; no demo until green |
| Rehearsal | Fresh exports | `--plan` exit 0, read-only, prints 16.11.x → 17.1.z plus the stop note | Non-zero → halt and diagnose; never go live |
| Stop 1, injected attempt | Plan green | ACK `17.1.z` → mutate → heartbeats → postgres stop → `GATE='monitor'` halt naming the postgres backend within 5 min, plus failure bundle and 4-line rollback story, runners paused | A different gate → keep the bundle and investigate before continuing |
| Restart + re-run | Halt bundle captured | Postgres restarted; re-run re-derives state from the live instance (no resume — retry/resume is out of scope) and plans a fresh 17.1 → 17.3 hop with no prompt | Pre-gate halt on unfinished 17.1 migrations → wait, re-run until green; other halts → bundle and diagnose |
| Stops 2–3 clean | Re-run green | Exactly one stop per run, 10 s heartbeats with telemetry, 6-step proceed gate, unpause, close-out exit 0 + `run complete`; stop 3 prompts ACK for the 17.5 note | Any halt → bundle + rollback story, runners stay paused, diagnose before retry |
| Evidence capture | All runs complete | `demo-evidence-4-4/` holds every run log, the monitor-gate bundle, and a summary mapping runs to AC1/AC2 with the loud-warning close-out recorded as expected | Any item missing → re-collect before clearing the deferred entry |

</frozen-after-approval>

## Code Map

- `runner/upgrade-gitlab.sh` — read-only: env header :12, strict validation :633/:684, stop extraction :722, next-stop lookup :814, plan + note ACK :1059–:1080, backup verify :1012, failure bundle + rollback story :1778; never edit
- `runner/upgrade_path.yml` — stop list: 16.11 (:82) → 17.1 (:85, note → ACK) → 17.3 (:89, no note) → 17.5 (:92, note → ACK); never edit
- `_bmad-output/implementation-artifacts/demo-runbook.md` — operator flow (Settings, stops, postgres-stop injection, halt handling); follow it, do not edit
- `test-gitlab-server/` — live seed: `README.md` (7 exports), `setup.sh` (idempotent refresh), `healthcheck.sh` (6/6), `.env` (gitignored), `docker-compose.yml` (will drift to 17.5 — expected, never commit)
- `_bmad-output/implementation-artifacts/spec-4-4-demo-runbook.md` — phase-1 decisions (user-runs/agent-verifies, zero-runner path, seed layout); frozen
- `_bmad-output/planning-artifacts/epics.md` Story 4.4 (:520) — AC1 (2–3 stops, DONE-per-stop) / AC2 (injected halt within 5 min) / AC3 (explainable, assessed in demo)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — key `4-4-demonstrated-proof-on-the-seeded-instance`: `review` → `done` when evidence lands
- `_bmad-output/implementation-artifacts/deferred-work.md` — clear the live-demo entry on completion; the secrets-rotation entry stays
- `_bmad-output/implementation-artifacts/demo-evidence-4-4/` (new) — per-run logs, failure-bundle copy, evidence summary

## Tasks & Acceptance

**Execution:**
- [x] `test-gitlab-server/setup.sh` — user re-runs on the host — refreshes the backup to ≤24 h and confirms a healthy 16.11 start before any evidence run
- [x] `runner/upgrade-gitlab.sh --plan` — user runs, agent reviews the pasted output — read-only rehearsal proving the settings with zero mutations
- [x] `runner/upgrade-gitlab.sh` (stop 1, injected) — user runs live, stops postgres during heartbeats — produces the `GATE='monitor'` halt, failure bundle, and rollback story for AC2
- [x] `runner/upgrade-gitlab.sh` (re-run through stop 3) — user restarts postgres and runs to 17.5 — continues 17.1 → 17.3 → 17.5 with DONE per run for AC1
- [x] `_bmad-output/implementation-artifacts/demo-evidence-4-4/` — agent writes run logs, bundle copy, and summary — durable 4.4 proof mapping each run to AC1/AC2
- [x] `_bmad-output/implementation-artifacts/deferred-work.md` + `sprint-status.yaml` — agent edits — removes the live-demo entry and moves the 4-4 key `review` → `done`

**Acceptance Criteria:**
- Given the seed at 16.11 with a fresh backup, when the user runs the flow, then three hops advance one per successful run to 17.5 with 10 s heartbeats and telemetry on every migration wait.
- Given the stop-1 injection, when postgres stops mid-wait, then the run halts at `GATE='monitor'` naming the postgres backend within 5 minutes, leaving a bundle and rollback story with runners paused.
- Given all runs complete, when evidence is inspected, then every run log, the monitor-gate bundle, and a summary mapping each run to AC1/AC2 exist under `demo-evidence-4-4/`.
- Given close-out on the zero-runner seed, when runs succeed, then they end exit 0 + `run complete` with the documented loud warning instead of jobs-flowing confirmation, recorded in the summary as expected.
- Given evidence complete, when tracking is checked, then the live-demo deferred entry is gone, the secrets-rotation entry remains, and the 4-4 key reads `done`.

## Implementation Notes

- Implementing directly (no subagent dispatch): spec tasks 1–4 are user-run-on-host with agent verification interleaved per run; a dispatched subagent could neither receive the user's multi-step outputs across turns nor touch Docker. Sprint sync skipped per rule (4-4 key already at `review`, later than `in-progress`).
- Stop 1 injected halt captured (GATE='monitor', gitlabsos bundle, 4-line rollback). Stop 2 blocked: 17.1 leftovers frozen at 59/61 for ~15.5h across 4 attempts (attempt1 no-exports validate halt, attempts 2–4 identical pre-halts) — declared stuck, not slow, then diagnosed as `finalized` false-positive (see blocker note below). Recovery: capture unfinished-rows diagnostic, `docker compose restart gitlab`, healthcheck to 6/6, re-check rake, re-export from .env, re-run. Backup still fresh (~16.6h at last check, ~7h margin); no setup.sh refresh needed yet.
- Attempt4 (Nov 3 01:51Z) is the 4th identical pre-halt (59/61), 7 min after attempt3 — restart still pending. Correction: root `upgrade-gitlab.log` is the script's own accumulative log (`LOG_FILE`, every line tee'd; bundles replay health lines from it) — copy from it for evidence, never move/delete.
- BLOCKER (live-demo finding): the 2 "unfinished" leftovers are status `finalized` (BackfillEpicBasicFieldsToWorkItemRecord, BackfillPartitionIdCiDailyBuildGroupReportResult) — a terminal complete state, not stuck work. The runner's shared rake parser counts only `finished` (upgrade-gitlab.sh:539-540; consumers: leftover :1002, monitor :1584, proceed :1695) and never mentions `finalized`: false-positive gate, confirmed by GitLab enum/docs (finalized == done). Restart done, instance 6/6 healthy, count unchanged as expected. Demo cannot pass hop 1 without a runner code change (frozen spec forbids; no bypass; tampering with migration rows forbidden) — awaiting human decision: bugfix spec vs scoped partial proof.
- RESOLVED via spec-4-4-rake-finalized-verdict (user chose bugfix-spec-then-resume): parser counts finalized as done + regression check green + live proof — hop 2 completed 17.1.8 → 17.3.7 with full DONE-per-stop (heartbeats+telemetry 109→114/114, version match, migrations complete, /health_check success, readiness all-green, smoke clone+push pass, exit 0 + `run complete`). Post-run: 3 transient 17.3 `active` rows appeared then finished within ~1 min (normal wave scheduling). Hop 3 DONE (see close-out note below).
- CLOSE-OUT (Nov 3 02:49Z): hop 3 completed 17.3.7 → 17.5.5 with full DONE-per-stop (ACK 17.5.5 for the 17.5 note — runbook "no prompts" proven stale; heartbeats 170→173/173; proceed 6/6; smoke pass; exit 0 + `run complete`; backup 17.5h fresh). Evidence summary written; live-demo deferred entry cleared (secrets entry stays); sprint 4-4 → done, epic-4 → done. Demo spec step-03 complete; step-04 reviews (bugfix + demo) next.

## Spec Change Log

## Review Triage Log

- [blind B1] plan leftover old wording — verdict: false — current code has no old-wording site (all emit sites print `complete`); cited log lines are pre-fix Nov 2 history.
- [blind B2] stale 4.4 comment beside done — verdict: low — line contradicts the done flip; cosmetic. Route: patch (delete line + remove satisfied deferred entry).
- [blind B3] no pending/unknown fixture — verdict: medium — groups with V1 (same defect); demonstrated undetected regression. Route: patch.
- [blind B4] no all-finalized/multi-banner fixture — verdict: low — same code path as covered mixed case; live multi-banner table already handled. Rejected (test-only gap, fix adds complexity).
- [blind B5] duplicate failure bundles root vs evidence — verdict: low — all 4 pairs byte-identical; clutter + no canonical note. Route: patch (delete root copies).
- [blind B6] sos redaction unverifiable from diff — verdict: false — checked directly: zero token strings in all 4 sos payloads; risk disproven.
- [blind B7] run-stop3 omitted from staged diff — verdict: false — file in tree and verified (6 hb, 6/6, ACK 17.5.5, run complete); omission only in staged copy.
- [blind B8] compose drift hunk unexplained — verdict: false — spec Never-clause + verification explicitly require it uncommitted; current state is the spec'd end state.
- [blind B9] gitlab-backup brief unrelated — verdict: false — untracked notes outside this spec; review-staging riders only, nothing staged for commit.
- [blind B10] 34s effective vs 10s AC cadence — verdict: low — wording ambiguity, disclosed in summary, DONE-per-stop demonstrated. Rejected (fix would edit this spec).
- [blind B11] flat beats vs flat_streak unreconciled — verdict: low — code has one counter (flat_streak=$flat); summary's `cosmetic` remark is inaccurate. Route: patch (correct summary bullet).
- [blind B12] sh-degradation unprobed — verdict: false — bash-only surface (shebang + sole bash sourcer); unreachable path untested is not a defect.
- [blind B13] triage search commands missing — verdict: false — substance re-verified by this review's verification-gap layer; working-notes paste absence is not a defect.
- [blind B14] absolute source_spec paths — verdict: false — established file convention and workflow-mandated defer format; no new defect.
- [vgap V1] pending/unknown unpinned (pre-verified) — verdict: medium — pending-as-done ships green, gates pass over running work. Route: patch (filed disposition).
- [vgap V2] verdict strings/heartbeat fields unpinned (pre-verified) — verdict: medium — misleading safety evidence + frozen-contract erosion; decisions unaffected. Route: patch (filed disposition).
- [vgap V3] compose ships repinned — verdict: false — nothing shipped; setup.sh consequence already tracked in deferred-work.
- [edge] no findings — clean pass after claims verification.

## Verification

**Commands:**
- `ls _bmad-output/implementation-artifacts/demo-evidence-4-4/` — expected: per-run logs, bundle dir, and summary all present
- `grep -l "GATE='monitor'" _bmad-output/implementation-artifacts/demo-evidence-4-4/*` — expected: the injected run's log matches
- `git status --porcelain=v1` — expected: `.env` untracked, drifted compose pin uncommitted, no secrets staged

**Manual checks (if no CLI):**
- User shares each run's console output; agent confirms ACK prompts on stops 1 and 3, heartbeat lines with telemetry, the monitor halt line, and `run complete` exits.
