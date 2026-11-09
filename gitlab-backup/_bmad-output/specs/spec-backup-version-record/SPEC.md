---
id: SPEC-backup-version-record
companions:
  - manifest-and-placement.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# Backup version record — GitLab version per set

## Why

A pain to solve. Restores generally need the same GitLab version the backup was taken from, but today a set reveals its version only after decryption — the operator must fetch the blob, decrypt it, and read the pinned image tag inside the sealed compose recipe before knowing whether the set matches the target instance. This work puts the version beside the blob in plaintext, so a version mismatch is visible before any decrypt or restore step begins.

## Capabilities

- **CAP-1**
  - **intent:** Operator reads the GitLab version a backup set was taken from without decrypting anything.
  - **success:** A set directory holds a plaintext manifest naming the GitLab version; the recorded version equals the version segment of the native tarball sealed inside that set.
- **CAP-2**
  - **intent:** Operator ships, verifies, prunes, and deletes the manifest together with the blob and hash as one unit.
  - **success:** Blob + hash + manifest travel as a unit end to end, and any altered manifest byte fails the set's hash re-verification locally and on the NAS.

## Constraints

- `SHA256SUMS` stays pure `sha256sum -c` check format: hash lines only, never metadata lines.
- The `<ts>` set-dirname grammar (`YYYYMMDD-HHMMSS`) is unchanged; no version suffix in the name.
- The recorded version is parsed, never guessed: an unparseable source fails the run rather than recording a fallback.
- The manifest holds no secrets: version, image tag, timestamp, and tarball name only.
- Bash-only, one named function per stage, every tool call commented — same discipline as the existing script.

## Non-goals

- Automated version-compatibility gating: the run records the version; it never refuses to back up or restore on version grounds.
- Version-in-dirname or decrypt-time version checks.
- Runner-side verification changes (`backup-contract.md` v2, runner check step): parent-deliverable follow-up, not work in this build.

## Success signal

A produced set carries a plaintext manifest whose version matches the sealed native tarball's writer version; `sha256sum -c` passes on the intact set and fails on any altered manifest byte; the restore runbook reads the version before the decrypt step.

## Assumptions

- Native tarball filenames carry a parseable version segment across supported GitLab versions (12.2+ through 19.x).
- GitLab version strings are non-secret and safe in a plaintext manifest.

## Open Questions

- Unparseable tarball name: FAIL the run or fall back to the compose image tag? (Recommend FAIL: never record a guessed version.)
- Does `SHA256SUMS` cover the manifest with a second hash line, or does the manifest ship unverified? (Recommend covered: keeps `sha256sum -c` the single verifier.)
