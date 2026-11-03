# Addendum: gitlab-backup PRD

Depth that belongs downstream or beside the PRD, preserved during Discovery.

## Rejected alternatives

- **Option 2 (encrypt-each, 3 blobs + 3-line hash file).** Rejected: three
  encrypt operations plus set-as-unit enforced by discipline (a directory +
  careful code) instead of by physics. Per-file granularity (decrypt one piece
  without the rest) is unneeded for a rollback path — a restore always needs
  everything.
- **Double hashing (inner per-file hashes + outer blob hash).** Rejected: the
  outer hash transitively covers every sealed byte, so the inner layer guards
  only a seconds-long window on the local disk between tarring and encrypting.
  A second mechanism to explain, test, and break, for no new guarantee.

## Mechanism notes (for the build)

- Hash what ships: SHA-256 is computed over the ciphertext after encryption and
  verified post-trip, so the NAS and the runner can verify receipt without the
  private key (no decryption needed to check integrity).
- `age` is authenticated encryption: decryption fails loudly on tampered bytes
  — a second integrity net that costs nothing.
- Deterministic chain: same blob decrypts to the same tar, which untars to the
  same files. This transitivity is why no inner hashes are needed.
- Whole-volume config: the `/etc/gitlab` bind volume is copied entire — secrets
  live inside it, there is no separate secrets volume. The live data volume is
  never copied (inconsistent under a running GitLab); the native tarball is the
  only data capture. (Grounded in `test-gitlab-server/docker-compose.yml`:
  config/logs/data binds.)

## Inherited constraints (settled in spec/architecture, not re-decided here)

- Config precedence env > `backup.env` file > built-in defaults; `age` public
  key required, validated up front (`FAIL:CONFIG`).
- Staging-to-publish atomicity (hidden `.staging-<ts>`, single `mv`, trap
  cleanup); same discipline mirrored on the NAS.
- Fixed output grammar (`START`/`DONE`/`FAIL:<STAGE>`), single-flight via
  `flock`, exit 1 for all v1 failures.
- Newest-2 local retention by dirname sort; UTC `YYYYMMDD-HHMMSS` set names.
