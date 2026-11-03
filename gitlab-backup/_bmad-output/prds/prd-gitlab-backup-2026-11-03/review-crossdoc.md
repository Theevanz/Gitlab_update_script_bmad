Verdict: INCONSISTENT — do not build yet; 1 critical + 4 high findings (retention count, stage model, set-archive term, config-path var, retention configurability) must be resolved first.

# Cross-doc consistency review — gitlab-backup (one blob + one hash)

Docs read fully: `prds/prd-gitlab-backup-2026-11-03/prd.md` + `addendum.md`; `brief-gitlab-backup-2026-11-03/brief.md` + `addendum.md`; `specs/spec-gitlab-backup/SPEC.md` + `backup-contents.md` + `capture-and-transport.md` + `retention-policy.md`; `architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md`.

## F1 — Retention "2–3 sets" survives in two live files vs "2" everywhere else [critical]

- brief `addendum.md:25`: "GitLab host: latest 2–3 sets (ship buffer + fast local restore)."
- `retention-policy.md:3`: "The script enforces nothing here except the local 2–3 sets (CAP-6); everything else is owned by operators and schedulers around it."
- vs `retention-policy.md:5` (same file): "GitLab host: latest 2 sets (ship buffer + fast local restore)."
- vs `SPEC.md:38-39` (CAP-6): "Operator keeps the latest 2 sets locally for fast restore without manual pruning." / "After a run, only the latest 2 set directories remain; set members are never retained or deleted piecemeal."
- vs `prd.md:80` (FR-9): "After a verified ship, the newest 2 local sets remain (dirname order);"
- vs `brief.md:12`: "keeps the latest 2 sets locally" and `brief.md:41`: "local retention of the latest 2 sets"
- vs `ARCHITECTURE-SPINE.md:157-159` (AD-8): "keep the newest 2 set dirs by dirname sort (never mtime) and `rm -rf` whole losers only (SPEC CAP-6 settles the brief's "2–3" at 2)."
- Suggested fix: change both "2–3" occurrences to "2". In brief `addendum.md:25` either fix to "latest 2 sets" or mark the line superseded with a pointer to SPEC CAP-6. In `retention-policy.md:3` change to "except the local 2 sets (CAP-6)".

## F2 — Stage model: PRD/SPEC test 4 stages, ARCH builds 6 (+CONFIG/LOCK) [high]

- `prd.md:102-103`: "An induced failure at each stage (capture, seal, hash, ship) produces a named failure with nothing partial left behind."
- `SPEC.md:42` (CAP-7): "Any induced step failure (capture, seal, hash, ship) exits non-zero naming the failed step and leaves no partial set behind."
- `prd.md:30-33` (In): "bundle-then-encrypt seal (exactly one `age` invocation)" — treats bundle+encrypt as one "seal" stage.
- vs `ARCHITECTURE-SPINE.md:24-26`: "flowchart LR / CAPTURE --> BUNDLE --> ENCRYPT --> HASH --> SHIP --> PRUNE"
- vs `ARCHITECTURE-SPINE.md:28-30`: "`CAPTURE` (native tarball) → `BUNDLE` (tarball + config volume + compose → `set.tar`) → `ENCRYPT` (`set.tar` → `set.tar.age`, wipe plaintexts) → `HASH` (single hash over sealed blob) → `SHIP` (rsync to remote staging, re-verify, remote-publish) → `PRUNE` (local newest-N)."
- vs `ARCHITECTURE-SPINE.md:52` (AD-1): "Exactly the stages `CAPTURE → BUNDLE → ENCRYPT → HASH → SHIP → PRUNE` in order."
- vs `ARCHITECTURE-SPINE.md:146` (AD-7): "stage vocabulary: `CONFIG CAPTURE BUNDLE ENCRYPT HASH SHIP PRUNE LOCK`"
- PRUNE, CONFIG, LOCK failures and the BUNDLE/ENCRYPT split have no induced-failure coverage in PRD/SPEC.
- Suggested fix: align PRD + SPEC to the ARCH vocabulary. Rewrite both induction lists as "(capture, bundle, encrypt, hash, ship, prune)" plus config-validation and lock-contention cases, and restate "seal" as the BUNDLE→ENCRYPT pair, not a stage. Update PRD NFR-1 "one named function per stage" count accordingly (6 stage functions + config/lock handling).

## F3 — "Set archive" means plaintext tar in SPEC/PRD but encrypted output in ARCH AD-5 [high]

