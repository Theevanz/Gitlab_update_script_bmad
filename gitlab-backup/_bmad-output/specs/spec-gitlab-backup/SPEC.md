---
id: SPEC-gitlab-backup
companions:
  - backup-contents.md
  - capture-and-transport.md
  - retention-policy.md
sources:
  - ../../../brief-gitlab-backup-2026-11-03/brief.md
  - ../../../brief-gitlab-backup-2026-11-03/addendum.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# gitlab-backup — pre-migration backup producer

## Why

A pain to solve plus a mandate to meet. The stepwise GitLab upgrade runner refuses to migrate without a fresh, valid backup, but no producer exists: today's backup is hand-made for the demo, and the `--nobackup` escape hatch means "no rollback path." Worse, a bare tarball alone cannot restore a GitLab instance — the native tool deliberately excludes `gitlab.rb` and `gitlab-secrets.json` — so any check that passes on "a tarball exists" can bless an unrestorable backup. This work makes the rollback path real: one command that either yields a complete, verifiable set or fails loudly, so no migration step ever proceeds without a restore-capable backup behind it.

## Capabilities

- **CAP-1**
  - **intent:** Operator captures live GitLab data (database, repositories, uploads, CI data) into a frozen, timestamped backup set with a single invocation.
  - **success:** Each run captures live data into a native tarball taken from a frozen copy of the live data, ready for sealing into the set.
- **CAP-2**
  - **intent:** Operator copies the whole config volume (host-side bind path: configuration, secrets, certificates, host keys) plus the compose recipe into the set for sealing.
  - **success:** The sealed set holds the full config volume and compose recipe, recoverable by decrypting with the backup server's private key; plaintext secrets never leave the GitLab host unencrypted.
- **CAP-3**
  - **intent:** Operator preserves the pinned-version compose recipe inside the set so the matching GitLab version is restorable.
  - **success:** The compose file and `.env` recovered from a sealed set are byte-identical to the source files.
- **CAP-4**
  - **intent:** Operator proves the sealed set survived the trip to backup storage unaltered.
  - **success:** One SHA-256 hash over the sealed blob ships beside it; recompute-and-compare passes on intact sets and fails on any altered byte, locally and on the backup server. No inner hashes — the blob hash transitively covers the sealed contents.
- **CAP-5**
  - **intent:** Operator ships the complete set to the on-prem backup server as one unit.
  - **success:** The backup server holds the blob + hash and post-trip hash re-verification matches.
- **CAP-6**
  - **intent:** Operator keeps the latest 2 sets locally for fast restore without manual pruning.
  - **success:** After a run, only the latest 2 set directories remain; set members are never retained or deleted piecemeal. Prune runs only after the current set shipped and re-verified on the NAS; ordering is by dirname sort over UTC names, never mtime.
- **CAP-7**
  - **intent:** Operator gets either a complete set or an unambiguous failure, never a partial set.
  - **success:** Any induced step failure (capture, bundle, encrypt, hash, ship, prune, plus config-validation and lock-contention cases) exits non-zero naming the failed step and leaves no partial set behind.

## Constraints

- Bash-only, no Python; every step explainable — the script is an audit-grade, mentor-graded learning artifact.
- Scheduler-agnostic: no timing logic in the script; it runs identically by hand or under an external task scheduler.
- Native capture uses `gitlab-backup create STRATEGY=copy` (the 12.2+ spelling, verified through 19.x).
- The set archive (tarball + config volume + compose file + `.env`) is sealed with exactly one `age` invocation to the backup server's public key, supplied out-of-band before the first run; tools (`age`, `rsync`, `ssh`, `sha256sum`) are executables orchestrated from bash, vendored where needed for air-gap portability.
- Transport is rsync over SSH with key auth; the backup stays on-prem across exactly two servers (GitLab host + backup/NAS box).
- One set, one timestamp: one encrypted blob and one hash file live, ship, and delete as a unit.
- Local sets land in the `backups/` folder alongside the compose file under `test-gitlab-server/` (testing/POC placement).
- Verification contract (v2): presence check first, then hash re-verification; the runner accepts only a set at most 24h old with blob + hash present and the hash matching. Updating `backup-contract.md` and the runner's verification step is a parent-deliverable dependency, not work in this build.
- Build discipline (staging→publish both sides, `flock`, output grammar, exit 1, UTC format, dirname sort, `cmp` check, remote stage→verify→rename; POC placement, source tree, tool versions, variable registry) per `ARCHITECTURE-SPINE.md` AD-1/AD-2/AD-5/AD-6/AD-7, normative by reference.

## Non-goals

- Scheduling, retention-horizon enforcement, and off-site copies: horizons are declared policy in `retention-policy.md`; enforcement is explicitly out of scope.
- Automated restore: restore stays manual and documented.
- Log backup: skipped by design.
- Inner/per-artifact hashes: the blob hash transitively covers sealed contents; a second hash layer is explicitly out.
- Live data-volume copies: inconsistent under a running server; the native tarball is the only data capture.
- Parent-deliverable changes (`backup-contract.md` v2, runner verification step) and NAS VM provisioning: dependencies of acceptance, not work in this build.

## Success signal

A single run yields a complete set (one encrypted blob + one matching hash) locally and on the backup server; the runner's pre-migration check passes against a fresh set and fails against a missing, stale (>24h), or incomplete one; and a restore from a produced set is demonstrated at least once against the test instance.

