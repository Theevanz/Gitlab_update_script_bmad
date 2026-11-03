# Rubric review (r2) — gitlab-backup architecture spine

- **Spine:** `_bmad-output/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md` (2026-11-03, status: draft)
- **Spec:** `_bmad-output/specs/spec-gitlab-backup/SPEC.md` + companions (`backup-contents.md`, `capture-and-transport.md`, `retention-policy.md`)
- **Checklist:** good-spine rubric (divergence points fixed; AD Rules enforceable and preventive; Deferred divergence-free; tech verified-current; spec coverage; every owned dimension decided/deferred/open; re-derivation complete; no inter-AD contradictions)
- **Reviewer role:** spine rubric reviewer. All line numbers refer to the spine unless noted.

## Overall verdict: REQUIRES CHANGES — minor, localized, fix-before-build

The spine is structurally sound: the re-derivation from the 4-member set to the
1-blob+1-hash seal design and from the config file-list to the whole config volume
is substantively complete and consistently reflected; all seven spec capabilities
are covered; the Deferred list is divergence-free; and every named tech version
verified current (checked 2026-11-03, see §4). However, review found **three
contradictions that are directly build-blocking for a literal implementer**
(F1–F3: AD-8 vs AD-6; AD-3 vs the Stack's own capture mechanism; AD-1
self-contradiction on stage inputs) plus **one unfixed divergence point**
(F4: no variable owns the whole-config-volume host path). Each fix is a one- or
two-line edit. F5 and N1–N5 are polish.

---

## Findings

### F1 — AD-8 hardcodes "newest 2" while AD-6 makes retention configurable (contradiction)

AD-8 Rule (L157–160):

> "After a successful ship + remote re-verify, keep the newest 2 set dirs
> by dirname sort (never mtime) and `rm -rf` whole losers only (SPEC CAP-6 settles
> the brief's '2–3' at 2)."

AD-6 registry (L134–138) defines `RETENTION_COUNT` as a resolved variable
(`real env > backup.env > built-in default`, L124–125), and L137 requires new
variables to enter "with default + comment."

If an operator sets `RETENTION_COUNT=3`, the two ADs give opposite orders: AD-8
says keep 2, AD-6 says the resolved value governs. One of them must yield.
**Fix:** AD-8 should read "keep the newest `RETENTION_COUNT` (default 2) set
dirs…" so SPEC's "settles at 2" becomes the default, not a literal.

### F2 — AD-3's "exactly one tool" list omits `docker`, contradicting the Stack's capture mechanism (contradiction + unenforceable Rule)

AD-3 Rule (L86–88):

> "Each external effect goes through exactly one tool: `gitlab-backup`
> (capture), `tar` (bundle), `age` (encrypt), `sha256sum` (hash), `rsync`/`ssh`
> (ship) — one tool per stage, matching AD-1."

But the Stack row (L179) defines capture as
`docker exec -t <container> gitlab-backup create STRATEGY=copy` — `docker` is the
executable the script actually invokes, and it appears nowhere in AD-3's
enumeration. Read literally, AD-3 forbids the Stack's own mandated mechanism.
The enumeration is also short one stage (five mappings for six stages — PRUNE's
`rm` is unmapped) and silent on the filesystem utilities the Rules elsewhere
mandate (`mv` for publish in AD-2 L72, `cmp` for byte-identity in AD-1 L54,
`rm` for wipe in AD-3 L92–93, `flock` in AD-7 L144).

The stated divergence AD-3 prevents — "crypto/checksum/transfer logic drifting
into bash (or vice versa)" (L85) — is the right one, but the Rule overreaches
("exactly one tool" per stage, which no real stage satisfies) while
under-delivering (missing the capture tool itself).
**Fix:** scope the Rule to one *domain* tool per stage, add `docker` to CAPTURE,
map PRUNE → `rm`, and bless a closed set of standard file utilities
(`mv`, `rm`, `mkdir`, `cmp`, `flock`).

### F3 — AD-1 forbids stages reading anything but the set dir, then orders BUNDLE to do exactly that (self-contradiction, unenforceable)

AD-1 Rule (L58–59):

> "A stage reads only artifacts prior stages left in the set dir, never re-runs a prior stage."

Same Rule (L53–54):

> "`BUNDLE` tars the native tarball + whole config volume + compose copy … into `set.tar`"

The config volume and the compose file live at external source paths, not in the
set dir; CAPTURE likewise reads live GitLab, not a prior artifact. BUNDLE cannot
satisfy both sentences simultaneously.
**Fix:** distinguish pipeline artifacts from declared source inputs, e.g. "a
stage reads only prior-stage artifacts in the set dir plus its AD-6-declared
source inputs."

### F4 — The re-derived whole-volume design has no variable for the volume's host path (unfixed divergence point + silent capture handoff)

CAP-2 (SPEC L26) requires copying "the whole config volume (**host-side bind
path** …)". The spine consistently adopted whole-volume language (AD-1 L53,
conventions L168 "whole config volume (`/etc/gitlab` bind)"). But AD-6's
canonical registry (L135–136) —

