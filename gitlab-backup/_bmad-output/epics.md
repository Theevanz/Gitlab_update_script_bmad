---
stepsCompleted: ["step-01-validate-prerequisites", "step-02-design-epics", "step-03-create-stories", "step-04-final-validation"]
inputDocuments:
  - ../_bmad-output/planning-artifacts/prds/prd-gitlab-backup-2026-11-03/prd.md
  - ../_bmad-output/planning-artifacts/prds/prd-gitlab-backup-2026-11-03/addendum.md
  - _bmad-output/specs/spec-gitlab-backup/SPEC.md
  - _bmad-output/specs/spec-gitlab-backup/backup-contents.md
  - _bmad-output/specs/spec-gitlab-backup/capture-and-transport.md
  - _bmad-output/specs/spec-gitlab-backup/retention-policy.md
  - ../_bmad-output/planning-artifacts/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md
  - ../_bmad-output/planning-artifacts/briefs/brief-gitlab-backup-2026-11-03/brief.md
  - ../_bmad-output/planning-artifacts/briefs/brief-gitlab-backup-2026-11-03/addendum.md
---

# gitlab-backup - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for gitlab-backup, decomposing the requirements from the PRD, UX Design if it exists, and Architecture requirements into implementable stories.

## Requirements Inventory

### Functional Requirements

FR-1: The run captures live GitLab data (database, repositories, uploads, CI data) via native `gitlab-backup create STRATEGY=copy` into a native tarball. The live data volume is never copied — the tarball is the only data capture.

