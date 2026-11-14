---
title: "Product Brief: gitlab-backup"
status: final
created: 2026-11-03
updated: 2026-11-03
---

# Product Brief: gitlab-backup

## Executive Summary

`gitlab-backup` is a small, scheduler-agnostic backup script for a Docker-hosted, on-prem GitLab instance. Each run produces one timestamped backup set — the native tarball (frozen via `STRATEGY=copy`), the whole config volume, the compose file, and `.env` bundled into one archive, encrypted once with `age`, plus one SHA-256 hash over the sealed blob — keeps the latest 2 sets locally, and ships blob + hash to an on-prem backup server (NAS VM) over rsync. Its first job is to be the rollback path for the stepwise GitLab upgrade runner: no migration step proceeds without a fresh backup. Scheduling, retention horizons, and off-site copies are policy around the script, not logic in it.

## The Problem

The upgrade runner (`runner/upgrade-gitlab.sh` in the parent deliverable) refuses to migrate without a valid backup — today that backup is hand-made for the demo, and the `--nobackup` escape hatch means "no rollback path." There is no producer: nothing that reliably captures the database, repositories, uploads, CI data, and the config/secrets a restore actually needs, verifies the set survived the trip to backup storage, and keeps enough history that a late-noticed mistake (a project deleted last week) is still recoverable. A bare tarball alone cannot restore a GitLab instance — the native tool deliberately excludes `gitlab.rb` and `gitlab-secrets.json` — so any check that passes on "a tarball exists" can bless an unrestorable backup.

## The Solution

One script, one run, one backup set. When invoked (by hand pre-migration, or by an external task scheduler), it:

1. Runs GitLab's native backup with `STRATEGY=copy`, so live data is duplicated aside and the archived set is frozen; copies the whole config volume (the `/etc/gitlab` bind: `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys) and the compose file + `.env` (the pinned-version recipe).
2. Tars all three into one set archive and encrypts it once with `age` to the backup server's public key (key supplied out-of-band before first run); wipes the plaintexts.
3. Hashes the sealed blob (one SHA-256) and ships blob + hash to the NAS via rsync as one timestamped unit; retention and deletion delete the unit whole. Logs are skipped; no inner hashes — the blob hash covers the contents.

## Who This Serves

- **The upgrade runner (primary consumer):** needs a fresh, complete, verifiable backup at `$BACKUP_PATH` before every migration stop.
- **The operator (you):** needs a single command that either produces a trustworthy set or fails loudly, with no scheduler or NAS-side logic inside the script.
- **The mentor (grader):** needs the script to read as audit-grade bash — every step explainable, consistent with the parent deliverable's standards.

## Success Criteria

- A run either yields a complete set (one encrypted blob + one matching hash, locally and on the NAS) or exits non-zero naming what failed.
- The runner's pre-migration check passes against a fresh set and fails against a missing, stale (>24h), or incomplete set; the hash is re-verified, not just checked for presence.
- A restore from a produced set is demonstrated at least once against the test instance (even though restore itself stays manual).
- The script contains no scheduling logic and runs identically by hand or under a task scheduler.

## Scope

**In (v1):** native-tarball capture with `STRATEGY=copy`; config-volume + compose + env assembly; bundle-then-encrypt (one `age` invocation); single SHA-256 over the blob; rsync shipment of blob + hash to NAS; local retention of the latest 2 sets; set-as-unit semantics; loud failure with no partial sets left behind.

**Out (v1):** scheduling (external scheduler owns it); automated restore (restore stays manual/documented); retention-horizon enforcement and off-site copies — policy is declared in the addendum, enforcement is explicitly out of scope; log backup (skipped by design); live data-volume copies and inner hashes (both rejected by design).

**Requires:** the backup server's `age` public key, provided out-of-band before the first run.

## Contract Dependency

This brief amends the parent backup contract (v1: `data/` + `secrets/` + `BACKUP_CREATED_AT` layout) to v2: a timestamped set directory (one encrypted blob + one hash file) the runner checks for existence, freshness (≤24h), and completeness (both files present, hash matching). Updating `backup-contract.md` and the runner's verification step is a **parent-deliverable change** and a dependency of this script's acceptance — not work inside this brief.

## Open Questions

None remaining. NAS VM provisioning is out of script scope but required before acceptance.