> "`BACKUP_DIR NAS_HOST NAS_USER NAS_DIR SSH_KEY_FILE AGE_PUBKEY_FILE GITLAB_CONTAINER COMPOSE_FILE RETENTION_COUNT VERBOSE ENV_FILE`"

— names `COMPOSE_FILE` yet no `GITLAB_CONFIG_DIR` (or equivalent) for the
host-side bind path, even though it is environment-specific by definition
(AD-6's own criterion, L123–124). BUNDLE's principal input path is therefore
unowned: two implementers (or test-box vs real host) can diverge with no Rule to
stop them. L138 ("no epic invents a variable that bypasses it") makes the
omission worse, since the variable cannot be added except by amending the
registry.

Adjacent silence: the capture handoff — how the native tarball gets from inside
the container into staging (`docker cp` vs bind-mount vs other) — is decided
nowhere (AD-1, AD-3, and conventions are all silent), and no variable names the
container-side backup path either.
**Fix:** add the config-volume host-path variable (and container tarball-path
variable if `docker cp`) to the AD-6 registry, and state the handoff mechanism
in AD-1/AD-3.

### F5 (minor) — AD-4 allows pubkey via "env var or file path"; AD-6 registers only the file (inconsistency)

AD-4 Rule (L101–102): "The public key arrives out-of-band (**env var or file
path**), never hardcoded." AD-6 registers only `AGE_PUBKEY_FILE` (L136) and
says the file "holds no secrets (key paths, never key material)" (L127–128). A
strict AD-6 implementer cannot build the env-var-material option, and it is
ambiguous whether public-key material in env is even permitted.
**Fix:** pick one supply shape (file path is the registered one) or add an
`AGE_PUBKEY` material variable with its secrecy treatment.

### Nits (non-blocking)

