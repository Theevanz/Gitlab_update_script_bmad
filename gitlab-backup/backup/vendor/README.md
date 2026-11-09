# Vendoring `age`

`backup/vendor/age` must be the publisher's static linux-amd64 `age` 1.3.2
binary. It is intentionally absent from a fresh checkout: a placeholder here
could silently stand in for real encryption, so the slot stays empty until the
real binary is verified into place.

To vendor (on any machine with network access):

1. Download `age-v1.3.2-linux-amd64.tar.gz` from
   `https://github.com/FiloSottile/age/releases/tag/v1.3.2`.
2. Verify its SHA-256 against the hash published on that release page.
3. Extract the `age` binary, place it at `backup/vendor/age`, `chmod +x` it.
4. Replace the `TBD` line in `backup/vendor/age.SHA256` with the verified hash.

Until then, point `AGE_BIN` at a trusted `age` on `PATH`, or run the test
suite (which stands a recording double in for `age` via `AGE_BIN`).
