# Epic 4 Context: Proof of Done and Close-Out

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

The runner proves the stop is complete through the ordered proceed gate, resumes CI only on success, and closes every run out with re-verified health or a diagnostics bundle plus rollback story. This is the evidentiary end of the run: nothing chains into the next stop on assertion, jobs never resume onto a broken instance, and every failure parks the instance safe with material a human can act on.

## Stories

- Story 4.1: Ordered proceed gate (proof of done)
- Story 4.2: Recheck, unpause, and success close-out
- Story 4.3: Failure bundle and rollback story
- Story 4.4: Demonstrated proof on the seeded instance

## Requirements & Constraints

- The proceed gate runs six checks in fixed order and halts on the first failure: version match with edition re-check, migration table all finished, comprehensive health check success, readiness green with per-service statuses recorded to the log, a clone-and-push smoke test against the seeded project's main branch, then a full health re-check followed by unpause-all.
- Unpause-all happens only on the success path after the step-6 re-check passes; on any failure runners stay paused and nothing resumes them.
- Success close-out re-runs the full pre-upgrade health set (backup freshness check included unless the run passed the no-backup testing flag), confirms runners unpaused with jobs flowing, and does not re-run the smoke test — the push path was proven once.
- Failure close-out always leaves a diagnostics bundle plus a four-line rollback story (backup path, image-revert edit, container up command, unpause explicitly marked as a human action). It never retries, never remediates, and never unpauses.
- The diagnostics bundle prefers the pinned standalone sos collector fetched at failure time, copied into the container, and run with the embedded runtime into a timestamped failure directory; if fetch or run fails it degrades to a native manifest (log tail, container inspect, replayed readiness/health lines, best-effort migration status) with the degradation logged. Either path includes recorded readiness statuses and health-check failure messages.
- Detect-and-halt everywhere: every issue is written to the log for a human to fix; the script never upgrades a sick instance and never auto-remediates.
- Log lines carry UTC timestamps with phase and message; halt lines add gate, expected, observed, action, live runner state, and live container state with single-quoted values.
- No unit harness: verification is runs against the seeded instance plus one injected-failure halt; the demo advances 2–3 real required stops one per run and proves hang detection fires on an injected stall, with every line defensible to review without notes.

## Technical Decisions

- Current version is read from the live instance API and normalized on both sides before exact-equality comparison; the expected edition derives from the image repository basename and is re-asserted at proceed step 1.
- The rake background-migration status table is the single migration signal at all sites; parse requires at least one database banner with every other non-blank line shaped as status-pipe-detail, else halt; verdict is every status finished, zero rows means clear.
- Endpoint roles follow official semantics: the comprehensive health check is for monitoring verdicts, readiness decides traffic-worthiness, liveness detects deadlocks.
- Container state is checked before trusting HTTP: scripted exec calls pass the no-TTY flag, every HTTP probe carries a timeout, and Layer-0 state is logged alongside probe results.
- All halts flow through one halt routine with the fixed gate vocabulary (proceed, unpause, and close-out gates live here); signal traps route into it with the current-phase gate; the routine writes only log and bundle output after detection.
- The runner stays one self-contained Bash file plus the vendored stop list, readable top-to-bottom in execution order, using only Bash plus curl, git, and docker/compose CLIs with an optional JSON parser and a byte-identical grep fallback detected once at startup; every phase re-derives state from the live instance with no state file.
- CI quiet uses the Runners API: enumerate all runners following pagination, assert drained means zero running jobs across all runners, log the pause count plus IDs. The success-path log notes that pre-existing paused runners also resume.
- Backup freshness means run-start minus the artifact timestamp is within 24 hours, with run-start captured as the script's first statement.

## Cross-Story Dependencies

- Story 4.2 requires 4.1 steps 1–5 green before its step-6 re-check and unpause; step 4's recorded readiness statuses feed 4.3's bundle on later failure.
- The proceed gate is entered only from the Epic 3 monitor exit; the close-out re-check reuses the Epic 2 pre-upgrade health and backup checks; unpause reverses the Epic 2 pause.
- All stories build on the Epic 1 substrate (halt routine, log format, probe library, strict startup config) and follow its source layout and parsing contracts.
- Story 4.4 is the end-to-end demonstration depending on all epics plus the seeded instance at 16.11 and the injected failure.
