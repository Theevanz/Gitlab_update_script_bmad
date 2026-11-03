# Rubric Review — Architecture Spine gitlab-backup (2026-11-03)

- **Target:** `_bmad-output/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md` (status: draft, altitude: feature, paradigm: pipes-and-filters)
- **Driving spec:** `_bmad-output/specs/spec-gitlab-backup/SPEC.md` + companions (`backup-contents.md`, `capture-and-transport.md`, `retention-policy.md`)
- **Reviewer role:** spine rubric reviewer
- **Date:** 2026-11-03
- **Verdict:** **REQUEST CHANGES** — strong spine, but 3 major findings must be fixed before epic authoring; 2 moderate + 4 minor should be fixed in the same pass.

## Rubric walk

### (1) Fixes the real divergence points for epics, misses none — FAIL (2 misses + 2 gaps)

Covered well: stage order/interleaving (AD-1), local atomicity (AD-2), tool-vs-bash boundary (AD-3), secret handling (AD-4), producer-vs-consumer boundary (AD-5), config precedence (AD-6), failure signaling (AD-7), prune ordering (AD-8).

Misses (see F2):

- **Concurrency / single-flight.** Nothing says what happens on overlapping runs (scheduler overlap, operator double-invoke). One epic adds `flock`, another assumes serial runs → divergent behavior. Real divergence point for a scheduled producer.
- **Remote NAS layout.** Local layout is fixed (`<backups>/<ts>/`), but the SHIP target layout (remote base dir, mirror `<ts>/`?) is unfixed. Local-layout epic and ship epic can diverge; the v2 presence-check consumer also needs this contract.
- **Timestamp single-source + collision.** Convention assumes UTC `YYYYMMDD-HHMMSS` but no rule fixes who generates `<ts>` once per run, or what happens on same-second collision (staging dir clash, publish clash).
- **Post-trip re-verify mechanism.** AD-5 requires re-verification after rsync but not *how/where* (remote `ssh … sha256sum -c` vs local recompute vs `rsync --checksum`). CAP-4 requires proof "locally and on the backup server" — two units can implement different halves.

### (2) Every AD Rule enforceable and actually prevents its stated divergence — FAIL (2 rules overclaim)

- **AD-1** PASS. Exact stage list/order, read-only-prior-artifacts, fail-fast. Reviewable and testable.
- **AD-2** FAIL (see F1). Local half-built prevention is airtight (4-member gate + `sha256sum -c` + atomic `mv` + trap `rm -rf` staging-only). But the stated prevention is "any consumer ever seeing a half-built set" — rsync SHIP can expose a partial set on the NAS mid-transfer, and no remote atomicity (temp dir + rename, `--delay-updates`) is required. Overclaims.
- **AD-3** PASS (minor note: "no retry logic that duplicates tool flags" is slightly vague but review-enforceable).
- **AD-4** PASS with wording wart (see F9: "env var or file path" vs AD-6 "key paths, never key material" needs a pubkey-is-public clarification).
- **AD-5** PASS. Exact 4-member set + `sha256sum -c` format + explicit non-assertion of freshness/validity/fitness. Negative requirement is grep-enforceable.
- **AD-6** FAIL as written (see F4). "No host, path, or key literal in the script body" contradicts the "built-in default" precedence tier — defaults *are* literals. Unenforceable literally; needs "outside the defaults block" scoping.
- **AD-7** PASS. `set -euo pipefail`, `FAIL:<STAGE>:<detail>` + timestamp to stderr, non-zero exit, no partial set (via AD-2), START/DONE stdout lines. Deferred numeric taxonomy is explicit.
- **AD-8** PASS. Newest 2 by dirname sort (never mtime), whole-dir `rm -rf`, gated on ship + remote re-verify. Correctly resolves SPEC CAP-6 ("2") over brief/addendum ("2–3").

### (3) Nothing under Deferred could let two units diverge — FAIL (1 contradiction)

Mostly clean: scheduling, retention-horizon enforcement, off-site, restore, log backup, exit taxonomy, key rotation, consumer contract, NAS provisioning are true non-goals correctly deferred.

- **FAIL (see F3):** Deferred says "CLI flags … v1 is env > env-file > defaults", but the Consistency Conventions table assumes "`--verbose` gates tool output". `--verbose` *is* a CLI flag. One unit implements a flag, another implements `VERBOSE` env → divergence. Pick one.
- Minor: "Rule of Three earns a `lib/`" split trigger is vague about who counts to three; acceptable as a process gate but could name the decider.

### (4) Named tech verified-current — PASS with 1 stale pin

Verified 2026-11-03 via web sources:

| Stack entry | Spine claim | Verified | Status |
|---|---|---|---|
| bash | ≥5.0, prefer 5.3 (Jul 2025) | 5.3 (Jul 2025) still latest stable; distros on 5.3.x patches | current |
| age | 1.3.x (CLI 1.3.1 Dec 2025; X25519) | latest v1.3.2 (Aug 2026); v1.3.0 added PQ recipients, X25519 still supported | STALE PIN — bump parenthetical to 1.3.2 (range 1.3.x already covers) |
| rsync | ≥3.4, prefer 3.5.x (3.5.1 Sep 2026; 3.5.0 fixed 33 CVEs) | 3.5.1 released Sep 21 2026 (rsync.samba.org); 3.5.0 Aug 13 2026 fixed 33 CVEs | current |
| OpenSSH | ≥9.x, prefer 10.x (10.6 Oct 2026) | 10.6 released Oct 6 2026 | current |
| gitlab-backup via GitLab 16.x–17.x | spec range | spec-pinned; current GitLab is newer (18.x/19.x era) — confirm test-box version at build | spec-inherited, flag at build |
| sha256sum (coreutils) | system, format stable | stable ubiquitous format | current |
| BATS | assumption, de-facto standard | correct characterization | fine as assumption |

