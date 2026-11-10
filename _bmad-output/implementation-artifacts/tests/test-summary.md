# Test Automation Summary

Feature: integrated backup gate (`runner/upgrade-gitlab.sh` — check, produce-once, re-check).
Date: 2026-11-10. Framework: project's existing bash regression harness (no API or UI in this repo, so no REST/API or browser tests apply; BATS covers the producer in `gitlab-backup/tests/` and was left untouched).

## Generated Tests

Extended `runner/check-backup-gate.sh` from 53 to 88 assertions (+35), following the file's existing fixture/stub patterns. No production code changed.

### CLI contract tests (sourced runner, fixture `BACKUP_PATH` dirs)

- [x] Cases 14–16 — newest-only shadowing (future shadows older fresh, no fallback) and live check-only late-wave routing (stale/missing fail without producing)
- [x] Cases 17–18 — fail-closed paths: future-dated newest still fails after produce; exit-0-but-empty producer fails the re-check, exactly one attempt each
- [x] Case 19 — strict invocation contract: producer runs zero-arg with `BACKUP_DIR`/`ENV_FILE` pinned to `BACKUP_PATH`/`BACKUP_ENV_FILE`
- [x] Cases 20–21 — exact freshness bounds under a frozen clock: 86400s old passes, 86401s old fails as stale
- [x] Cases V6–V8 — validate deaths: missing `BACKUP_PATH`, file-as-`BACKUP_PATH`, non-executable `BACKUP_SCRIPT`

### E2E tests (stubbed `--plan` subprocess runs, no Docker)

- [x] Case P3 — `--plan` with a stale set halts at the plan gate naming the stale cause plus the would-run action; producer never runs
- [x] Case P4 — `--plan --nobackup` with empty backups passes end-to-end with the check skipped; producer never runs

## Coverage

- Gate check (`check_backup_set` / `newest_backup_set`): fresh, missing, stale, future, unparsable, incomplete, legacy-only, exact 24h bounds, anomalous-newest shadowing — covered
- Gate routing (`verify_backup`): produce, live check-only, plan double-guard, nobackup skip, produce-failure, empty-produce re-check failure — covered
- Producer invocation (`run_backup_producer`): zero-arg, `BACKUP_DIR`/`ENV_FILE` pinning, single attempt, output capture — covered
- Validate (producer paths): defaults, missing/file `BACKUP_PATH`, bogus/non-executable `BACKUP_SCRIPT`, missing/directory `BACKUP_ENV_FILE`, nobackup skip — covered
- Plan E2E: missing halt, stale halt, fresh pass, nobackup skip pass — covered

## Verification

- `bash -n runner/check-backup-gate.sh` — clean
- `bash runner/check-backup-gate.sh` — **88 passed, 0 failed** (exit 0)
- `bats gitlab-backup/tests/` (Bats 1.13.0, local npm install in /tmp) — **69 passed, 0 failed, 1 skipped** (skip: live-SSH endpoint test needs a `TEST_SSH_ENDPOINT` fixture; includes 2 new CONFIG fail-fast tests for the backups-dir check)

## Next Steps

- Run both suites in CI (`bash runner/check-backup-gate.sh` + `bats gitlab-backup/tests/`)
- Optionally provide a `TEST_SSH_ENDPOINT` fixture to cover the one skipped live-endpoint test