- **N1 — AD-1 "Exactly the stages" vs AD-7's 8-name vocabulary.** AD-1 (L52)
  says "Exactly the stages `CAPTURE → … → PRUNE`", while AD-7's grammar (L146)
  adds `CONFIG` and `LOCK` as stage names. Intent is clear (pre-pipeline gates),
  but "Exactly" reads as forbidding them. One clarifying phrase in AD-1 ("the
  pipe stages"; CONFIG/LOCK are gates) removes the tension.
- **N2 — "manifest" (AD-2 L69).** "or a manifest that doesn't verify" is the
  only use of "manifest" anywhere; the canonical name is `SHA256SUMS`. Rename
  for terminology hygiene (possible residue of the older multi-member design
  language).
- **N3 — Frontmatter `companions: []` (L13).** The Deferred section normatively
  cites `retention-policy.md` (L232–233) and the spec's other companions drove
  content, yet no companion is recorded. List them for traceability.
- **N4 — Internal `set.tar` layout undecided.** AD-1 fixes *what* enters
  `set.tar` (tarball + volume + compose) but not member paths/arrangement inside
  the tar. For a solo single-script build this is a one-implementer micro-choice,
  and restore is explicitly manual/out-of-scope — but the altitude owns "Data &
  formats," so one line fixing it or explicitly deferring it to the builder
  would close the dimension.
- **N5 — AD-2 trap scope vs AD-5.** AD-2 L78–79 says the trap "removes local and
  remote staging (and only staging on each side)." Correct and consistent with
  AD-5's remote-staging discipline; no action — recorded only because trap
  behavior was checked against the "never at risk" claim (L79–80) and holds.

---

## Checklist judgments

### 1. Fixes the real divergence points for the level below; misses none — MOSTLY, one miss

Fixed well: six-stage order and ownership (AD-1, incl. publish-inside-HASH and
SHIP-reads-published-only); atomic publish via single dir-rename both sides
(AD-2/AD-5); tool-vs-bash split (AD-3, modulo F2); seal-before-hash with no inner
hashes (AD-4); emit-everything-judge-nothing producer boundary (AD-5);
env-precedence + registry + fail-fast CONFIG (AD-6); output grammar + flock +
exit-1 (AD-7); whole-dir newest-wins prune gated on verified ship (AD-8);
timestamp-once-and-reuse with collision abort (AD-2 L75–76); UTC naming, staging
names, no-JSON formats (conventions).

Missed: config-volume host-path ownership and capture-handoff mechanism (F4);
`set.tar` internal layout (N4, negligible at this stakes level).

### 2. Every AD Rule enforceable and actually preventive — 5 of 8 clean

| AD | Enforceable? | Prevents stated divergence? |
|----|---|---|
| AD-1 | NO — F3 (input sentence unsatisfiable) | Yes, otherwise (order/ownership/publish-placement) |
| AD-2 | Yes (staging gate + atomic `mv` + trap; testable "complete or nothing") | Yes |
| AD-3 | NO as written — F2 (`docker` missing, "exactly one" unsatisfiable) | Intent right, Rule over/under-scoped |
| AD-4 | Yes (order seal→hash→ship, key handling, wipe) | Yes, modulo F5 ambiguity |
| AD-5 | Yes (exact 2-member emit, write-once, remote stage→verify→rename) | Yes |
| AD-6 | Yes (precedence, registry, fail-fast, no-argv-secrets) | Yes, modulo F4 omission |
| AD-7 | Yes (grammar is machine-checkable; `flock -n` implied by "exits immediately") | Yes |
| AD-8 | Yes mechanically, but contradicts AD-6 (F1) | Yes (whole-dir, dirname-sort, gated) |

### 3. Nothing under Deferred could let two units diverge — PASS

All eleven bullets are "don't build" or "owned elsewhere" statements, each with
an explicit v1 rule where behavior is needed: exit 1 + `FAIL:<STAGE>` (L235, via
AD-7); env-only config (L236, via AD-6); no retries/NAS logic/parallelism
(L237); checkout-run packaging (L239); scheduler-owned logs (L240).
Retention-horizon non-enforcement (L232–233) matches SPEC non-goals (SPEC L57)
and `retention-policy.md` L3 ("declares policy only"). Consumer contract +
`backup-contract.md` v2 + NAS provisioning correctly externalized (L241–243;
SPEC L53). No deferred item leaves a producer-side choice open.

### 4. Named tech verified-current — PASS (independently checked 2026-11-03)

| Spine claim | Verification |
|---|---|
| `age` 1.3.x, vendor 1.3.2 (Aug 2026; X25519) (L180) | CONFIRMED — v1.3.2 latest; FreshPorts dates 1.3.2 to 30 Aug 2026; v1.3.0 Dec 2025 added post-quantum recipients (X25519 path unaffected) |
| `rsync` ≥3.2, prefer ≥3.5.1 (3.5.0 fixed 33 CVEs; 3.5.1 fixed regressions) (L181) | CONFIRMED — 3.5.0 released 13 Aug 2026 fixing 33 security issues; 3.5.1 released 21 Sep 2026 fixing regressions (rsync.samba.org) |
| OpenSSH ≥9.x, prefer 10.x (10.6 Oct 2026) (L182) | CONFIRMED — 10.6 released 6 Oct 2026, newest as of late Oct 2026 |
| BATS ≥1.13 (1.14.0 Oct 2026) (L184) | CONFIRMED — 1.14.0 released Oct 2026 (PyPI/FreshPorts); 1.13.0 exists as prior |
| bash ≥5.0, prefer 5.3 (latest stable Jul 2025) (L178) | CONFIRMED — bash 5.3 released Jul 2025, still latest stable line |
| `gitlab-backup create STRATEGY=copy`, 12.2+ through 19.x (L179) | PLAUSIBLE, low-risk — spelling stable since 12.2; 19.x exists in the 2026 release train; command-spelling claims of this form are the least volatile cell in the table |

`sha256sum`/coreutils "format stable" (L183) is uncontroversial. No stale pins found.

### 5. Covers the driving spec's capabilities — PASS

| Capability | Spine coverage |
|---|---|
| CAP-1 capture (SPEC L22–24) | CAPTURE stage; AD-1/2/3; Stack mechanism (modulo F4 handoff silence) |
| CAP-2 whole volume + compose into sealed set (SPEC L25–27) | BUNDLE+ENCRYPT; AD-1/3/4; `backup-contents.md` 2-member table matched exactly |
| CAP-3 byte-identical compose (SPEC L28–30) | AD-1 L53–54 (`cmp` check); COMPOSE_FILE in AD-6 registry |
| CAP-4 one outer hash, no inner (SPEC L31–33) | HASH stage; AD-1/3/5; AD-4 L103 "no inner hashes"; matches non-goal SPEC L60 |
| CAP-5 ship as one unit + post-trip re-verify (SPEC L34–36) | SHIP stage; AD-1/2/4/5; presence-then-hash order (AD-5 L113–114) matches SPEC L53 and `capture-and-transport.md` L6 |
| CAP-6 newest 2, never piecemeal (SPEC L37–39) | PRUNE stage; AD-1/8; matches `retention-policy.md` L5/L7 (modulo F1) |
| CAP-7 complete-or-loud-failure (SPEC L40–42) | AD-2 + AD-7; induced-failure tests in structural seed (L215); exit-nonzero-naming-step satisfied by `FAIL:<STAGE>` + exit 1 |

Constraints cross-check: bash-only/explainable (AD-3 + conventions L169) ✓;
scheduler-agnostic (AD-3 L89–90, seed L192) ✓; `STRATEGY=copy` (Stack L179) ✓;
exactly-one-`age` + out-of-band pubkey + vendoring (AD-1 L54–55, AD-4, seed L213) ✓;
rsync-over-SSH two-server (AD-5, seed L190–196) ✓; one-set-one-timestamp unit
(AD-2, AD-8) ✓; `test-gitlab-server/backups/` POC placement (AD-6 L132–133,
seed L192) ✓; v2 verification + parent-dependency split (AD-5, Deferred L241–243) ✓.
Non-goals all honored (Deferred + AD-4/AD-5; live-volume exclusion via "only
data capture" chain: SPEC L61 → conventions L168 "Nothing else enters the set").

### 6. Every owned dimension decided, deferred, or an open question — MOSTLY; two silences

Decided: paradigm, stage decomposition, atomicity, tool split, secrecy,
producer/consumer boundary, config, failure grammar, pruning, naming, formats,
set contents, explainability standard, auth, verbosity, deployment envelope,
on-disk layouts, test placement, capability map. Deferred with owner: scheduling,
horizon enforcement, off-site, restore, log backup/capture, exit taxonomy, CLI
flags, parallelism/retries, NAS logic, rotation, packaging, consumer contract,
script split. Open questions: none recorded — acceptable at solo-stakes with a
complete Deferred list.

Silent (neither decided, deferred, nor asked): (a) capture handoff mechanism +
container-side path (F4 — a genuine miss); (b) `set.tar` internal member layout
(N4 — negligible, one line to close).

### 7. Re-derivation complete; no inter-AD contradictions — DERIVATION COMPLETE; THREE CONTRADICTIONS

**Completeness (pass):** the 2-member `{set.tar.age, SHA256SUMS}` shape is
asserted identically in AD-1 (L54–57), AD-2 "exactly its two shippable members"
(L66–67), AD-5 "exactly `{set archive (.age), SHA256SUMS}`" (L109), conventions
(L166), and the on-disk seed (L200–205) — no 4-member residue survives. The
whole-volume design is likewise uniform (AD-1 L53, conventions L168, CAP map
L223); no file-list residue survives. Single-hash-over-sealed-blob is triple-
asserted (AD-1 L56, AD-4 L103, AD-5 L110–111) with "no inner hashes" matching
SPEC CAP-4 and its non-goal. Only lexical dust remains ("manifest," N2).

**Contradictions (fail, all fixable in one line each):** F1 (AD-8 vs AD-6),
F2 (AD-3 vs Stack), F3 (AD-1 internal); plus minor F5 (AD-4 vs AD-6) and N1
(AD-1 "Exactly" vs AD-7 vocabulary). No other pair was found contradictory:
AD-1/AD-2 publish placement, AD-2/AD-5 two-sided staging, AD-4/AD-5 seal-then-
hash order, AD-6/AD-7 CONFIG fail-fast grammar, and AD-2/AD-7 trap grammar all
agree on inspection.

---

## Required changes (suggested edits)

1. AD-8 L157: "keep the newest `RETENTION_COUNT` (default 2) set dirs…" (F1).
2. AD-3 L86–88: one *domain* tool per stage + `docker` for CAPTURE + PRUNE→`rm`
   + closed file-utility set (F2).
3. AD-1 L58–59: exempt AD-6-declared source inputs from the set-dir-only rule (F3).
4. AD-6 registry L135–136: add the config-volume host-path variable (and
   container tarball path if `docker cp`); AD-1/AD-3: name the handoff (F4).
5. AD-4 L102 or AD-6 L136: reconcile pubkey supply to the single registered
   shape (F5). Optional: N1–N4 polish.

## Method note

Read the spine (244 lines) in full plus SPEC.md and all three companions.
Independently verified five of six Stack version claims via web search on
2026-11-03 (age, rsync, OpenSSH, BATS release records; bash from stable
knowledge); the sixth (`gitlab-backup` spelling range) judged plausible/low-risk.
Checked every AD pair for contradiction and every SPEC capability, constraint,
and non-goal for spine coverage.