FR-2: The run copies the whole config volume that is mounted to the docker container (host-side bind path supplied via config — holds `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys) for sealing. The volume is the unit; no file pick-list.

FR-3: The sealed set carries the compose file and `.env` byte-identical to source (the pinned-version recipe).

FR-4: The run tars tarball + config volume + compose file + `.env` into one set archive and seals it with exactly one `age` invocation to the out-of-band NAS public key, then wipes the plaintexts.

FR-5: No plaintext (data or secrets) leaves the GitLab host; the NAS private key never exists on the host.

FR-6: The run writes one SHA-256 over the sealed blob (`sha256sum -c` format) after encryption. No inner hashes — the blob hash transitively covers the sealed contents, and `age` refuses tampered ciphertext.

FR-7: The run ships blob + hash to the NAS over rsync/SSH key auth as one unit; a ship delivering only one of the two files is a failure per FR-10, with the partial remote file removed.

FR-8: The run re-verifies the hash on the NAS before reporting success.

FR-9: After a verified ship, the newest 2 local sets remain (dirname order); losers are deleted whole, never piecemeal; prune never runs unless the current set shipped and verified.

FR-10: Any step failure exits non-zero naming the step and leaves no partial set behind, local or remote.

FR-11: Single invocation, scheduler-agnostic (identical by hand or cron); environment-supplied config, validated up front.

### NonFunctional Requirements

NFR-1 (explainability): bash-only, no Python; one named function per stage; every tool call commented.

NFR-2 (boundaries): no scheduler logic, no retry logic duplicating tool flags, no NAS-side logic, no consumer-specific checks (freshness and fitness are judged by consumers).

NFR-3 (portable): on-prem across two servers; static binaries vendored where needed for air-gap vetting.

### Additional Requirements

- Pipeline is exactly `CONFIG + LOCK` pre-pipe gates then `CAPTURE → BUNDLE → ENCRYPT → HASH → SHIP → PRUNE` in order; a stage reads only prior stages' artifacts plus its declared source inputs, never re-runs a prior stage (AD-1).
- Run preamble computes `<ts>` once (UTC `YYYYMMDD-HHMMSS`) and creates empty `.staging-<ts>/`; abort if it or `<ts>/` already exists; `<ts>` reused for staging, publish, and remote paths (AD-1/AD-2).
- CAPTURE writes exactly one native tarball (the file its own `create` produced, never newest-wins) via `docker exec` `gitlab-backup create STRATEGY=copy`, read from host-visible `$GITLAB_DATA_DIR/backups/` (AD-1).
- BUNDLE requires exactly one `*_gitlab_backup.tar` in staging; stages copies of config volume (as `config/`), compose file (source basename), and `.env` from the compose file's directory (missing file fails `FAIL:BUNDLE`); `cmp`s each copy byte-identical or `FAIL:BUNDLE`; tars exactly `{<native-tarball>, config/, <compose-basename>, .env}` with relative members via plain `tar -cf` (no compression, defaults, no absolute paths) into `set.tar` (AD-1).
- ENCRYPT seals `set.tar` → `set.tar.age` with exactly one `age` invocation and deletes exactly {native tarball, staged `config/`, staged compose copy, staged `.env`, `set.tar`}; `rm` checked — any failure is `FAIL:ENCRYPT` (AD-1/AD-3).
- HASH runs only on the sealed blob; the publish `mv` belongs to HASH; SHIP reads only from published `<ts>/`, never staging (AD-1).
- Publish gate: staging holds exactly two entries named exactly `set.tar.age` and `SHA256SUMS` AND `sha256sum -c SHA256SUMS` passes inside staging; any third entry or verify failure aborts with `FAIL:HASH`, never publishes; publish is one atomic `mv .staging-<ts> <ts>`, never per-file moves; published sets never renamed/touched (AD-2).
- ERR trap + EXIT-when-nonzero removes local and remote staging (only staging each side, never published sets, including on PRUNE failure); remote cleanup runs `|| true`, never masks original FAIL (AD-2).
- One domain tool per stage (`gitlab-backup` via `docker exec`, `tar`, `age`, `sha256sum`, `rsync`/`ssh`, `rm`); closed utility set only (`mv`, `rm`, `mkdir`, `cmp`, `flock`, `test`); bash does sequencing, arg validation, error naming only (AD-3).
- Encryption invocation is `age -R "$AGE_PUBKEY_FILE" -o set.tar.age set.tar` (binary, no armor), cwd inside staging; key file holds a single `age1…` line or `FAIL:CONFIG` up front; public key arrives out-of-band as file path, never hardcoded (AD-4).
- `SHA256SUMS` is exactly one line — 64 lowercase hex, two spaces, `set.tar.age`, trailing newline — generated with cwd inside the set dir on the bare filename; passes `sha256sum -c` unmodified in local staging, local published, and remote staging; written once by HASH, SHIP only reads/verifies (AD-5).
- SHIP: re-run `sha256sum -c` locally first; contents-mirror `rsync -a -e "ssh -i $SSH_KEY_FILE" "$BACKUP_DIR/<ts>/" "$NAS_USER@$NAS_HOST:$NAS_DIR/.staging-<ts>/"` (trailing slashes); over ssh: presence check (`test -f` both members, else `FAIL:SHIP:missing-member`) then `(cd <NAS_DIR>/.staging-<ts> && sha256sum -c SHA256SUMS)` (else `FAIL:SHIP:hash-mismatch`); only then remote rename to `<NAS_DIR>/<ts>/`, aborting if it exists; all remote paths absolute (AD-5).
- Config precedence real env > `backup.env` file > built-in defaults; script sources `$SCRIPT_DIR/backup.env` when present (`ENV_FILE` overrides path); tracked `backup.env.example` documents every variable with POC default; real file gitignored, holds key paths never key material (AD-6).
- Up-front validation with `FAIL:CONFIG` before any capture: required vars non-empty; files exist/readable; `BACKUP_DIR` writable; key file single `age1…` line; container + compose present (`docker inspect`, read-only); no network probes (unreachable NAS = `FAIL:SHIP`); secrets never via argv (AD-6).
- Canonical variable registry (13): `BACKUP_DIR NAS_HOST NAS_USER NAS_DIR SSH_KEY_FILE AGE_PUBKEY_FILE GITLAB_CONTAINER GITLAB_CONFIG_DIR GITLAB_DATA_DIR COMPOSE_FILE AGE_BIN VERBOSE ENV_FILE`; `GITLAB_CONFIG_DIR` defaults to `$(dirname "$COMPOSE_FILE")/volumes/config`, `GITLAB_DATA_DIR` to `$(dirname "$COMPOSE_FILE")/volumes/data`, `AGE_BIN` to `$SCRIPT_DIR/vendor/age`; new variables enter with default + comment in the same epic (AD-6).
- `set -euo pipefail`; order: resolve + validate config → compute `<ts>` → acquire lock → `mkdir` staging; single-flight via `flock` on `<backups>/.lock`; contention emits exactly one `FAIL:LOCK:ts=-:<detail>` to stderr, exit 1, no START/DONE, no stdout (AD-7).
- Fixed output grammar, stage vocabulary `CONFIG CAPTURE BUNDLE ENCRYPT HASH SHIP PRUNE LOCK`: `START <STAGE> ts=<ts>` and `DONE <STAGE> ts=<ts> [detail]` to stdout (grammar only); `FAIL:<STAGE>:ts=<ts>:<detail>` (detail required) to stderr, exit 1; `ts=-` only when dying before `<ts>` assignment; tool output to stderr when `VERBOSE=1`, else `/dev/null`; v1 exits 1 for all failures (AD-7).
- PRUNE keeps newest 2 set dirs in local `<backups>/` only (never touches NAS), by dirname sort never mtime; only entries matching `^[0-9]{8}-[0-9]{6}$` participate (`.staging-*`, `.lock` never victims); `rm -rf` whole losers only; runs only if SHIP exited 0 this run; count fixed at 2, no retention variable in v1 (AD-8).
- Naming/terminology: set dir `<backups>/<ts>/`; sealed blob `set.tar.age`; `manifest` is banned (bundle/seal synonyms per spine) (Consistency).
- Stage functions `capture bundle encrypt hash ship prune` (lowercase, `<ts>` as `$1`, exit code + FAIL lines only); every external tool overridable without editing the script (`age` via `$AGE_BIN`, container/ssh tools via PATH) (Consistency).
- Explainability: one named function per stage; every tool invocation preceded by intent comment; no `eval`, dynamic dispatch, or cryptic one-liners (Consistency).
- Stack: bash ≥5.0 (prefer 5.3); `age` 1.3.x vendored static binary (1.3.2); rsync ≥3.5.1 both ends; OpenSSH ≥9.x key auth Ed25519; sha256sum system; BATS ≥1.13 for tests.
- Source tree: `backup/gitlab-backup.sh`, `backup/backup.env.example`, `vendor/age`, `tests/*.bats` (per-stage + induced-failure tests).
- Local sets land in `backups/` alongside the compose file under `test-gitlab-server/` (testing/POC placement).
- Spec CAP-1..CAP-7 trace to FR-1..FR-11 (CAP-1→FR-1, CAP-2→FR-2/FR-4/FR-5, CAP-3→FR-3, CAP-4→FR-6, CAP-5→FR-7/FR-8, CAP-6→FR-9, CAP-7→FR-10/FR-11); verification contract v2 (presence then hash, ≤24h freshness) is a parent-deliverable dependency, not this build.
- No starter template specified in Architecture — Epic 1 Story 1 scaffolds the repo/tree from the spine's Structural Seed (script + env example + vendored age + BATS skeleton), not from a template repo.

### UX Design Requirements

None — no UX design document exists for this CLI-only project (no UI, no DESIGN.md/EXPERIENCE.md spine). No UX-DRs extracted.

### FR Coverage Map

FR-1: Epic 2 - Native tarball capture via STRATEGY=copy; live data volume never copied
FR-2: Epic 2 - Whole config volume copied as the unit for sealing
FR-3: Epic 2 - Compose file + .env carried byte-identical in the set
FR-4: Epic 2 - Tarball + config + compose + env tared into one archive, sealed with exactly one age invocation, plaintexts wiped
FR-5: Epic 2 - No plaintext leaves the host; NAS private key never on host
FR-6: Epic 2 - One SHA-256 over the sealed blob, sha256sum -c format, after encryption
FR-7: Epic 3 - Blob + hash shipped to NAS over rsync/SSH as one unit; partial ship removed
FR-8: Epic 3 - Hash re-verified on the NAS before success
FR-9: Epic 3 - Newest 2 local sets remain (dirname order), deleted whole; prune only after verified ship
FR-10: Epic 1 (failure framework: grammar, traps, exit 1) — extended per-stage in Epics 2-3
FR-11: Epic 1 - Single invocation, scheduler-agnostic, config validated up front

## Epic List

Pipeline coverage:

```text
CONFIG + single-run guard (pre-pipe gates) → CAPTURE → BUNDLE → ENCRYPT → HASH → SHIP → PRUNE
|________________ Epic 1 ________________| |_________ Epic 2 _________| |___ Epic 3 ___|
```

(Epic 1 also provides the run skeleton — output grammar, hidden build folder, traps — that all six steps run inside.)

### Epic 1: Script Runs, Checks Its Inputs, and Fails Loudly

Operator runs one command (`backup/gitlab-backup.sh`), by hand or under cron — identical either way:

- **Input check first:** simple "if this file's not here, fail" — every required file must exist and be readable, every required value non-empty, before anything else runs. Fails in ~1 second with e.g. `FAIL:CONFIG:ts=-:missing AGE_PUBKEY_FILE`.
- **Single-run guard:** `flock` on `backups/.lock` so two runs never overlap; a colliding run exits immediately with `FAIL:LOCK`. Kernel-held: releases automatically on process exit, success or failure — no lock cleanup needed, and the `.lock` file itself is never deleted.
- **One progress line per step:** each pipeline step prints `START <STEP> ts=<ts>` on begin and `DONE <STEP> ts=<ts>` on end. Any failure prints one `FAIL:<STEP>:ts=<ts>:<reason>` line to stderr and exits 1.
- **Hidden build folder, atomic publish:** intermediates go into `.staging-<ts>/`, invisible to set listings. The finished set appears as `<ts>/` via a single atomic rename, only when complete. A failed run's build folder is deleted automatically.

**FRs covered:** FR-10, FR-11

### Epic 2: Complete Sealed Set, Built and Verified Locally

Operator gets a complete timestamped set directory locally — one encrypted blob plus one matching hash — published atomically and verifiable with `sha256sum -c`.

**FRs covered:** FR-1, FR-2, FR-3, FR-4, FR-5, FR-6

### Epic 3: Shipped, Re-verified, and Pruned as One Unit

The set lands on the NAS as one unit and is re-verified post-trip. If ship or re-verify fails, nothing is pruned — local history stays untouched. Only after a verified ship does local history collapse to newest-2, deleted whole, never piecemeal.

**FRs covered:** FR-7, FR-8, FR-9

## Epic 1: Script Runs, Checks Its Inputs, and Fails Loudly

Operator runs one command (`backup/gitlab-backup.sh`), by hand or under cron — identical either way. Input check first ("if this file's not here, fail"), single-run guard, one `START`/`DONE` line per step with `FAIL:<STEP>` on errors, hidden build folder with automatic cleanup.

**FRs covered:** FR-10, FR-11

### Story 1.1: Runnable script skeleton with resolved config

As an operator,
I want to run one command that resolves its configuration and reports progress in fixed lines,
So that every backup step has a working foundation to run inside.

**Acceptance Criteria:**

**Given** a fresh checkout
**When** I list the repo tree
**Then** `backup/gitlab-backup.sh`, `backup/backup.env.example` (all 13 registry vars, each with POC default + comment), `vendor/` (age 1.3.2 pin + publisher's published SHA-256 recorded in `vendor/age.SHA256`; binary itself lands in Story 2.3 when first used), and the BATS skeleton exist

**Given** no `backup.env` and no env overrides on the POC box
**When** I run the script
**Then** it exits 0 and stdout carries only `START CONFIG ts=<ts>` / `DONE CONFIG ts=<ts> ...` lines — grammar only, no tool chatter

**Given** conflicting values across real env, env file, and defaults
**When** I run the script
**Then** real env wins over the file and the file wins over defaults, observable via the resolved `BACKUP_DIR` in the `DONE CONFIG` detail line, with a BATS test per precedence layer

**Given** default vs `VERBOSE=1` runs
**When** tools emit output
**Then** it goes to `/dev/null` by default and to stderr under `VERBOSE=1`; stdout stays grammar-only in both

**Given** BATS installed
**When** I run the suite
**Then** skeleton tests pass: grammar-line format, precedence matrix, stdout-purity (tool output never on stdout), VERBOSE gating

### Story 1.2: Fail-fast input checks

As an operator,
I want the script to reject bad inputs in ~1 second before touching any GitLab data,
So that a typo fails fast instead of dying halfway through a 50 GB capture.

**Acceptance Criteria:**

**Given** a required file missing or unreadable (e.g. `AGE_PUBKEY_FILE` points at nothing)
**When** I run the script
**Then** it exits 1 within ~1 second, stderr shows `FAIL:CONFIG:ts=-:...` naming the input, stdout is empty, and nothing is created

**Given** an age key file holding anything other than exactly one `age1…` line (empty, two lines, wrong prefix)
**When** I run the script
**Then** it exits 1 with `FAIL:CONFIG` naming the key file

**Given** an unwritable `BACKUP_DIR`, or `docker inspect` failing on the container name
**When** I run the script
**Then** it exits 1 with `FAIL:CONFIG` naming the problem — no network probes, unreachable NAS is not a CONFIG failure

### Story 1.3: Single-run guard and build-folder lifecycle

As an operator,
I want overlapping runs refused and every run's build folder created and cleaned automatically,
So that failures are loud, fast, and never leave a half-built set behind.

**Acceptance Criteria:**

**Given** a first run holding the guard on `backups/.lock`
**When** a second run starts
**Then** it exits 1 with exactly one `FAIL:LOCK:ts=-:...` line on stderr, no stdout, no `START` line

**Given** validation passed
**When** the run proceeds
**Then** one `<ts>` (UTC `YYYYMMDD-HHMMSS`) is computed and reused everywhere, empty `.staging-<ts>/` is created, and a pre-existing `.staging-<ts>/` or `<ts>/` aborts the run

**Given** any failure after the build folder exists (induced in test)
**When** the run exits non-zero
**Then** `.staging-<ts>/` is removed automatically, no `<ts>/` dir or partial file remains, and the guard is released so the next run starts immediately

**Given** any `FAIL` line emitted by the script
**When** an operator reads the detail field
**Then** it states the cause in plain words (e.g. `missing AGE_PUBKEY_FILE`, `another run holds backups/.lock`), never a bare code — BATS asserts every `FAIL` detail in the suite matches a human-readable pattern

## Epic 2: Complete Sealed Set, Built and Verified Locally

Operator gets a complete timestamped set directory locally — one encrypted blob plus one matching hash — published atomically and verifiable with `sha256sum -c`. Covers `CAPTURE → BUNDLE → ENCRYPT → HASH`, one story per step.

**FRs covered:** FR-1, FR-2, FR-3, FR-4, FR-5, FR-6

### Story 2.1: Capture live data into a native tarball

As an operator,
I want the run to capture live GitLab data into exactly one native tarball inside the hidden build folder,
So that the frozen data is ready for sealing and the live volume is never touched.

**Acceptance Criteria:**

**Given** a healthy container and data bind
**When** CAPTURE runs
**Then** exactly one `*_gitlab_backup.tar` lands in `.staging-<ts>/`, produced by this run's own `docker exec` `gitlab-backup create STRATEGY=copy`, and `START`/`DONE CAPTURE ts=<ts>` lines are emitted

**Given** the capture tool fails or no tarball appears
**When** CAPTURE runs
**Then** it exits 1 with `FAIL:CAPTURE:ts=<ts>:...`, the build folder is removed automatically, and nothing is published

**Given** a stale tarball from an earlier run sitting in the data bind dir
**When** CAPTURE runs
**Then** only the file its own `create` produced is used — never newest-wins — and the build folder holds exactly one file afterward

**Given** CAPTURE completed
**When** the live data directory is inspected
**Then** it is otherwise untouched: no wholesale copy, the single tarball is the only thing read out of it (FR-1)

### Story 2.2: Assemble tarball, config, and recipe into one set archive

As an operator,
I want the run to bundle the tarball, the whole config volume, the compose file, and `.env` into one set archive with byte-identical copies,
So that everything a restore needs sits in a single file.

**Acceptance Criteria:**

**Given** a build folder with exactly one tarball and valid sources
**When** BUNDLE runs
**Then** staged copies (`config/`, compose basename, `.env`) each `cmp` byte-identical to source, and `set.tar` holds exactly `{<tarball>, config/, <compose-basename>, .env}` with relative members via plain `tar -cf` (no compression), with `START`/`DONE BUNDLE` emitted

**Given** zero or two-or-more tarballs in the build folder
**When** BUNDLE runs
**Then** it exits 1 with `FAIL:BUNDLE` and nothing is published

**Given** `.env` missing beside the compose file
**When** BUNDLE runs
**Then** it exits 1 with `FAIL:BUNDLE` naming the missing `.env`

**Given** a staged copy that differs from its source (induced `cmp` mismatch)
**When** BUNDLE runs
**Then** it exits 1 with `FAIL:BUNDLE` naming the mismatched copy

**Given** a produced `set.tar`
**When** its member listing is inspected
**Then** members are relative paths only (no absolute paths, no extra members), asserted byte-exact by BATS

### Story 2.3: Seal the set with one age invocation and wipe plaintexts

As an operator,
I want the set archive sealed to the NAS public key with every plaintext wiped,
So that no secret ever leaves the host unencrypted.

**Acceptance Criteria:**

**Given** `set.tar` plus staged plaintexts in the build folder
**When** ENCRYPT runs
**Then** exactly one `age` invocation (binary, no armor, `-R` key file, cwd inside the build folder) produces `set.tar.age` using the vendored binary at `$AGE_BIN` (age 1.3.2, verified at vendor time against the publisher's published SHA-256 recorded in `vendor/age.SHA256`), with `START`/`DONE ENCRYPT` emitted

**Given** `age` exited 0
**When** the wipe runs
**Then** exactly {native tarball, staged `config/`, staged compose copy, staged `.env`, `set.tar`} are removed with every `rm` checked, leaving only `set.tar.age` in the build folder

**Given** `age` exits non-zero
**When** ENCRYPT runs
**Then** it exits 1 with `FAIL:ENCRYPT`, plaintexts stay inside the build folder for automatic trap removal, and nothing is published

**Given** any `rm` failure during the wipe (induced)
**When** ENCRYPT runs
**Then** it exits 1 with `FAIL:ENCRYPT`

**Given** the ENCRYPT stage under test with a counting `age` shim on PATH
**When** the stage completes
**Then** the shim records exactly one invocation — no fallback cipher, no second call (FR-4, FR-5)

**Given** the finished repo and script
**When** the key-hygiene test scans them
**Then** no private-key material and no private-key path exists anywhere in the repo, and the script references only `AGE_PUBKEY_FILE` — the host-side half of FR-5 ("private key never on the host") is recorded as an operator responsibility in the Story 3.4 runbook, not asserted by test

### Story 2.4: Hash the sealed blob and publish atomically

As an operator,
I want one hash written over the sealed blob and the set published by atomic rename only when complete and verified,
So that anything listing sets sees a complete set or nothing.

**Acceptance Criteria:**

**Given** a build folder holding only `set.tar.age`
**When** HASH runs
**Then** `SHA256SUMS` is written (exactly one line: 64 lowercase hex, two spaces, `set.tar.age`, trailing newline; cwd inside the build folder), `sha256sum -c` passes inside the build folder, and one atomic `mv .staging-<ts> <ts>` publishes the set, with `START`/`DONE HASH` emitted

**Given** a third entry in the build folder at the gate (planted leftover plaintext)
**When** HASH runs
**Then** it exits 1 with `FAIL:HASH`, nothing is published, and the trap removes the build folder

**Given** a `SHA256SUMS` that fails self-verification (induced corruption)
**When** HASH runs
**Then** it exits 1 with `FAIL:HASH` and nothing is published

**Given** a published set
**When** it is inspected
**Then** `<ts>/` holds exactly `set.tar.age` + `SHA256SUMS`, `sha256sum -c` passes from the published dir unmodified, and no `.bak` files exist nor were older sets renamed or touched

## Epic 3: Shipped, Re-verified, and Pruned as One Unit

The set lands on the NAS as one unit and is re-verified post-trip. If ship or re-verify fails, nothing is pruned — local history stays untouched. Only after a verified ship does local history collapse to newest-2, deleted whole, never piecemeal. Covers `SHIP → PRUNE`, plus automated proof (3.3) and a demonstrated restore with runbook (3.4).

**FRs covered:** FR-7, FR-8, FR-9

### Story 3.1: Ship the set to the NAS and re-verify before success

As an operator,
I want blob + hash shipped to the NAS as one unit and re-verified there before success is reported,
So that the off-host copy is proven intact.

**Acceptance Criteria:**

**Given** a published local set and a reachable NAS (BATS uses a real SSH test endpoint, never a mocked rsync)
**When** SHIP runs
**Then** it re-runs `sha256sum -c` locally first, mirrors contents via `rsync` (trailing slashes) into `.staging-<ts>/` on the NAS, passes the remote presence check (both members) and remote `sha256sum -c`, then renames remotely to `<ts>/`, with `START`/`DONE SHIP` emitted — and the NAS `<ts>/` holds both files verifying

**Given** the local re-verify fails (induced)
**When** SHIP runs
**Then** it exits 1 with `FAIL:SHIP` and nothing is sent

**Given** one member missing on the remote side (induced)
**When** the remote presence check runs
**Then** it exits 1 with `FAIL:SHIP:missing-member` and the remote build folder is removed

**Given** a flipped byte on the remote side (induced)
**When** the remote hash check runs
**Then** it exits 1 with `FAIL:SHIP:hash-mismatch`, no remote `<ts>/` is created, and the remote build folder is removed

**Given** a remote `<ts>/` that already exists
**When** SHIP runs
**Then** it aborts with `FAIL:SHIP` before the remote rename — the remote move never runs onto an existing path

**Given** any SHIP failure
**When** the run exits
**Then** no partial remote set remains (remote build folder removed, original `FAIL` preserved) and the local published set is untouched (FR-7, FR-8)

### Story 3.2: Keep newest-2 local sets, whole units only

As an operator,
I want local history collapsed to the newest 2 sets after each verified ship,
So that disk stays bounded and restores stay fast without manual pruning.

**Acceptance Criteria:**

**Given** 3+ published local sets and SHIP exited 0 this run
**When** PRUNE runs
**Then** the newest 2 by dirname sort remain, losers are `rm -rf`'d whole, and `.staging-*`, `.lock`, and non-`YYYYMMDD-HHMMSS` names are never victims, with `START`/`DONE PRUNE` emitted

**Given** SHIP did not exit 0 this run (induced ship failure)
**When** the run ends
**Then** PRUNE never runs — every pre-existing local set is still present, untouched

**Given** only 2 (or fewer) local sets
**When** PRUNE runs
**Then** nothing is deleted, it exits 0 with `DONE PRUNE`

**Given** an oldest-dirname set with the newest mtime (planted disagreement)
**When** PRUNE runs
**Then** dirname sort wins and mtime is ignored

**Given** PRUNE completed
**When** the NAS is inspected
**Then** remote sets are unchanged — PRUNE never touches the NAS (FR-9)

### Story 3.3: Prove the full run and every failure mode automatically

As an operator,
I want a full run plus an induced failure at every stage proven by automated test,
So that the complete pipeline and its loud-failure promise are verified without manual effort.

**Acceptance Criteria:**

**Given** the test GitLab instance and test NAS
**When** a full run executes
**Then** blob + matching hash exist locally and on the NAS, local history is newest-2, exit is 0, and the full `START`/`DONE` line sequence is present (SM-1)

**Given** induced failures at each stage (capture, bundle, encrypt, hash, ship, prune) plus config-validation and lock-contention cases
**When** each is run
**Then** each exits non-zero naming its stage with nothing partial left behind, local or remote (SM-2 sweep in BATS)

### Story 3.4: Demonstrate the restore and ship the runbook

As an operator,
I want a demonstrated manual restore plus a checked-in runbook covering restore and operator responsibilities,
So that the upgrade runner's rollback path is proven real, not theoretical.

(This story is operator-executed; the dev agent authors the procedure, the operator performs the demo.)

**Acceptance Criteria:**

**Given** a produced set and the checked-in procedure at `docs/restore.md`
**When** the operator follows it against the test instance
**Then** GitLab is restored at least once (pinned version recovered from the set's compose recipe), proving a set is restore-capable (SM-3)

**Given** the finished runbook
**When** it is reviewed
**Then** it documents the restore procedure plus operator responsibilities: NAS private key lives only on the NAS (host-side half of FR-5), NAS VM provisioning, scheduler setup, and retention-horizon enforcement — all explicitly out of the script's scope

**Given** the finished implementation
**When** it is reviewed against the counter-metric
**Then** no per-artifact hashes, sidecars, or per-file logic exist after the seal (CM-1) — one blob, one hash, set-as-unit throughout
