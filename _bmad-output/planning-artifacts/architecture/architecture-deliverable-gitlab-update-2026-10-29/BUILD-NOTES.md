# Build notes (companion to ARCHITECTURE-SPINE.md)

Non-binding implementation guidance. Normative rules live in the spine ADs; anything here that conflicts with an AD loses. Kept byte-lean on purpose.

## Probe contracts (byte-identical jq/grep outputs)

- Version: jq `.version` | grep `"version"[[:space:]]*:[[:space:]]*"[^"]*"` stripped to bare `X.Y.z[-ee]`, then AD-3 normalization.
- Runners list: jq `.[] | "\(.id) \(.paused)"` | grep pairs of `"id":<n>` and `"paused":<bool>` in document order.
- Drain per runner: `GET /runners/:id/jobs?status=running&per_page=1`; drained = `[]` for every runner.
- Rake status rows: status = text before first `|` with whitespace trimmed; rows containing no `|` that are not a `Database:` banner or blank = die.
- Hub tags: jq `.results[].name` + `.next` | grep `"name":"..."` + `"next":"..."`; `null` next terminates.

## Env validation order

Lock first, then required-nonempty (URL scheme+host assert), then token-trim, then optional defaults, then file/dir existence (compose, YAML, backup), then edition/repo coherence.

## Hang-counter pseudocode

`flat=0`; each heartbeat: if `rake_delta>0` then `flat=0` else if cpu-int==0 and bio-string-unchanged then `flat+=1` else `flat=0`; `flat>=30` dies GATE=monitor.

## Failure-path exec lines

`docker cp /tmp/gitlabsos.rb $CID:/tmp/gitlabsos.rb` then `compose exec -T $SVC /opt/gitlab/embedded/bin/ruby /tmp/gitlabsos.rb -o /tmp/sos` then `docker cp $CID:/tmp/sos ./failure-bundle-<t>-<e>/`; any step failing falls to the AD-12 native manifest.

## Residual risks (accepted)

- Hub legacy tags path is the non-preferred surface and could retire or tighten auth; AD-14 dies loudly either way, and the namespaced `/v2/namespaces/.../tags` is the documented successor.
- The `:status` grammar is verified against the 16-11-stable source; 17.x point releases could in principle alter padding — the pipe-shape assert catches that as a loud halt, never a mis-parse.
- `cpu_raw`/`bio_raw` string comparisons are host-locale sensitive in theory; the single-maintainer demo host makes this negligible, and the spaced-digit guard (AD-16) covers the known Docker formats.
