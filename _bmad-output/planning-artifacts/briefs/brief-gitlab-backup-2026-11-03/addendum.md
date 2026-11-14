# Addendum: gitlab-backup — design detail carried forward

Depth volunteered by the user during Discovery. Preserved here for the downstream spec/build; the brief stays the 1–2 page story.

## Backup content (user's table)

| Piece | Holds | Protection |
|---|---|---|
| Native tarball | Database, repositories, uploads, CI data | Sealed in set archive (`age`) + outer SHA-256 |
| Config volume | Whole `/etc/gitlab` bind (`gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys) | Sealed in set archive (`age`) + outer SHA-256 |
| Compose file | Recipe incl. pinned GitLab version | Sealed in set archive (`age`) + outer SHA-256 |
| Env file | `.env` beside the compose file (ports, passwords, tokens) | Sealed in set archive (`age`) + outer SHA-256 |
| Logs | Nothing worth keeping | Skip |

## Mechanics

- Native capture: `gitlab-backup create STRATEGY=copy` (copy strategy duplicates data aside so the archived set is frozen; `gitlab-backup` is the 12.2+ command, verified 12.2+ through 19.x; `gitlab-rake gitlab:backup:create` is the legacy spelling). The live data volume is never copied — inconsistent under a running server.
- 1 hash shipped per set: SHA-256 of the sealed blob, computed after encryption to prove integrity across the rsync trip. No inner hashes — same blob → same tar → same files.
- Transport: rsync from GitLab host to NAS backup server over SSH with key auth (confirmed).
- Encryption: `age` — exactly one invocation sealing the set archive (single static binary invoked from bash, same standing as `rsync`/`ssh`/`sha256sum`: bash orchestrates, tools execute). Portable and air-gap friendly by vendoring the binary. NAS `age` public key to be supplied out-of-band.
- Runner verification order: presence check first, then hash re-verification.
- Environment carried in: 2 servers (GitLab host + backup/NAS box), backup stays on-prem, GitLab is Docker-hosted. NAS is a VM to be provisioned; this machine acts as the GitLab box.

## Retention policy (declared; enforcement is explicitly not this script's mechanism)

- GitLab host: latest 2 sets (ship buffer + fast local restore).
- Backup server: 7 daily, 4 weekly, 3–6 monthly. Disk need ≈ one-set size × sets kept — measure a real tarball first.
- One set, one timestamp: blob + hash file deleted together, never piecemeal.
- Rationale for depth: mistakes surface late (e.g. project deleted last week).
- Off-site (3-2-1): ship only weekly/monthly sets, encrypted.

## Inherited standards (parent brief)

- Bash-only for auditability; no Python.
- Lightweight, air-gap vettable; every step explainable (mentor-graded learning artifact).
- Docker-based GitLab; backup producer is the follow-on deliverable to the upgrade runner's verify-only contract.