- `SPEC.md:49`: "The set archive (tarball + config volume + compose file) is sealed with exactly one `age` invocation to the backup server's public key" — archive is the input to age (plaintext).
- `prd.md:59-60` (FR-4): "The run tars tarball(From gitlab for its data) + config volume(gitlab configs) + compose file into one set archive and seals it with exactly one `age` invocation" — archive is plaintext.
- `brief.md:22-23`: "Tars all three into one set archive and encrypts it once with `age`" — archive is plaintext.
- `capture-and-transport.md:4`: "`tar` bundles tarball + config volume + compose file into one set archive; `age` ... seals it with exactly one invocation." — archive is plaintext.
- vs `ARCHITECTURE-SPINE.md:109` (AD-5): "The producer emits exactly `{set archive (.age), SHA256SUMS}`, hashed pre-ship in `sha256sum -c` format." — archive is the encrypted output.
- vs ARCH's own `ARCHITECTURE-SPINE.md:28-30` + `:53-55` (AD-1): "`BUNDLE` tars the native tarball + whole config volume + compose copy ... into `set.tar`; `ENCRYPT` seals `set.tar` to `set.tar.age`" — `set.tar` is the archive, `set.tar.age` the sealed blob.
- Suggested fix: in AD-5 change "`{set archive (.age), SHA256SUMS}`" to "`{sealed blob (`set.tar.age`), `SHA256SUMS`}`". Reserve "set archive" / "`set.tar`" for the plaintext tar and "blob" / "sealed blob" / "`set.tar.age`" for the encrypted output everywhere; add that glossary row to ARCH Consistency Conventions.

## F4 — PRD requires a configurable config-volume path; ARCH registry has no such variable [high]

- `prd.md:51-52` (FR-2): "The run copies the whole config volume that is mounted to docker container(host-side bind path supplied via config — holds `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys)"
- `prd.md:111-112` (Dependencies): "NAS `age` public key plus NAS/SSH/container/config paths, supplied out-of-band before the first run (build inputs, not PRD gaps)."
- vs `ARCHITECTURE-SPINE.md:135-136` (AD-6 registry): "(`backup.env.example` is the single owner): `BACKUP_DIR NAS_HOST NAS_USER NAS_DIR SSH_KEY_FILE AGE_PUBKEY_FILE GITLAB_CONTAINER COMPOSE_FILE RETENTION_COUNT VERBOSE ENV_FILE`." — no config-volume variable.
- vs `ARCHITECTURE-SPINE.md:123-124` (AD-6): "Every environment-specific value — NAS hostname, backup dir, container name, compose path, key paths, retention count — resolves by precedence" — config path not listed.
- Suggested fix: add one variable (e.g. `CONFIG_VOLUME` or `GITLAB_CONFIG_DIR`) to the AD-6 registry with its POC default taken from `test-gitlab-server/docker-compose.yml`, document it in `backup.env.example`, and reference it from FR-2. AD-6's "no epic invents a variable that bypasses it" rule means the build is blocked until this entry exists.

## F5 — `RETENTION_COUNT` configurable in ARCH vs fixed "2" in PRD/SPEC/brief [high]

- `ARCHITECTURE-SPINE.md:123-124` (AD-6): "retention count" is among values resolving by "real env > `backup.env` file > built-in default".
- `ARCHITECTURE-SPINE.md:135-136` (AD-6 registry): includes `RETENTION_COUNT`.
- vs `prd.md:80` (FR-9): "the newest 2 local sets remain (dirname order)"
- vs `SPEC.md:38-39` (CAP-6): "only the latest 2 set directories remain"
- vs `brief.md:41`: "local retention of the latest 2 sets"
- vs `ARCHITECTURE-SPINE.md:157` (AD-8): "keep the newest 2 set dirs by dirname sort (never mtime)"
- Suggested fix: decide one rule. Recommended for v1 simplicity: 2 is fixed behavior — remove `RETENTION_COUNT` from the registry (or mark it reserved/unused in v1 and have PRUNE ignore env). Alternative: 2 is the default — reword FR-9/CAP-6/AD-8 as "default 2, overridable via `RETENTION_COUNT`" with precedence stated. Do not ship with both readings live.

## F6 — `backup-contents.md` says "exactly two members" then shows a 3-row table [medium]

- `backup-contents.md:3`: "One run produces one timestamped set directory containing exactly two members:"
- `backup-contents.md:5-9`: rows "Sealed blob" / "Hash file" / "Logs | Nothing worth keeping | Skipped by design" — a reader counting rows sees three members.
- vs `prd.md:43-44`: "A set is one timestamped directory holding exactly one encrypted blob plus one hash file."
- vs `SPEC.md:51`: "One set, one timestamp: one encrypted blob and one hash file live, ship, and delete as a unit."
- Suggested fix: remove the Logs row from the members table and move it to a note below ("Logs: skipped by design, never enter the set."), leaving a 2-row members table matching "exactly two members". (Contrast: brief `addendum.md:7-12` correctly lists 3 seal-inputs + Logs-skip as pre-seal contents — that 4-row table is fine once this file stops mixing members with non-members.)

