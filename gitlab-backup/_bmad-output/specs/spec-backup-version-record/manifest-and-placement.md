# Manifest and placement

Companion to `SPEC.md`. Holds the placement verdict, the rejected options with
reasons, the manifest contract, and the known contract ripples.

## Verdict

Small plaintext manifest as the third set member. A set becomes
`<ts>/{set.tar.age,SHA256SUMS,MANIFEST}`.

## Rejected options

- **Version lines inside `SHA256SUMS`.** `SHA256SUMS` is a machine-checked
  integrity file in `sha256sum -c` format. Metadata lines break the verifier
  and the script's strict one-line gate plus its tests. Integrity proof and
  descriptive metadata must not share a line-oriented check format.
- **Version in the set directory name.** The `<ts>` grammar is load-bearing:
  PRUNE's dirname glob and byte-order sort, staging/publish/remote path
  derivation, collision detection, and the runner's backup-contract
  verification all assume `YYYYMMDD-HHMMSS`. A version suffix ripples through
  every one of those contracts.

## Manifest contract

- Format: `KEY=value`, one per line, trailing newline. Human-readable without
  decrypting; machine-parseable with `grep`/`cut`.
- Fields (v1): `gitlab_version` (from the native tarball filename, the version
  that wrote the data), `image` (compose image tag, secondary signal),
  `created_ts` (`<ts>` of the run), `tarball` (native tarball basename).
- Integrity: `SHA256SUMS` gains one hash line per covered file, still pure
  `sha256sum -c` format, so the existing verifier proves the whole set.
- Unit rule: blob + hash + manifest live, ship, verify, prune, and delete as
  one unit — never handle one without the others.

Example:

```text
gitlab_version=17.8.2
image=gitlab/gitlab-ce:17.8.2-ce.0
created_ts=20261106-120000
tarball=1762346400_2025_11_06_17.8.2_gitlab_backup.tar
```

## Source-of-truth rule

The native tarball filename's version segment is the recorded
`gitlab_version`: it names the exact GitLab build that wrote the data, which
is the version a restore needs. The compose image tag is recorded alongside
but never promoted above the tarball version — tags can read `latest` or lag
the running container.

## Known contract ripples (for build)

- HASH entry/publish gates move from exactly-1/exactly-2 to account for the
  manifest; `SHA256SUMS` line-count assertions move from 1 to 2.
- SHIP presence check and remote verification cover all three members.
- PRUNE keeps deleting whole set directories; member count needs no change
  there, but unit wording does.
- `tests/07-hash.bats`, `tests/08-ship.bats`, and any blob-plus-hash
  assertions gain the third member.
- `docs/restore.md`: version step moves before the decrypt step; set
  definition becomes three files.
- The native tarball is wiped by ENCRYPT, so the version must be captured no
  later than BUNDLE (while the tarball is still staged) and carried to the
  manifest writer — stage assignment is a build decision.
