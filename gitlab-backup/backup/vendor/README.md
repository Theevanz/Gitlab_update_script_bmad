# Vendored `age`

`backup/vendor/age` is the publisher's static linux-amd64 `age` 1.3.2
binary, verified into place 2026-11-04 (Story 2.3). Hashes live in
`backup/vendor/age.SHA256`: the publisher's asset digest and the extracted
binary's own SHA-256.

To re-verify the vendored binary (from the checkout root):

1. Run `sha256sum gitlab-backup/backup/vendor/age`.
2. Compare against the binary hash recorded in `backup/vendor/age.SHA256`.
3. On mismatch, do not run a backup — re-vendor from the publisher asset.
(`age.SHA256` is comment-only documentation, so `sha256sum -c` won't check it.)

To re-vendor (e.g. for a version bump, on a machine with network access):

1. Download `age-v1.3.2-linux-amd64.tar.gz` from
   `https://github.com/FiloSottile/age/releases/tag/v1.3.2`.
2. Verify its SHA-256 against the publisher's published digest for that asset.
3. Extract the `age` binary, place it at `backup/vendor/age`, `chmod +x` it.
4. Update `backup/vendor/age.SHA256` with the verified hashes.
5. Confirm `age --version` reports v1.3.2; discard `age-keygen` (the asset
   ships both binaries, only `age` is vendored).

To run without the vendored binary, set `AGE_BIN` to a trusted `age` on
`PATH` (e.g. `AGE_BIN=age`); the test suite stands a recording double in
for `age` via `AGE_BIN`.