### (5) Covers the driving spec's capabilities — PASS with 2 gaps

Capability map binds all of CAP-1..CAP-7 and the mapping is correct. Non-goals are all correctly deferred. Gaps:

- **Capture spelling not a rule (see F6).** `docker exec -t <container> gitlab-backup create STRATEGY=copy` lives only in Stack ("seed — the code owns this once it exists"), not in any AD rule. An epic could use the legacy `gitlab-rake gitlab:backup:create` spelling despite the explicit spec constraint. Pin in AD-3.
- **Bundle members not enumerated (see F7).** `backup-contents.md` requires `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys, but the spine never enumerates set-member source paths. BUNDLE epic could omit certs/host keys. Add a convention (paths env-configurable per AD-6).
- Otherwise: CAP-1 frozen copy ✓ (via STRATEGY=copy in stack — see F6), CAP-2 ✓ AD-4, CAP-3 byte-identical ✓ (hash-covered; compare method minor), CAP-4 ✓ AD-5 (+F2 re-verify mechanism), CAP-5 ✓ (+F1 remote atomicity), CAP-6 ✓ AD-8, CAP-7 ✓ AD-2+AD-7. Constraints bash-only ✓, scheduler-agnostic ✓, two-server on-prem ✓, `test-gitlab-server/backups/` POC placement ✓ (structural seed; default path value itself could be pinned — minor). Parent-deliverable v2 contract correctly deferred.

### (6) Every owned dimension decided, deferred, or an open question (operational envelope) — FAIL (no Open Questions section)

- **Deployment:** diagram fixes topology (operator/scheduler → host → NAS, script + Docker GitLab, rsync/SSH Ed25519). But *how the tree reaches the host* (clone? scp? bake into image?) is neither decided, deferred, nor asked.
- **Environments:** decided via AD-6 (same script, env/file changes; POC defaults). Good.
- **Infra:** decided (two servers, NAS storage-only, no NAS logic; NAS provisioning deferred elsewhere). Good.
- **Operations:** scheduling/restore/retention-horizons correctly deferred; failure signaling decided (AD-7). Gaps: **log handling** (who captures/rotates stdout/stderr? scheduler? file?) is nowhere; **key rotation** deferred with no owner; **concurrency** (F2) nowhere.
- **Structural gap:** the spine has **no Open Questions section at all**. Inline `[ASSUMPTION]`s (ts format, filenames, retention 2, `--verbose`, single-script+BATS) mark guesses, but genuine unknowns — remote base dir/SSH user, age-pubkey distribution mechanics, timestamp collision policy, log rotation, deployment method — need a home as decided/deferred/open per the altitude contract.

## Findings (ordered by severity)

- **F1 [MAJOR] AD-2 overclaims: no remote atomicity.** Stated prevention "any consumer ever seeing a half-built set" holds locally but not on the NAS during rsync. *Fix:* extend AD-2 or AD-5 — ship to a temp/partial remote dir (or `--delay-updates`) and remote-rename to `<ts>/` only after remote re-verify passes.
- **F2 [MAJOR] Missing divergence points: concurrency, remote layout, timestamp source/collision, re-verify mechanism.** *Fix:* add rules/conventions — single-flight (`flock` or documented serial-use assumption), remote base path + mirror-`<ts>/` layout, `<ts>` generated once per run + collision behavior, remote re-verify = `ssh … sha256sum -c` (or named alternative).
- **F3 [MAJOR] Deferred-vs-Convention contradiction on CLI flags.** Deferred bans CLI flags; convention assumes `--verbose`. *Fix:* pick one (recommend `VERBOSE` env per AD-6) and correct the convention row.
- **F4 [MODERATE] AD-6 self-contradiction on literals.** "No literal in the script body" vs "built-in default" tier. *Fix:* scope to "no host/path/key literal outside the defaults block".
- **F5 [MODERATE] No Open Questions; deployment + log handling unowned.** *Fix:* add Open Questions section (remote base dir/SSH user, pubkey distribution, collision policy); explicitly decide or defer script deployment to host and stdout/stderr capture/rotation.
- **F6 [MINOR] Capture spelling not rule-bound.** `STRATEGY=copy` + `docker exec -t` only in Stack seed. *Fix:* pin the exact capture invocation in AD-3 (and forbid the legacy `gitlab-rake` spelling).
- **F7 [MINOR] Bundle member list not enumerated.** *Fix:* convention row listing `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys + source-path variables (AD-6 configurable).
- **F8 [MINOR] Stale age pin.** Parenthetical names CLI 1.3.1 (Dec 2025); latest is 1.3.2 (Aug 2026). *Fix:* bump to 1.3.2. Rest of stack verified current (see table); GitLab 16.x–17.x is spec-inherited — confirm test-box version at build.
- **F9 [MINOR] AD-4/AD-6 key-material wording.** "env var or file path" (AD-4) vs "key paths, never key material" (AD-6) can confuse on pubkey-material-in-env. *Fix:* one sentence — pubkey material in env is allowed (public, not secret); private key never on host, never in env/argv/repo/logs.

## What is good (keep)

- Paradigm fits the problem: linear staged pipeline with the set dir as the pipe is the right call for an audit-grade bash producer.
- AD-2 local atomicity (4-member gate + verify + atomic rename + staging-only trap) is precise and testable.
- AD-5 producer/consumer boundary ("emit a complete set; judge nothing") correctly keeps freshness/validity/fitness out.
- AD-8 correctly resolves the SPEC-vs-brief retention conflict in favor of the SPEC.
- Stack claims were near-perfectly current — rsync 3.5.1/33-CVE and OpenSSH 10.6 pins verified exact.
