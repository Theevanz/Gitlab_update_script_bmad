# Backup Contract

Cross-deliverable contract between this upgrade runner (consumer, defines the contract) and the backup producer (fulfills it). The backup is a timestamped pipeline set; the hand-made demo layout (`data/` + `secrets/` + `BACKUP_CREATED_AT`) is not recognized and counts as missing.

## Producer must deliver

- Timestamped set dirs under `$BACKUP_PATH/`: `<YYYYMMDD-HHMMSS>/` (UTC) holding exactly `set.tar.age` + `SHA256SUMS` as one unit; both members ship and prune together, never piecemeal.
- Each set hash-verified at creation (HASH) and after ship (SHIP); the gate trusts presence plus freshness and never re-hashes.
- No partial sets: any failure leaves no published set behind.

## Consumer verifies (integrated gate, local only)

1. Newest set: the lexicographic-max `<ts>` dirname under `$BACKUP_PATH` matching `^[0-9]{8}-[0-9]{6}$` with both members present. Anything else (legacy epoch dirs, stray files, incomplete sets) counts as missing.
2. Freshness: `0 <= CHECK_TIME - <ts> <= 86400` (24 hours), with `CHECK_TIME` captured when the gate runs; future timestamps fail. (Check time, not `RUN_START`: a set this run just produced is definitionally fresh, while a `RUN_START`-pinned age would mark it future-dated and the re-check could never pass.)
3. Produce-once: on a live run, the first pre-gate wave (before pause) runs the producer once, zero-arg, when the set is missing or stale, then re-checks; the gate passes only if the re-check is green. No retry inside one run.
4. `--plan` never runs the producer: rehearsal reports the live run would run it, then halts naming the backup cause. `--nobackup` skips backup loudly with no check and no run. Later waves (post-pause) are check-only and never produce.
5. Local only: the gate never checks the NAS; the producer's exit code gates the produce step.

`$BACKUP_PATH` is the sets root holding `<ts>/` dirs. Producer paths are optional `BACKUP_SCRIPT` and `BACKUP_ENV_FILE` (runner-relative defaults); the runner pins `BACKUP_DIR` to `$BACKUP_PATH` for the produce run so the new set lands where the gate checks.
