# PRD Quality Review — gitlab-backup

## Overall verdict

This PRD holds up: a sharp thesis ("either produces a complete, verifiable backup set ... or fails loudly"), honest scope boundaries with reasons, and FRs that are mostly directly testable. What's at risk is minor — one FR with undefined unit semantics and the absence of a glossary for downstream extraction — neither of which blocks a solo build. Calibrated to its stated stakes (solo learning artifact, simplicity wins ties), it is decision-ready.

## Decision-readiness — strong

Decisions are stated as decisions throughout: "exactly one `age` invocation" (§ FR-4), "No inner hashes" (§ FR-6), "The live data volume is never copied" (§ FR-1). Trade-offs are surfaced honestly in the addendum with what was given up, not just what was chosen — encrypt-each rejected because "Per-file granularity ... is unneeded for a rollback path," double hashing rejected as "A second mechanism to explain, test, and break, for no new guarantee." Open Questions ("None blocking. Out-of-band values above are build inputs.") is a genuine closure statement, not a dodged question: the Dependencies section names exactly what arrives out-of-band. No `[NOTE FOR PM]` callouts exist, but there are no deferred tensions to hang one on — demanding them here would be ceremony.

### Findings

None. This dimension needs nothing.

## Substance over theater — strong

No persona theater: the three Users entries each drive decisions (Operator → "Single invocation, scheduler-agnostic" in FR-11; Upgrade runner → the verifiability requirements; Mentor → "audit-grade bash" in NFR-1). No innovation theater: the PRD claims no novelty anywhere. No NFR theater: NFR-1 ("bash-only, no Python; one named function per stage; every tool call commented") and NFR-2 ("no scheduler logic, no retry logic duplicating tool flags, no NAS-side logic") are product-specific prohibitions, not boilerplate. No vision theater: the Goal ("Two guarantees, nothing else: confidentiality ... and integrity") could not be swapped into any other PRD. One soft phrase lives in NFR-1 but belongs to done-ness, counted there.

### Findings

None. This dimension needs nothing.

## Strategic coherence — strong

The thesis is explicit and load-bearing: the backup is "the rollback path the stepwise upgrade runner requires before any migration step," with exactly two guarantees. Every FR serves that arc; nothing reads as backlog filler. Success metrics validate the thesis rather than measuring activity ("A run yields blob + matching hash locally and on the NAS, or exits non-zero naming the failure"; "An induced failure at each stage ... produces a named failure with nothing partial left behind"). A counter-metric is named and it guards the thesis directly: "any design needing per-artifact handling after seal ... is rejected as drift." Scope kind is a coherent capability spec with scope logic to match (In/Out lists, parent-deliverable boundary).

### Findings

None. This dimension needs nothing.

## Done-ness clarity — adequate

Most FRs carry testable consequences an engineer could verify directly: "byte-identical to source" (§ FR-3, diffable), "exactly one `age` invocation" (§ FR-4, countable), "`sha256sum -c` format" (§ FR-6, runnable), "the newest 2 local sets remain (dirname order)" (§ FR-9, enumerable), "exits non-zero naming the step and leaves no partial set behind" (§ FR-10, observable per the induced-failure success metric). The potentially soft "fails loudly" from the Goal is pinned down by FR-10 rather than left floating. Two soft spots remain: one FR leans on an undefined collective noun, and one NFR ends in an untestable style adjective.

### Findings

- **[medium]** "As one unit" has no testable consequence (§ FR-7) — "ships blob + hash to the NAS over rsync/SSH key auth as one unit" never says what unit-ness means operationally (single rsync invocation? atomic publish? both files or neither on failure?), unlike FR-9/FR-10 which spell out whole-unit deletion and no-partial-set behavior. *Fix:* add one clause, e.g. "a ship that delivers only one of the two files is a failure per FR-10, with the partial remote file removed."
- **[low]** "No cleverness" is untestable (§ NFR-1) — "bash-only, no Python; one named function per stage; every tool call commented; no cleverness" ends a list of verifiable constraints with a judgment call. *Fix:* leave it as mentor-facing style guidance (it matches the "Solo learning artifact" stakes) or drop it; do not pretend it is acceptance criteria.

## Scope honesty — strong

The Out list does real work: eight exclusions, several with the reason attached ("live data-volume copies (inconsistent under a running server — the tarball is the capture)"; "automated restore (stays manual/documented)"). The single inference is tagged inline: "[ASSUMPTION] Sealed blob filename is `set.tar.age`" (§ Dependencies), with the pin vs. freedom stated ("pins 'one blob + one hash', not the name"). Boundaries against the parent deliverable are explicit twice (Scope Out: "`backup-contract.md` v2, runner checks"; Dependencies: "not this build"). Open-items density (0 open questions, 1 assumption, 0 PM notes) fits a low-stakes green-light PRD. The missing Assumptions Index entry point is mechanical, noted below.

### Findings

None. This dimension needs nothing.

## Downstream usability — adequate

FR IDs are contiguous and unique (FR-1–FR-11), NFR IDs likewise (NFR-1–NFR-3), and domain nouns ("set," "blob," "hash," "seal") are used consistently across Scope, FRs, and Success. Each section reads sensibly alone; there are no dangling "see above" references. Gaps are proportionate to a standalone 2-page PRD feeding one build directly: there is no glossary (acceptable given the consistent vocabulary, but a 5-term one would harden extraction), and the four success/counter-metrics are unnumbered, so the build cannot cite them by ID.

### Findings

- **[low]** Success metrics lack IDs (§ Success + counter-metrics) — "A run yields blob + matching hash ..." and siblings cannot be referenced from build notes or test plans. *Fix:* number them SM-1–SM-4 (CM-1 for the counter-metric, or keep it inline as is).

## Shape fit — strong

Correctly shaped as a single-operator capability spec: no UJs, and their absence is right rather than a gap — the only human action is "runs one command," and the consumer is a downstream runner whose checks are explicitly "its own business (parent deliverable)." Success metrics are operational (blob + hash on both ends, induced-failure matrix, one manual restore demo), not user-facing vanity metrics. Brownfield grounding is present where it matters (addendum: "Grounded in `test-gitlab-server/docker-compose.yml`: config/logs/data binds"). No over- or under-formalization for hobby/solo stakes.

### Findings

None. This dimension needs nothing.

## Mechanical notes

- Glossary drift (trivial): "one set archive" (§ FR-4) vs "the sealed blob" (§ FR-6) vs "`set.tar.age`" (§ Dependencies) all denote the same artifact; meaning is recoverable from context in all three places. A glossary would collapse them.
- ID continuity: FR-1–FR-11 and NFR-1–NFR-3 contiguous, unique, no duplicates; no cross-references to resolve (FR-10 is referenced by name only in this review, not in the PRD). Success metrics unnumbered (see Downstream usability finding).
- Assumptions Index roundtrip: one inline `[ASSUMPTION]` (§ Dependencies), no index section at the end. For a single assumption this is fine; do not build index machinery for it.
- UJ protagonist naming: n/a — no UJs, correctly (see Shape fit).
- Required sections for stakes: Goal, Users, Scope (In/Out), FRs, NFRs, Success + counter-metrics, Dependencies, Open questions all present.
