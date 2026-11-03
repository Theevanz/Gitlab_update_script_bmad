# Story 4.4 evidence summary — live demo 16.11 → 17.5

Live runs Nov 2–3 2026 on the seeded `test-gitlab-server/` instance (single-node Docker
Compose, zero runners). Runner: original parser for hop 1; fixed parser (finalized
verdict, see bug note) for hops 2–3. All token values redacted in evidence.

## AC1 — 2–3 real stops, one per run, DONE-per-stop

| Hop | From → To | Note/ACK | Heartbeats (telemetry) | Proceed 6/6 | Smoke | Close-out | Log |
|-----|-----------|----------|------------------------|-------------|-------|-----------|-----|
| 1 (injected attempt) | 16.11.10 → 17.1.8 | note shown, `ACK 17.1.8` | 58→59/61, health OK | — (halted, see AC2) | — | halt, no mutations after gate | `run-stop1-injected.log` |
| 2 | 17.1.8 → 17.3.7 | none, no prompt | 109→111→113→114/114 | 6/6 | pass | exit 0 + `run complete` | `run-stop2-17.3.log` |
| 3 | 17.3.7 → 17.5.5 | note shown, `ACK 17.5.5` | 170→172→173/173 | 6/6 | pass | exit 0 + `run complete` | `run-stop3-17.5.log` |

DONE-per-stop elements observed on hops 2–3: 10 s-sleep heartbeats with full
telemetry (cpu/mem/bio/net + rake counts + deltas), version match, migrations
complete, `/health_check` success, readiness all-green (16/16 services), passing
main clone-and-push, re-check + close-out re-verification.

Hop 1 shows mutation + hang verdict instead of proceed: the injected postgres stop
halted the run at the monitor gate by design, and re-runs continue forward with no
resume (retry/resume is out of scope), so that hop yields halt evidence while hops
2–3 yield proceed evidence. The 17.1.8 mutation itself is proven (compose pin,
image pull, recreate, 171 s boot, heartbeats on the new version).

## AC2 — injected failure halts within 5 minutes with actionable logs

Postgres stopped mid-wait on hop 1 → next affected beat halted at once with
`GATE='monitor'` (`migration table unreadable`, cause `PG::ConnectionBad` on the
missing socket in the log line above). Fast halt, not the 30-flat-beat idle path.
Bundle: preferred gitlabsos report (764K) + recorded health
(`failure-bundle-17.1.8-1793615310/`). Full 4-line rollback story (backup source,
image-revert sed to 16.11.10, restart command, unpause as HUMAN-ACTION). Runners
`none`, container `Running`. Log: `run-stop1-injected.log`.

## Bug found live — `finalized` verdict false-positive (fixed)

Hop 2 pre-gate halted 3× (attempts 2–4) on `59 of 61 finished, 2 unfinished` over
~15 h on a healthy instance. Diagnosis: the 2 rows read `finalized` — GitLab's
terminal complete state, not stuck work. The parser counted only `finished`.
Fix (`spec-4-4-rake-finalized-verdict.md`): count finalized as done in the shared
parser, honest `complete` verdict wording, entry guard + `runner/check-rake-verdict.sh`
(green 11/11), AD-10 sentence amended. Live proof: hop 2 then read
`61 of 61 complete (finished or finalized)` and ran to `run complete`.
False-positive halts: `run-stop2-17.3-attempt{2,3,4}-prehalt.log` + bundles;
diagnostic table: `rake-status-17.1-leftovers.log`.

## Expected and degraded paths (all by design)

- Zero runners: pause/unpause no-op; close-out ends `run complete` with
  `no runners, flow check skipped` instead of jobs-flowing confirmation.
- Heartbeat cadence is ~34 s effective (10 s sleep + ~24 s rake probe), full
  telemetry every beat; `flat_streak` on the observed-only sub-check line is
  the live rake-delta hang counter (30 flat beats halts the wait).
- Backup is hand-made per the backup contract; stayed ≤24 h through hop 3
  (17.5 h at close). Compose drifted 16.11 → 17.5.5 with 3 kept `.bak-*` files
  (never auto-restored) — expected mutation evidence, uncommitted.
- `setup.sh` mints a fresh smoke token whenever its probe fails, so shell exports
  must be re-derived from `.env` after any setup run (observed 3 values).
- The demo-runbook line claiming no prompts for stops 2–3 is stale for stop 3:
  the 17.5 stop carries a note and the run required `ACK 17.5.5` (proven live).
- Instance left at 17.5.5 in its proven state. Reset to a fresh 16.11 seed is
  documented, not executed: `git checkout -- test-gitlab-server/docker-compose.yml`,
  wipe `volumes/` + `backups/`, re-run `setup.sh`.

## Files

- `run-stop1-injected.log` — full first-terminal session (validate halts, green
  `--plan`, live ACK/mutate/heartbeats, injected halt + rollback)
- `session-early-halts-and-plan.log` — corroborating session copy
- `run-stop2-17.3-attempt1-noexports.log` — export-less re-run, validate halt
- `run-stop2-17.3-attempt{2,3,4}-prehalt.log` — finalized false-positive halts
- `run-stop2-17.3.log` — hop 2 clean run to `run complete: 17.1.8 -> 17.3.7`
- `run-stop3-17.5.log` — hop 3 clean run to `run complete: 17.3.7 -> 17.5.5`
- `rake-status-17.1-leftovers.log` — live 59+2 table (59 finished, 2 finalized)
- `failure-bundle-17.1.8-1793615310/` — injection halt bundle (gitlabsos)
- `failure-bundle-17.3.7-1793615909/`, `-1793670174/`, `-1793670728/` — pre-halt bundles
