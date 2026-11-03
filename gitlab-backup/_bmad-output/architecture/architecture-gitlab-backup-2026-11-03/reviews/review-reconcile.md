# Reconciliation review — spec package vs architecture spine

- Spec: `_bmad-output/specs/spec-gitlab-backup/SPEC.md` + companions (`backup-contents.md`, `capture-and-transport.md`, `retention-policy.md`)
- Spine: `_bmad-output/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md`
- Date: 2026-11-03
- Verdict: **gaps** (all minor; no capability unaddressed, three quiet requirements dropped or implicit)

## Capabilities

| Spec item | Lands in spine | Assessment |
|---|---|---|
| CAP-1 — frozen timestamped set, native tarball from frozen copy | `CAPTURE` stage; AD-1, AD-2, AD-3; Stack (`gitlab-backup create STRATEGY=copy`, 16.x–17.x) | Clean. Copy-strategy frozen rationale carried by the `STRATEGY=copy` stack pin. |
| CAP-2 — encrypted bundle (config, secrets, certs, host keys); decryptable with backup-server private key; plaintext never leaves host | `BUNDLE`+`ENCRYPT`; AD-3, AD-4; map row CAP-2 | Partial (see F1). Sealing, out-of-band pubkey, wipe, and hash-over-ciphertext all land in AD-3/AD-4. But the member enumeration from `backup-contents.md` (`gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys) appears nowhere — "config bundle" is generic throughout. |
| CAP-3 — compose recipe in set, byte-identical | `BUNDLE` stage; AD-1, AD-3; seed (`docker-compose.yml`, basename preserved) | Lands via implication (see F2). Plain copy + SHA-256 coverage implies byte-identity, but the word "byte-identical" and any copy-verify rule are absent. |
| CAP-4 — one SHA-256 per artifact; recompute-and-compare passes/fails; local + server | `HASH` stage; AD-1, AD-3, AD-5; conventions (`sha256sum -c` format); `backup-contents.md` "three hashes, computed before sending" mirrored in AD-5 "hashed pre-ship" | Clean. |
| CAP-5 — ship complete set to on-prem backup server as one unit; post-trip re-verify matches | `SHIP` stage; AD-1, AD-2, AD-4, AD-5; deployment seed (rsync over SSH, two servers) | Clean. |
| CAP-6 — keep latest 2 locally; never piecemeal | `PRUNE`; AD-1, AD-8 (newest-2 by dirname sort, whole-dir `rm -rf`, runs only after verified ship) | Clean. Spine explicitly resolves the `retention-policy.md` "2–3" vs CAP-6 "2" tension with a SPEC-wins assumption. |
| CAP-7 — complete set or named non-zero failure; no partial set | Traps + staging; AD-2 (staging→publish, trap `rm -rf`s staging only), AD-7 (`FAIL:<STAGE>`, non-zero) | Clean. Induced-failure coverage (capture/encrypt/hash/ship) lands in the BATS seed. |

## Constraints

| Spec constraint | Lands in spine | Assessment |
|---|---|---|
| Bash-only, no Python; every step explainable (audit-grade, mentor-graded learning artifact) | AD-3 ("No Python, no embedded crypto"); conventions ("No JSON in v1 — plain text, audit-readable") | Partial (see F3). The bash-only half lands; the explainability/learning-artifact tone has no convention (readability, commenting, step narration beyond `START`/`DONE` lines). |
| Scheduler-agnostic; identical by hand or scheduler | AD-3 ("no scheduler logic"); invariant diagram (`scheduler/operator → invoke only`, `script never → scheduler`); Deferred (scheduling) | Clean. |
| `gitlab-backup create STRATEGY=copy`, 12.2+ spelling, 16.x–17.x | Stack row pinned verbatim | Clean. |
| `age` to backup-server pubkey, out-of-band; tools are orchestrated executables, vendored for air-gap | AD-3 (one `age` invocation, no fallback), AD-4 (out-of-band pubkey, never hardcoded), Stack (vendored static `age`), seed (`vendor/age`) | Clean. |
| rsync over SSH key auth; on-prem, exactly two servers | AD-3 (ship tool), deployment diagram (GitLab host → NAS VM), conventions (SSH key auth) | Clean. Note: spine narrows "key auth" to Ed25519 without an `[ASSUMPTION]` tag — acceptable elaboration, suggest tagging. |
| One set, one timestamp: live, ship, delete as unit | AD-2 (atomic publish, four members), AD-8 (whole-set prune) | Clean. |
| POC placement: `backups/` beside compose under `test-gitlab-server/` | Deployment seed (`test-gitlab-server/backups/`), AD-6 (defaults target the POC box) | Clean. |
| Verification contract v2: presence first, then hash re-verify; runner accepts ≤24h, all present, hashes match; `backup-contract.md` + runner step are parent dependencies | AD-2 (four members present AND `sha256sum -c` passes), AD-5 (judge nothing: no age/validity checks), Deferred (consumer contract, NAS provisioning) | Mostly lands (see F4). The 24h freshness correctly stays consumer-side. But the explicit presence-first-then-hash ordering (also in `capture-and-transport.md`) is only implicit in AD-2's "present AND verifies" — order unpinned. |

## Non-goals

| Spec non-goal | Lands in spine | Assessment |
|---|---|---|
| Scheduling, retention-horizon enforcement, off-site copies (policy declared, enforcement out) | Deferred item 1 (names `retention-policy.md` horizons 7/4/3–6) | Clean. |
| Automated restore stays manual/documented | Deferred item 2 | Clean. |
| Log backup skipped by design | Deferred item 2; consistent with the exact four-member set (AD-2/AD-5) | Clean. |
| Parent changes (`backup-contract.md` v2, runner step) + NAS provisioning | Deferred (consumer contract + provisioning) | Clean. |

## Companion-only details

- `backup-contents.md` "exactly these members" → lands as AD-2's four shippable members + AD-5's exact set.
- `backup-contents.md` bundle member list → **dropped** (F1).
- `capture-and-transport.md` legacy-spelling note (`gitlab-rake …` excluded) → lands implicitly via the single stack spelling; fine.
- `capture-and-transport.md` "hashes ship beside the set" → lands (SHA256SUMS in set, AD-5).
- `retention-policy.md` NAS horizons, whole-set delete, late-surface rationale, weekly/monthly-only encrypted off-site → horizons + off-site land in Deferred; whole-set delete lands in AD-8; rationale and disk-sizing guidance are informational, correctly not in the spine.
- Spec "Success signal" (restore demonstrated ≥once on the test instance) → acceptance activity, not structure; correctly absent from the spine, no action.

## Findings (ranked)

- **F1 (gap): CAP-2 bundle contents unenlisted.** Spec + `backup-contents.md` name `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys; the spine never lists bundle members. Suggest a one-row convention or seed entry so the builder doesn't under/over-collect.
- **F2 (minor): CAP-3 "byte-identical" implicit only.** Covered mechanically by copy + SHA-256, but no stated rule. One sentence in AD-1's `BUNDLE` description or the map row would pin it.
- **F3 (minor): explainability tone dropped.** "Every step explainable / audit-grade learning artifact" has no landing beyond `START`/`DONE` lines and audit-readable formats. Suggest a brief readability convention (narrating comments, one tool per stage already in AD-3).
- **F4 (minor): presence-before-hash order unpinned.** AD-2's "present AND verifies" should say presence first, then `sha256sum -c`, matching the v2 contract language.
- **F5 (nit): Ed25519 specificity untagged.** Spine narrows spec's "key auth" to Ed25519 in conventions/diagram without `[ASSUMPTION]`. Tag it or soften to "key auth (Ed25519 preferred)".

## Verdict

**Gaps, all minor.** Every CAP, constraint, and non-goal has a structural home; nothing requires a new AD. The recommended fixes are four one-sentence landings (bundle member list, byte-identical, explainability, presence-first) plus one assumption tag.