## F7 — Runner path `$BACKUP_PATH` (brief) vs producer `BACKUP_DIR` (ARCH); no mapping [medium]

- `brief.md:28`: "needs a fresh, complete, verifiable backup at `$BACKUP_PATH` before every migration stop."
- vs `ARCHITECTURE-SPINE.md:135-136` (AD-6 registry): has `BACKUP_DIR` (plus `NAS_DIR`), no `BACKUP_PATH`.
- vs `ARCHITECTURE-SPINE.md:166`: "Set dir `<backups>/<ts>/`, `<ts>` = UTC `YYYYMMDD-HHMMSS`, computed once per run."
- vs `SPEC.md:52`: "Local sets land in the `backups/` folder alongside the compose file under `test-gitlab-server/` (testing/POC placement)."
- No doc states whether `$BACKUP_PATH` is the local `<BACKUP_DIR>/<ts>/`, the remote `<NAS_DIR>/<ts>/`, a parent-contract alias, or which `<ts>` the runner reads.
- Suggested fix: define all three in one place (SPEC Constraints or ARCH Conventions): `$BACKUP_PATH` = runner's read path per parent `backup-contract.md` v2 (state local vs NAS and latest-`<ts>` resolution), `BACKUP_DIR` = producer local root, `NAS_DIR` = remote root; give the resolution rule (e.g. runner reads newest `<ts>/` under the agreed root).

## F8 — SPEC CAP-6 omits the prune guard and ordering rule PRD+ARCH require [medium]

- `prd.md:80-82` (FR-9): "After a verified ship, the newest 2 local sets remain (dirname order); losers are deleted whole, never piecemeal; prune never runs unless the current set shipped and verified."
- `ARCHITECTURE-SPINE.md:157-160` (AD-8): "After a successful ship + remote re-verify, keep the newest 2 set dirs by dirname sort (never mtime) and `rm -rf` whole losers only ... Prune never runs unless the current set shipped and verified."
- vs `SPEC.md:38-39` (CAP-6): "After a run, only the latest 2 set directories remain; set members are never retained or deleted piecemeal." — no verified-ship precondition, "latest" undefined (mtime? name?).
- Suggested fix: append to CAP-6 success: "Prune runs only after the current set shipped and re-verified on the NAS; ordering is by dirname sort over UTC `YYYYMMDD-HHMMSS` names, never mtime."

## F9 — Seal/blob/bundle/manifest/`SHA256SUMS` drift; ARCH pins filenames PRD leaves open [medium]

