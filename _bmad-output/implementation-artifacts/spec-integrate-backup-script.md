---
title: 'Integrate backup producer into upgrade pre-gate (auto-run when missing or stale)'
type: 'feature'
created: '2026-11-10'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context: []
baseline_commit: '0eeca377973233c55c7d6b913eac3d8f15348ee4'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The upgrade runner halts when the backup is missing or stale, while the producer (`gitlab-backup/backup/gitlab-backup.sh`) exists but is never invoked — every stale backup blocks the upgrade by hand.

**Approach:** Build one integrated verification gate: it checks for a fresh backup first, runs the producer once when the backup is missing or stale, then re-checks before any pause or container change; a fresh backup proceeds with zero side effects.

## Boundaries & Constraints

**Always:** Check before producing (fresh backup never triggers a run); the produce-once step lives inside the gate on live runs in the first pre-gate wave before pause, never in `--plan` (read-only rehearsal reports would-run) and never under `--nobackup` (loud skip stands); producer invoked zero-arg with its 13-var registry from env or `backup.env`; after a run the gate re-checks presence and freshness and halts naming missing or stale on failure; preserve `die()` GATE vocabulary, log format, and fail-before-CI-touched ordering.

**Never:** No changes to pause, drain, mutate, monitor, proceed, or failure-bundle logic beyond the backup gate; no retry of a failed backup inside one run; no mid-run produce after pause (later waves check-only); no silent fallback to `--nobackup`; no Python or new runtimes; no NAS provisioning; the runner adds no retention logic of its own (the producer's own ship and prune steps are the producer's behavior, not runner scope).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh backup present | Live run, newest set ≤24h, both members present | Gate passes, no producer run, log fresh age | N/A |
| Missing or stale | Live run, first pre-gate wave, no set or age >24h | Gate runs producer once, re-check passes, continue to pause | Producer fail or re-check fail halts GATE=pre naming cause |
| Plan rehearsal | `--plan` with missing or stale backup | No producer run, halt names backup cause with would-run action | Same halt: take fresh backup and re-run |
| Skip flag | `--nobackup` any state | Loud skip, no check, no run | N/A |
| Late staleness | Post-pause waves see stale set | Check-only halt, no produce | Halt with closeout or pre GATE per caller |

## Decisions

- Single integrated gate: check, produce-once when missing or stale, re-check — no separate versions to support.
- Check is presence-only: newest set is the lexicographic-max `<ts>` dirname matching `^[0-9]{8}-[0-9]{6}$` with both members present; anything else counts as missing. No live re-hash — the producer hash-verified the set at creation.
- Fresh means `0 ≤ CHECK_TIME − <ts> ≤ 86400` with `CHECK_TIME` captured when the gate runs; within 24h passes, future timestamps fail. (Renegotiated: a `RUN_START` basis can never pass the re-check, since the producer necessarily runs after script start.)
- Local only: the gate never checks the NAS; the producer's exit code gates the produce step, and no producer changes are needed.
- Producer: new optional env `BACKUP_SCRIPT` plus `BACKUP_ENV_FILE` with runner-relative defaults.
- Path: `BACKUP_PATH` is the sets root holding `<ts>/` dirs.

</frozen-after-approval>

## Code Map

- `runner/upgrade-gitlab.sh:1017-1033 verify_backup()` — current probe, return 1 never die; extend into the integrated check-produce-recheck gate.
- `runner/upgrade-gitlab.sh:1140-1158 pregate_checks()` plus callers `1196,1267,1728,1860` — produce step only at first caller, rest check-only.
- `runner/upgrade-gitlab.sh:1096-1138 plan_mode()` — read-only, must report would-run never execute.
- `runner/upgrade-gitlab.sh:618-693 phase_validate()` — `BACKUP_PATH` required and dir-checked unless skip; add producer path checks.
- `gitlab-backup/backup/gitlab-backup.sh:1-100,598-620` — zero-arg, 13-var registry, stdout START/DONE only, FAIL to stderr exit 1.
- `_bmad-output/specs/spec-deliverable-gitlab-update/backup-contract.md` — contract doc stating the integrated check the gate enforces.
- `gitlab-backup/_bmad-output/specs/spec-gitlab-backup/SPEC.md` — producer rule: presence first, then hash re-check, age at most 24h.

## Tasks & Acceptance

**Execution:**
- [x] `_bmad-output/specs/spec-deliverable-gitlab-update/backup-contract.md` -- state the integrated check the gate enforces: newest set present with both members, age at most 24h, local only -- contract source of truth
- [x] `runner/upgrade-gitlab.sh` -- extend `verify_backup` into the integrated check-produce-recheck gate with producer path validation honoring plan and nobackup -- core gate change
- [x] `test-gitlab-server/README.md` -- record the new env exports and gate behavior -- operator can run it

