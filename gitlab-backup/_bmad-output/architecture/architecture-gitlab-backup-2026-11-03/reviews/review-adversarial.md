# Adversarial Spine Review — gitlab-backup

- Target: `_bmad-output/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md` (status: draft, 2026-11-03)
- Role: adversarial reviewer
- Method: construct pairs of units one level down (epics/stories implementing parts of the single bash backup script) that each obey every AD to the letter, yet combine into an incompatible build. Every such pair is a hole.
- Verdict: **REJECT — spine under-constrains integration; 5 incompatible pairs survive literal compliance.**

All pairs below assume good-faith builders who read only the spine + SPEC references and follow every AD exactly as written.

---

## Pair 1 — Env var registry: two config dialects, both AD-6 compliant

**Unit A (story: "CAPTURE + config plumbing")** defines and documents:
`BACKUP_DIR, NAS_HOST, NAS_DIR, CONTAINER, COMPOSE_PATH, AGE_PUBKEY_FILE, RETENTION_COUNT, ENV_FILE`
with precedence `real env > backup.env > default`, `backup.env.example` tracked, real file gitignored, no secrets on argv, fail fast `FAIL:CONFIG`.

**Unit B (story: "SHIP + PRUNE + key plumbing")** defines and documents:
`GITLAB_BACKUP_DIR, BACKUP_NAS_HOST, BACKUP_NAS_PATH, GITLAB_CONTAINER_NAME, GITLAB_COMPOSE_FILE, AGE_PUBLIC_KEY, AGE_KEY_PATH, KEEP_SETS`
with identical precedence, sourcing, gitignore, and `FAIL:CONFIG` behavior.

**Why both obey the letter:** AD-6 enumerates *categories* ("NAS hostname, backup dir, container name, compose path, key paths, retention count") and the *mechanism* (precedence, `backup.env`/`ENV_FILE`, `backup.env.example`, front validation, no argv secrets, no literals) but never freezes the *canonical variable names*, so both units satisfy every sentence of AD-6 while sharing zero names.

**Resulting incompatibility:** A and B each ship a `backup.env.example` fragment with disjoint keys; merged script reads one dialect per stage. Operator sets `BACKUP_DIR` per Unit A's docs → SHIP/PRUNE (Unit B) ignore it and fall back to POC defaults, writing/pruning the wrong directory. Validation passes (each unit validates only its own names) yet the run silently spans two directories. Secrets-on-ps rule holds in both, so no AD fires.

**Hole:** AD-6 constrains config *mechanism* but not config *vocabulary*.
**Close by:** tighten AD-6 (or add AD-6a registry): freeze the exact variable list with exact spellings, meanings, which are required vs defaulted, and the single owner of `backup.env.example`. Suggested minimum: `BACKUP_DIR, NAS_HOST, NAS_DIR, CONTAINER, COMPOSE_PATH, AGE_PUBKEY (value-or-path? pick one), RETENTION_COUNT, ENV_FILE` — any spelling works, but exactly one must be normative. Add: "no stage introduces a new env var without amending the registry."

## Pair 2 — Timestamp + filenames: two sets that never match, both convention-compliant

**Unit A (story: "CAPTURE + set-dir creation"):** at script start, `TS=$(date -u +%Y%m%d-%H%M%S)` once; set dir `<backups>/$TS/`; staging `.staging-$TS/`; expects tarball `<native>.tar`, bundle `config.tar.age`, compose basename preserved, manifest `SHA256SUMS`.