- `prd.md:14-16` (Goal): "confidentiality (the whole set sealed with `age`) and integrity (one SHA-256 over the sealed set)" — seal=encrypt; hash over "set".
- `prd.md:31`: "bundle-then-encrypt seal (exactly one `age` invocation)" and `prd.md:57`: "Seal (bundle-then-encrypt)" — seal=bundle+encrypt.
- `prd.md:67` (FR-6): "one SHA-256 over the sealed blob" — hash over "blob" (vs Goal's "set").
- `brief.md:12`: "sealed into one archive, encrypted once" — seal reads as tar; vs `brief.md:23`: "Tars all three into one set archive and encrypts it once"; vs `brief.md:41`: "bundle-then-encrypt seal" — seal reads as both.
- brief `addendum.md:9-11`: Protection "Sealed in set archive (`age`) + outer SHA-256" (blurs tar vs age); `addendum.md:19`: "`age` — exactly one invocation sealing the set archive" (seal=encrypt).
- `capture-and-transport.md:4`: "Seal: `tar` bundles ... into one set archive; `age` ... seals it" — heading uses Seal for both, verb for encrypt.
- `ARCHITECTURE-SPINE.md:28-30` splits BUNDLE vs ENCRYPT cleanly, but `AD-1:54-55` / `AD-3:90-92` reuse "seals/sealing `set.tar` to `set.tar.age`" for the encrypt step.
- `ARCHITECTURE-SPINE.md:66-69` (AD-2): "or a manifest that doesn't verify" — "manifest" appears nowhere in PRD/brief/SPEC, which say hash file / SHA-256 / `SHA256SUMS`.
- `ARCHITECTURE-SPINE.md:166`: "Sealed blob is `set.tar.age`; manifest is `SHA256SUMS` (one line)." — pins both filenames.
- vs `prd.md:115-116`: "[ASSUMPTION] Sealed blob filename is `set.tar.age`; the build may rename it. The PRD pins "one blob + one hash", not the name." SPEC never pins filenames either.
- Suggested fix: (1) adopt ARCH's BUNDLE≠ENCRYPT split as canonical; reserve "seal" for the age step only (or ban bare "seal" — write "bundle" and "encrypt"); reserve "blob/sealed blob" for `set.tar.age`, "set archive/`set.tar`" for plaintext tar, "hash file/`SHA256SUMS`" for the hash; delete "manifest" or define once as ≡`SHA256SUMS`. (2) Reconcile the filename pin: either PRD yields ("filenames now pinned by ARCH as `set.tar.age` + `SHA256SUMS`") — update the PRD assumption — or ARCH softens its row to defaults the build may rename.

## F10 — SPEC claims to be "the complete contract" yet omits staging/flock/grammar/exit/format mechanisms PRD-addendum + ARCH require [medium]

- `SPEC.md:12`: "This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate."
- Yet none of SPEC.md / `backup-contents.md` / `capture-and-transport.md` / `retention-policy.md` mention: hidden `.staging-<ts>` + single-`mv` publish + `ERR`/`EXIT` trap, remote staging mirror, `flock` single-flight, `START`/`DONE`/`FAIL:<STAGE>` grammar, exit code, UTC `YYYYMMDD-HHMMSS` format with single computation, dirname-sort ordering, `cmp` byte-identity check, or remote `.staging`+rename ship flow.
- Those mechanisms live only in: PRD `addendum.md:34-40` ("Config precedence env > `backup.env` file > built-in defaults; `age` public key required, validated up front (`FAIL:CONFIG`)." / "Staging-to-publish atomicity (hidden `.staging-<ts>`, single `mv`, trap cleanup); same discipline mirrored on the NAS." / "Fixed output grammar (`START`/`DONE`/`FAIL:<STAGE>`), single-flight via `flock`, exit 1 for all v1 failures." / "Newest-2 local retention by dirname sort; UTC `YYYYMMDD-HHMMSS` set names.") and ARCH AD-1 (`:52-60`, incl. `:54` "checked with `cmp`"), AD-2 (`:62-80`), AD-5 (`:109-117`, incl. `:112-114` remote `.staging` + re-verify + rename), AD-6 (`:119-138`), AD-7 (`:140-151`), Conventions (`:166`).
- Exit-code narrowing: `SPEC.md:42` says "exits non-zero" while PRD `addendum.md:39` and `ARCHITECTURE-SPINE.md:148-151` pin "exit 1 for all v1 failures" (compatible, but only the latter is testable).
- Suggested fix: either narrow the SPEC header claim ("capability contract; build discipline lives in ARCH + PRD addendum, referenced normatively") or promote the mechanisms into SPEC Constraints (staging→publish both sides, flock, grammar, exit 1, UTC format computed once, dirname sort, cmp check). Minimum: align exit code to "exit 1" in CAP-7 and add explicit SPEC pointers to AD-2/AD-5/AD-6/AD-7 so "complete" holds by reference.

## F11 — ARCH-only elaborations with no upstream support; version-range drift [low]

- POC placement `test-gitlab-server/backups/`: `SPEC.md:52`, `capture-and-transport.md:7` ("Local sets land in `test-gitlab-server/backups/` beside `docker-compose.yml`"), `ARCHITECTURE-SPINE.md:192` — PRD and brief never mention any path.
- Source tree: `ARCHITECTURE-SPINE.md:210-216` ("`backup/gitlab-backup.sh` ... `backup.env.example` ... `vendor/age` ... `tests/*.bats`") — no other doc mentions these paths.
- Tool versions: `ARCHITECTURE-SPINE.md:178-184` (bash ≥5.0; age 1.3.2; rsync ≥3.2/prefer ≥3.5.1; OpenSSH ≥9.x/prefer 10.x; BATS ≥1.13) — no other doc pins versions.
- Env-file mechanics: `ARCHITECTURE-SPINE.md:125-138` (sources `$SCRIPT_DIR/backup.env`, `ENV_FILE` override, tracked `backup.env.example` vs gitignored real file, "holds no secrets") — PRD `prd.md:85-86` (FR-11) says only "environment-supplied config, validated up front"; SPEC never mentions an env file (only PRD `addendum.md:34` states the env > file > defaults precedence).
- `docker exec` wrapper: `ARCHITECTURE-SPINE.md:179` ("`docker exec -t <container> gitlab-backup create STRATEGY=copy`") — all other docs say only "`gitlab-backup create STRATEGY=copy`" (`prd.md:48-49`, `SPEC.md:48`, brief `addendum.md:16`, `capture-and-transport.md:3`).
- Range drift: `SPEC.md:48` + brief `addendum.md:16` + `capture-and-transport.md:3` ("the 12.2+ spelling, fitting the 16.x–17.x range") vs `ARCHITECTURE-SPINE.md:179` ("12.2+ through 19.x").
- Suggested fix: accept ARCH as owner of build detail, but (1) reconcile to one supported range (widest verified "12.2+ through 19.x", or tested "16.x–17.x" with forward-compat explicitly unverified); (2) add a SPEC Constraints pointer ("POC placement, source tree, tool versions, and variable registry per ARCH") so SPEC's "complete contract" claim holds by reference.

## F12 — Minor wording drifts (same intent, different words) [low]

- Restore demo: `prd.md:104-105` "demonstrated once" vs `brief.md:36` + `SPEC.md:66` "at least once".
- Scope-Out enumeration: `prd.md:35-39` and `SPEC.md:57-62` list live-copies, inner hashes, parent changes, NAS provisioning as out; `brief.md:43` Out omits all four (parent contract + NAS provisioning surface instead at `brief.md:49,53`).
- Runner completeness: `brief.md:49` + `SPEC.md:53` "blob + hash present and the hash matching" and `brief.md:35` "the hash is re-verified, not just checked for presence" vs `prd.md:113-114` "completeness over blob + hash" (presence vs re-verify unstated).
- "Nothing else" overclaim: `prd.md:14-15` "Two guarantees, nothing else: confidentiality ... and integrity" vs `prd.md:30-33` In list + FR-7..FR-11 (ship, re-verify, retain, fail loudly, config) — the PRD itself requires more than two things.
- Key form: `ARCHITECTURE-SPINE.md:102` "arrives out-of-band (env var or file path)" + registry `AGE_PUBKEY_FILE` (path) vs all other docs' unqualified "supplied out-of-band"; sits uneasily with `ARCHITECTURE-SPINE.md:128` "holds no secrets (key paths, never key material)" + `:130` "Secrets never travel via `argv`".
- Tarball naming: "frozen tarball" (`prd.md:49-50`) vs "native tarball" (SPEC/brief) vs "Content tarball" (brief `addendum.md:9`, `backup-contents.md:7`) — one referent, three names.
- Disk sizing: brief `addendum.md:26` "Disk ≈ one-set size × sets kept" vs `retention-policy.md:6` "Disk need ≈ one-set size × sets kept" (same formula).
- Ship purpose: `brief.md:24` "ships blob + hash to the NAS via rsync as one timestamped unit for retention and deletion" — retention/deletion are local PRUNE effects, not ship purposes.
- Suggested fix: normalize to one phrasing each: "at least once"; brief Out mirrors SPEC Non-goals; PRD completeness becomes "both files present, hash re-verified"; PRD Goal becomes "Two guarantees anchor the design..."; key form becomes file-path-only via `AGE_PUBKEY_FILE`/`SSH_KEY_FILE`; tarball becomes "native tarball"; disk becomes "Disk need ≈ ..."; ship sentence becomes "as one timestamped unit; retention and deletion are likewise unit-wise".

## Stale-reference sweep (old-design patterns hunted)

- "3 separately-handled artifacts / encrypt-each / 3 blobs": only live hit is PRD `addendum.md:7-11` "Option 2 (encrypt-each, 3 blobs + 3-line hash file). Rejected: ..." — explicitly labeled rejected, not stale. No live per-artifact handling remains; `prd.md:106-107` counter-metric actively rejects it.
- "4 set members": no live occurrence. Brief `addendum.md:7-12` 4-row table describes pre-seal inputs (3 pieces + Logs-skip), not set members — correct. Only display confusion is F6.
- "Per-file config pick-list": none live — all docs say whole-volume copy; `prd.md:53` "The volume is the unit; no file pick-list." holds.
- "Plural / inner / per-artifact hashes": no live requirement — all docs say one hash, no inner (`prd.md:67-70`, `brief.md:24`, brief `addendum.md:17`, `SPEC.md:33,60`, `backup-contents.md:11`, `ARCHITECTURE-SPINE.md:103`). Double-hashing appears only as rejected (PRD `addendum.md:12-15`). Note `SHA256SUMS` is a conventional plural filename holding one line — see F9.
- "Retention 2–3 sets": LIVE STALE in two files — see F1.
- Review file's own path excluded from the hunt per instructions.