**Acceptance Criteria:**
- Given a live run with a fresh set, when the pre-gate runs, then it passes without invoking the producer.
- Given a live run with a missing or stale set, when the first pre-gate wave runs, then the producer runs once and the gate passes only if the re-check is green.
- Given `--plan` with a missing or stale set, when rehearsal runs, then no producer runs and the halt names the backup cause.
- Given `--nobackup`, when any gate runs, then backup is skipped loudly with no check and no run.

## Implementation Notes

- Coordinator fix during step-03 diff review: removed "v2" versioning language from backup-contract.md per the user's no-back-version decision (contract now states the pipeline set outright).
- Review patch (blind/B11 + verifgap/V1-V3): committed the passing /tmp harnesses as runner/check-backup-gate.sh (53 cases, green) since the implementation agent had finished; no producer or gate logic changed.

## Spec Change Log

## Review Triage Log

- blind/B1 empty-BACKUP_PATH glob → false: unreachable; phase_validate dies on non-dir unless SKIP_BACKUP, which returns before any glob; no other caller reaches newest_backup_set.
- blind/B2 no fallback to older set → false: newest-only semantics are frozen in the spec; anomalous newest fails closed on check-only waves and self-heals via produce-once on the live wave.
- blind/B3 -f-only member check → low: zero-byte/unreadable members pass only via post-creation damage already accepted as residual risk under the frozen presence-only decision; rejected (unlikely met; fix adds guards).
- blind/B4 no atomic publish protocol → false: producer stages in dot-dirs invisible to the `*/` glob and publishes by atomic rename after asserting both members plus self-hash; the gate can only observe complete sets.
- blind/B5 buffered producer output → low: output is grammar-bounded (KBs) so memory is a non-issue; blocking is announced by the "running once" line and interruptible via the INT trap; rejected (harmful parts unmet; proper fix adds streaming/timeout complexity).
- blind/B6 GNU-date-only → false: Linux-only target documented in code and architecture scope; BSD/macOS unsupported; degrades loudly to a missing cause, never silent.
- blind/B7 no early 13-var validation → false: runner deliberately avoids duplicating producer CONFIG validation (single owner, no drift); missing vars surface as loud FAIL:CONFIG only when produce runs; missing env file falls back per producer design and the runner logs it.
- blind/B8 inconsistent cause surfacing → false: phase_pregate's generic die is the untouched pre-existing aggregate pattern (per-check evidence in log); BACKUP_FAIL_CAUSE's sole consumer is plan's die and plan never produces, so no overwrite is observable; live-wave first cause stays in the log.
- blind/B9 <ts> start-vs-publish undefined → false: producer assigns TS once before pipeline stages (capture instant, the right age basis); arrival-age matters only for >24h pipelines, which don't occur; outcome would be a loud halt, never silent pass.
- blind/B10 no secret redaction → false: producer prints only grammar lines plus a BACKUP_DIR path; secrets are paths-only by convention and runner tokens aren't in the producer registry.
- blind/B11 no accompanying tests → medium: true of the repo (behavior verified only by throwaway /tmp harnesses); grouped with verifgap/V1-V3 → patch (commit the harness).
- edge/E1 broken-symlink env file → false: runner logs the fallback and producer documents missing-file fallback (load_env_file); nothing silent, fallback is the sane behavior for a nonexistent file.
- edge/E2 BSD date → false: same evidence as blind/B6.
- edge/E3 empty-output blank line → low: producer grammar guarantees output; one blank log line on bizarre failure is cosmetic; rejected (rarely met; fix adds a branch).
- edge/E4 large-output memory → low: same root and evidence as blind/B5; rejected with it.
- edge/E5 setup.sh legacy seed plus stale echo → medium: real contradiction (setup.sh seeds legacy layout, prints backups/latest) vs new README; pre-existing and gate self-heals via produce; grouped with verifgap/V0 → defer.
- verifgap/V1 fresh/stale check untested → medium (pre-verified): green today via /tmp harness, risk is future regression; grouped → patch (same harness).
- verifgap/V2 produce-once routing unverified → medium (pre-verified): same basis; grouped → patch.
- verifgap/V3 invocation env and validate untested → medium (pre-verified): same basis; grouped → patch.
- verifgap/V0 setup.sh contradiction → medium: same defect as edge/E5; grouped → defer.

## Design Notes

Freshness comes from the set dirname `<ts>` (`YYYYMMDD-HHMMSS` UTC) parsed against the check-time clock. The check is presence-only: the producer hash-verified each set at HASH and SHIP time, so the gate trusts presence plus freshness and the runner needs no `sha256sum` dependency. Later waves stay check-only so a multi-day monitor wait cannot mutate mid-run.

## Verification

**Commands:**
- `bash -n runner/upgrade-gitlab.sh` -- expected: clean parse
- `bash runner/upgrade-gitlab.sh --help` -- expected: usage lists backup auto-run behavior
- `bash runner/check-backup-gate.sh` -- expected: all gate and validate cases pass (53 passed, 0 failed)