**Unit B (story: "BUNDLE + ENCRYPT + HASH"):** per-stage `TS=$(date +%Y%m%d-%H%M%S)` (local time, no `-u`, regenerated at BUNDLE start); writes bundle as `config.bundle.tar.age` ("the config bundle (.age)" per AD-5's loose phrase); copies compose to fixed name `docker-compose.yml`; writes manifest `SHA256SUMS` but with `./`-prefixed paths.

**Why both obey the letter:** The `YYYYMMDD-HHMMSS UTC` rule lives in Consistency Conventions as `[ASSUMPTION]`, not in a binding AD; AD-2 names members loosely ("tarball", "`config.tar.age`", "compose copy", "manifest") with "e.g." examples; AD-5 says "{tarball, config bundle (.age), compose file, SHA256SUMS}" without exact filenames; no AD says "generate TS once" vs "per stage" or "UTC via `date -u`". Both units can claim compliance: A follows the convention text, B follows the AD text where it is vaguer.

**Resulting incompatibility:** If the run straddles a second boundary or the host TZ ≠ UTC, B writes into a different `TS` than A created (or a second staging dir), so HASH/SHIP see a partial set that AD-2's "exactly four members" check rejects — or worse, two sibling set dirs each half-complete. Even within one second, `config.bundle.tar.age` ≠ `config.tar.age` breaks AD-2's publish gate in one unit's check while passing the other's; `./`-prefixed vs bare `SHA256SUMS` entries break `sha256sum -c` depending on cwd; fixed `docker-compose.yml` overwrites/misses hosts using `compose.yaml`. Timezone drift also breaks AD-8's "dirname sort = newest" ordering across DST changes.

**Hole:** Timestamp generation (source, timezone, single-point-of-generation, collision on same-second rerun) and the exact 4-member filename registry are `[ASSUMPTION]`-grade conventions, not binding ADs.
**Close by:** promote to a tightened AD-2/AD-5 (or new AD-9 "Set naming"): freeze (a) `TS` generated exactly once in preamble via `date -u +%Y%m%d-%H%M%S`, exported to all stages, never regenerated; (b) exact member names: native tarball preserved byte-for-byte, `config.tar.age` exactly, compose `<source basename>` exactly (no rename), `SHA256SUMS` exactly; (c) `SHA256SUMS` entry format (bare filenames, no `./`, generated from inside set dir); (d) same-second-collision rule (fail vs suffix — pick one).

## Pair 3 — Stage boundaries: publish and verify each owned twice, both AD-1/AD-2/AD-5 compliant

**Unit A (story: "HASH"):** owns staging→publish: at end of HASH, after `sha256sum -c` passes in staging, `mv .staging-$TS $TS`. SHIP then rsyncs from the *published* dir. Remote re-verify is SHIP's job (`ssh … sha256sum -c`), per AD-5 "re-verifies hashes after the rsync trip."

**Unit B (story: "SHIP + PRUNE"):** owns staging→publish: SHIP rsyncs from *staging*, runs remote re-verify, and only then publishes (`mv` staging → visible). HASH never publishes; it only writes `SHA256SUMS` in staging.

**Why both obey the letter:** AD-1 lists six stages with no `PUBLISH` step and never assigns the `mv` to a stage. AD-2 says "publish happens only when…" (a *precondition*, not an *owner* or *ordering vs SHIP*). AD-5 requires both "hashed pre-ship" and "re-verifies after rsync" but never says which stage performs the remote check or where SHIP reads from. Both orderings satisfy every stated precondition.

**Resulting incompatibility:** Combined build either publishes twice (second `mv` fails → `FAIL:SHIP` on a healthy run, or publishes-then-ships-from-staging races the trap's `rm -rf` on failure) or never publishes (each unit waits for the other: HASH assumes SHIP publishes, SHIP assumes HASH published). PRUNE (AD-8 "after successful ship + remote re-verify") sorts visible dirs — under Unit A's order it can prune the just-published set's predecessor correctly, under Unit B's order the new set is invisible until after SHIP, so a failed SHIP leaves a staged-but-invisible set the next run's `TS` collides with or orphans. The remote re-verify also double-runs or zero-runs depending on which unit's assumption wins.

**Hole:** AD-1/AD-2/AD-5 define stage *names* and *preconditions* but not *boundary ownership* of publish (`mv`) or remote re-verify.
**Close by:** tighten AD-1 + AD-2: assign publish to exactly one stage and fix its position relative to SHIP. Recommended: HASH ends with local `sha256sum -c` + atomic `mv` (publish); SHIP reads only from published dir and owns remote re-verify; PRUNE reads only published dirs. Add: "no stage other than HASH creates/renames/removes set dirs; SHIP never touches staging."

## Pair 4 — Two owners of SHA256SUMS (and staging contents), both AD-3/AD-5 compliant

**Unit A (story: "HASH"):** owns `SHA256SUMS`: `cd staging && sha256sum <tarball> config.tar.age <compose> > SHA256SUMS`, covering exactly the three payload members.

**Unit B (story: "SHIP"):** also writes `SHA256SUMS`: after rsync, appends a "shipped OK" trailer line (or regenerates the file to include remote paths/timestamps for auditability), arguing AD-5's "re-verifies hashes after the rsync trip as a check on its own shipment" authorizes it to produce the shipment's hash record, and AD-3's "one tool per stage" only constrains *tools*, not *files*.

**Why both obey the letter:** AD-3 partitions by *tool* (`sha256sum` → hash stage) but never says "only HASH writes `SHA256SUMS`." AD-5 requires both a pre-ship manifest and a post-ship re-verify without stating the re-verify is read-only. AD-2's "manifest that doesn't verify" gate runs at publish time, so a post-publish SHIP append passes the gate and then corrupts the artifact.

**Resulting incompatibility:** SHIP's append/regeneration breaks `sha256sum -c` for every downstream consumer and for the next run's assumptions (trailer lines fail strict parsers; regenerated paths mismatch payload names from Pair 2). Alternatively the two units race: HASH writes bare names, SHIP rewrites with absolute remote paths, and the locally-published vs remotely-stored manifests diverge — AD-5's "hashes cover the shipped bytes" holds for neither. Same pattern threatens `backup.env.example` (every stage appends its vars) and the staging dir itself (CAPTURE creates it vs preamble creates it — AD-2 names staging but no AD assigns its creation).

**Hole:** No AD assigns single-writer ownership per artifact.
**Close by:** tighten AD-3 or AD-5 with a writer-ownership table: `SHA256SUMS` written exactly once by HASH, never modified after publish (SHIP's re-verify is read-only: `ssh … 'cd … && sha256sum -c'` with no write); staging dir created exactly once by preamble/CAPTURE; `backup.env.example` owned by exactly one unit. Add: "any stage writing a file owned by another stage is a violation."

## Pair 5 — Error + progress formats: two dialects the scheduler can't grep, both AD-7 compliant

**Unit A (story: "CAPTURE + BUNDLE + traps"):** `STAGE=capture` (lowercase); trap prints `FAIL:capture:<detail> ts=<ts>` to stderr; progress lines `START capture <ts>` / `DONE capture <artifact> <bytes>` to stdout.

**Unit B (story: "SHIP + PRUNE + config validation"):** `STAGE=SHIP` (uppercase, AD-1 spelling); trap prints `FAIL:SHIP:<detail> <ts>` (space-separated ts); config failures print `FAIL:CONFIG` with no ts (no set exists yet — AD-6's example shows no timestamp); progress lines `SHIP START …` / `SHIP DONE …`.

**Why both obey the letter:** AD-7's template `FAIL:<STAGE>:<detail>` never freezes the `<STAGE>` vocabulary (AD-1's uppercase names? lowercase? `CONFIG`? `PUBLISH`? `VERIFY`?), the timestamp attachment format ("with the set timestamp" — suffix? `ts=`? position?), or the `START`/`DONE` line grammar ("one line per stage (`START`/`DONE` + artifact + bytes)" — field order? separator? stage name included?). AD-6's `FAIL:CONFIG` introduces a seventh pseudo-stage name AD-1 never lists. `--verbose` gating of tool output is `[ASSUMPTION]`, so A passes tool stderr through always while B suppresses it — both compliant.

**Resulting incompatibility:** Scheduler alerting (`grep FAIL:`) catches both, but routing (`case $STAGE`) misses half; timestamp extraction for correlation fails on the other half's format; `FAIL:CONFIG` with no ts breaks any parser expecting a trailing ts. Progress-line consumers (dashboards, log scrapers) need two grammars. Verbose-mode divergence means one stage's `rsync` output floods stdout (breaking byte-count parsing) while another's is silent. Exit code is uniformly 1 (deferred taxonomy), so the string format is the *only* signal — and it has two dialects.

**Hole:** AD-7 specifies an error *shape* but not an error/progress *grammar*.
**Close by:** tighten AD-7 into a normative grammar: freeze `<STAGE> ∈ {CONFIG, CAPTURE, BUNDLE, ENCRYPT, HASH, SHIP, PRUNE}` (uppercase, exactly these seven — promote CONFIG to a named pre-stage); freeze trap format byte-for-byte, e.g. `FAIL:<STAGE>:<detail> ts=<ts>` (with `ts=-` when no set exists); freeze progress format, e.g. `START <STAGE> ts=<ts>` / `DONE <STAGE> artifact=<name> bytes=<n> ts=<ts>`; freeze stdout-vs-stderr routing and `--verbose` semantics (tool output to stderr only when `--verbose`, never to stdout).

---

## Secondary holes (no full pair constructed, but same class)

1. **Wipe scope (AD-3/AD-4):** "the plaintext is `rm`d" vs "plaintext staging is wiped" — one file (`config.tar`) or whole staging plaintexts? A unit wiping only `config.tar` leaves temp files; a unit wiping `staging/*` beside the `.age` can delete the tarball. Tighten AD-4: enumerate exactly which paths are wiped, in which stage, gated on what exit code.
2. **PRUNE count source (AD-8 vs AD-6):** AD-8 hardcodes newest-2 `[ASSUMPTION]`; AD-6 lists "retention count" as env-configurable. A unit hardcoding 2 and a unit reading `$RETENTION_COUNT`/`$KEEP_SETS` (see Pair 1) both comply. Tighten: one source of truth (env with default 2) and one variable name.
3. **Single-script split rule (Deferred "Rule of Three"):** "stays one file until the Rule of Three earns a `lib/`" is not a buildable criterion — two units can each add a second file claiming the third duplication. Tighten or delete: either "exactly the Structural Seed tree, no new files without architecture amendment" or a mechanical trigger.
4. **BATS placement (Structural Seed `[ASSUMPTION]`):** `tests/*.bats` per-stage + induced-failure tests are assumed, not bound by any AD, so a unit can ship with no tests while claiming full AD compliance. If tests are required, promote to an AD.

## Minimal close set (recommended)

| # | Action | Targets |
|---|---|---|
| 1 | Freeze canonical env var registry + single `backup.env.example` owner | AD-6 (Pair 1, §2) |
| 2 | Promote TS + filename registry to binding AD | AD-2/AD-5 (Pair 2) |
| 3 | Assign publish + remote re-verify to exactly one stage each; fix SHIP input (published vs staging) | AD-1/AD-2 (Pair 3) |
| 4 | Add single-writer ownership table for `SHA256SUMS`, staging, `backup.env.example` | AD-3/AD-5 (Pair 4) |
| 5 | Freeze `FAIL:`/`START`/`DONE` grammar byte-for-byte incl. `CONFIG` pseudo-stage and `ts=-` | AD-7 (Pair 5) |

Close all five and literal-compliance builds converge; close fewer and at least one incompatible pair above still ships.
