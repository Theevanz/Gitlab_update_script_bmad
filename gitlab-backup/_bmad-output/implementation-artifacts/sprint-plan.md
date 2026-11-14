# Sprint Plan — gitlab-backup

- Generated: 11-04-2026 14:29
- Project: gitlab-backup
- Readiness gate: **PASS**
- Epic source: `_bmad-output/epics.md`
- Tracking file: `_bmad-output/implementation-artifacts/sprint-status.yaml` (validated: format OK)
- Skill source: parent folder `.agents/skills/bmad-sprint-planning` (this folder has no `_bmad/` install; the deterministic script was run from the parent skill against this folder's artifacts)

## Intent and motivation

The stepwise GitLab upgrade runner refuses to migrate without a fresh, valid
backup — today that backup is hand-made for the demo, and the `--nobackup`
escape hatch means "no rollback path." There is no producer: nothing that
reliably captures the database, repositories, uploads, CI data, and the
config/secrets a restore actually needs, verifies the set survived the trip to
backup storage, and keeps enough history that a late-noticed mistake is still
recoverable. Worse, a bare tarball alone cannot restore a GitLab instance — the
native tool deliberately excludes `gitlab.rb` and `gitlab-secrets.json` — so
any check that passes on "a tarball exists" can bless an unrestorable backup.

This sprint builds one command (`backup/gitlab-backup.sh`) that produces one
timestamped backup set per run — native tarball (frozen via `STRATEGY=copy`) +
whole config volume + compose file + `.env`, bundled into one archive, sealed
once with `age`, plus one SHA-256 over the sealed blob — keeps the latest 2
sets locally, and ships blob + hash to the on-prem NAS over rsync as one unit.
A run either yields a complete set or exits non-zero naming what failed.

The forcing function is a learning mandate: the mentor grades coding detail,
so explainability outranks feature count — bash-only, one named function per
stage, every tool call commented.

Sources: `brief.md` (Executive Summary, Problem, Solution),
`SPEC.md` (Why, Success signal).

## Context and contract

**Capabilities (from `SPEC.md`):**

- CAP-1: live GitLab data captured into a native tarball from a frozen copy, single invocation
- CAP-2: whole config volume + compose recipe sealed in, recoverable by decrypting with the NAS private key
- CAP-3: compose file + `.env` byte-identical to source inside the sealed set
- CAP-4: one SHA-256 over the sealed blob, recompute-and-compare passes locally and on the NAS
- CAP-5: blob + hash shipped to the NAS as one unit with post-trip re-verification
- CAP-6: latest 2 set directories remain locally, never piecemeal, only after a verified ship
- CAP-7: any induced step failure exits non-zero naming the stage with no partial set left behind

**Architecture (from `ARCHITECTURE-SPINE.md`, AD-1–AD-8):**

Pipes-and-filters, six linear stages, one direction, no loops:

`CONFIG + LOCK` (pre-pipe gates) → `CAPTURE → BUNDLE → ENCRYPT → HASH → SHIP → PRUNE`

Key decisions: staged fail-fast pipeline with `<ts>` computed once and an
empty `.staging-<ts>/` preamble (AD-1); set-as-unit atomicity — exactly
`set.tar.age` + `SHA256SUMS` at the gate, `sha256sum -c` must pass, one atomic
`mv .staging-<ts> <ts>`, trap removes only staging each side (AD-2); bash
sequences while one domain tool per stage executes, closed utility set only,
no Python (AD-3); plaintext secrets never leave the host — one `age -R`
invocation, private key never on host (AD-4); emit a complete set and judge
nothing — exact-bytes `SHA256SUMS`, contents-mirror rsync, presence-then-hash
over ssh, remote rename only (AD-5); environment in via real env >
`backup.env` > defaults with a 13-variable registry and up-front `FAIL:CONFIG`
(AD-6); loud failure with fixed `START`/`DONE`/`FAIL:<STAGE>` grammar, `flock`
single-flight, exit 1 (AD-7); whole-set pruning, newest-2 by dirname sort,
local only (AD-8).

**Structural seed:** `backup/gitlab-backup.sh` + `backup/backup.env.example`
+ `vendor/age` + `tests/*.bats`. Local sets land in `backups/` alongside the
compose file under `test-gitlab-server/` (POC placement).
**Stack:** bash ≥5.0 + `gitlab-backup create STRATEGY=copy` via `docker exec`
+ vendored `age` 1.3.2 + rsync ≥3.5.1 both ends + OpenSSH ≥9.x (Ed25519 key
auth) + system `sha256sum` + BATS ≥1.13; no Python.

**Out of scope (must not generate work):** scheduling; automated restore
(stays manual/documented, proven once in Story 3.4); retention-horizon
enforcement and off-site copies (declared policy, enforced elsewhere); log
backup; inner/per-artifact hashes; live data-volume copies; parent-deliverable
changes (`backup-contract.md` v2, runner verification step); NAS VM
provisioning.

## Readiness gate: PASS

**Inventory scanned:**

- `../_bmad-output/planning-artifacts/briefs/brief-gitlab-backup-2026-11-03/brief.md`, `addendum.md`
- `../_bmad-output/planning-artifacts/prds/prd-gitlab-backup-2026-11-03/prd.md`, `addendum.md`
- `_bmad-output/specs/spec-gitlab-backup/SPEC.md`, `backup-contents.md`, `capture-and-transport.md`, `retention-policy.md`
- `../_bmad-output/planning-artifacts/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md`
- `_bmad-output/epics.md` (FR-1–FR-11, NFR-1–NFR-3, FR coverage map)
- `docs/` (project_knowledge): absent, skipped gracefully — no decisions depend on it
- No UX artifact: correct, bash CLI with no UI and no operator interaction surface

**Checks:**

- Traceability: every FR maps to at least one story per the epics coverage map (FR-1–FR-6 → Epic 2, FR-7–FR-9 → Epic 3, FR-10 → Epic 1 framework extended per-stage, FR-11 → Epic 1); every story traces back to FRs/NFRs/ADs; CAP-1–CAP-7 all bound in the architecture map. No orphan stories, no uncovered FRs.
- Epic shape: 3 epics in pipeline order, each delivers operator value, no forward dependencies; stories are independently completable increments (Epic 1 skeleton runs grammar-only; Story 3.3 is the automated full-run + failure sweep; Story 3.4 is the operator-executed restore demo + runbook).
- Recorded decisions: pipeline order, UTC `<ts>` format, staging→publish gate (exactly-two + self-verify + atomic `mv`), one tool per stage, the exact `age -R` line, exact-bytes `SHA256SUMS`, rsync/ssh lines with trailing slashes and absolute remote paths, config precedence + 13-var registry, output grammar + `flock` order, newest-2 dirname-sort prune — all recorded in the spine AD-1–AD-8 or the spec companions, nothing assumed.
- Conflicts: none blocking. Two settled refinements noted, not resolved silently: (1) PRD addendum rejects encrypt-each and double-hashing, consistent with AD-3/AD-4/AD-5 (one seal, one outer hash); (2) the ≤24h freshness verification contract is a parent-deliverable dependency, not this build — SPEC, PRD, and epics all agree the producer judges nothing.

**Generator warnings (accepted, no rerun needed):** two `unparsed Epic/Story-like heading`
notices for the document title (`# gitlab-backup - Epic Breakdown`) and the
`## Epic List` section header — neither is an epic or story, so the omission is correct.

## Sprint tracking

- Epics: 3 | Stories: 11 | Retrospectives: 3 | Total entries: 17
- Status breakdown: `backlog` 14 (3 epics + 11 stories), `optional` 3 (retrospectives)
- Upgraded from disk: none (no story files on disk yet)
- Dropped orphans / illegal / legacy-mapped: none

### Epic 1: Script Runs, Checks Its Inputs, and Fails Loudly (`epic-1`: backlog)

Operator runs one command by hand or under cron — identical either way.
Foundation epic: input check first, single-run guard, one progress line per
step, hidden build folder with automatic cleanup.

| Story | Key | Status |
|---|---|---|
| 1.1 Runnable script skeleton with resolved config | `1-1-runnable-script-skeleton-with-resolved-config` | backlog |
| 1.2 Fail-fast input checks | `1-2-fail-fast-input-checks` | backlog |
| 1.3 Single-run guard and build-folder lifecycle | `1-3-single-run-guard-and-build-folder-lifecycle` | backlog |
| Retrospective | `epic-1-retrospective` | optional |

### Epic 2: Complete Sealed Set, Built and Verified Locally (`epic-2`: backlog)

Operator gets a complete timestamped set directory locally — one encrypted
blob plus one matching hash — published atomically and verifiable with
`sha256sum -c`. Covers `CAPTURE → BUNDLE → ENCRYPT → HASH`, one story per step.

| Story | Key | Status |
|---|---|---|
| 2.1 Capture live data into a native tarball | `2-1-capture-live-data-into-a-native-tarball` | backlog |
| 2.2 Assemble tarball, config, and recipe into one set archive | `2-2-assemble-tarball-config-and-recipe-into-one-set-archive` | backlog |
| 2.3 Seal the set with one age invocation and wipe plaintexts | `2-3-seal-the-set-with-one-age-invocation-and-wipe-plaintexts` | backlog |
| 2.4 Hash the sealed blob and publish atomically | `2-4-hash-the-sealed-blob-and-publish-atomically` | backlog |
| Retrospective | `epic-2-retrospective` | optional |

### Epic 3: Shipped, Re-verified, and Pruned as One Unit (`epic-3`: backlog)

The set lands on the NAS as one unit and is re-verified post-trip. Only after
a verified ship does local history collapse to newest-2. Covers `SHIP → PRUNE`,
plus automated proof (3.3) and a demonstrated restore with runbook (3.4).

| Story | Key | Status |
|---|---|---|
| 3.1 Ship the set to the NAS and re-verify before success | `3-1-ship-the-set-to-the-nas-and-re-verify-before-success` | backlog |
| 3.2 Keep newest-2 local sets, whole units only | `3-2-keep-newest-2-local-sets-whole-units-only` | backlog |
| 3.3 Prove the full run and every failure mode automatically | `3-3-prove-the-full-run-and-every-failure-mode-automatically` | backlog |
| 3.4 Demonstrate the restore and ship the runbook | `3-4-demonstrate-the-restore-and-ship-the-runbook` | backlog |
| Retrospective | `epic-3-retrospective` | optional |

Implementation order is epic order (1 → 2 → 3); within an epic, story-number
order. Story 3.4 is operator-executed (the dev agent authors the procedure,
the operator performs the demo).

## Next steps

1. Review `_bmad-output/implementation-artifacts/sprint-status.yaml` — the
   deterministic source of truth for sprint state.
2. Start implementation with `bmad-build` on Story 1.1 (skeleton + resolved
   config); epics transition to `in-progress` automatically when their first
   story starts.
3. Rerun sprint planning anytime epics change to refresh tracking —
   advanced statuses are preserved, never downgraded.
