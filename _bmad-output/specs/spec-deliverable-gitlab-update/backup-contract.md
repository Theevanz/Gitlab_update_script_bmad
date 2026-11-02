# Backup Contract

Cross-deliverable contract between this upgrade runner (consumer, defines the contract) and the follow-on backup script (producer, fulfills it). The demo uses a hand-made backup satisfying this contract — stated, not hidden.

## Producer must deliver

- Docker volume snapshots under `$BACKUP_PATH/data/` plus secrets/config copies under `$BACKUP_PATH/secrets/`.
- A `BACKUP_CREATED_AT` file holding the artifact timestamp as epoch seconds.
- The demo uses a hand-made backup satisfying this layout — stated, not hidden.

## Consumer verifies (~15 lines, verification only)

1. Artifact check: `data/`, `secrets/`, and `BACKUP_CREATED_AT` exist under `$BACKUP_PATH`.
2. Freshness check: `RUN_START - BACKUP_CREATED_AT <= 86400` (24 hours), with `RUN_START` captured as the script's first statement. Halt if older.
3. Halt naming the missing or stale item if either check fails; the Phase 1 recon step never proceeds without a valid backup (unless `--nobackup` is passed for pre-producer testing, in which case the skip is logged loudly).

Backup implementation itself is explicitly out of this deliverable.
