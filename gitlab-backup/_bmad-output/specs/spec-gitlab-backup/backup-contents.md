# Backup contents — what one set holds

One run produces one timestamped set directory containing exactly two members:

| Member | Holds | Protection |
|---|---|---|
| Sealed blob | Native tarball (database, repositories, uploads, CI data — the only data capture; live data volume never copied) + whole config volume (`gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys) + compose file + `.env` (pinned-version recipe) | One `age` seal to NAS public key + outer SHA-256 |
| Hash file | Single SHA-256 of the sealed blob | `sha256sum -c` format, computed after encryption |

Logs: skipped by design, never enter the set.

One hash ships per set, computed over the sealed blob before sending so it proves integrity across the rsync trip. No inner hashes: same blob → same tar → same files.
