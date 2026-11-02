# Epic 1 Context: Safe Upgrade Planning

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

The operator can validate the environment and preview the exact one-stop upgrade plan (detected current version → pinned target) without changing anything, and the script refuses to plan an unsafe or unplannable run. Stories 1.1–1.3 build the script skeleton and cross-cutting substrate (halt contract, config, probes) with no operator-visible value alone; the epic demos end-to-end once 1.4–1.7 land (`--plan` against the seeded instance).

## Stories

- Story 1.1: Script skeleton with loud, consistent halts
- Story 1.2: Strict startup configuration and single-run lock
- Story 1.3: Probe library with Layer-0-first discipline
- Story 1.4: Stop-list extraction from vendored YAML
- Story 1.5: Current version detection and next-stop lookup
- Story 1.6: Latest-patch pin via Hub tags API
- Story 1.7: Plan print, note acknowledgement, and read-only --plan

## Requirements & Constraints

- Every failure halts loudly: non-zero exit, one UTC ISO-8601 log line naming what failed, where, and what to do next. No auto-remediation, no silent partial halts. Failures detected in any phase must never mutate anything afterward except log/bundle writes.
- All configuration arrives as environment variables and is validated strictly once at startup, before any action, in fixed order: exclusive lock first, then required-nonempty, token trim, optional defaults, file existence, edition coherence. Every missing variable or path is named in the halt.
- The printed plan shows exactly one hop: detected live current version to the next required stop resolved to an exact latest-patch image tag. The plan never floats between plan and run.
- Read-only preview mode rehearses the plan plus every readable pre-pause check, dying in-format on the first failure, and stops before the first mutation. It validates full config like a live run.
- Verification is runs against the seeded instance plus a read-only preview — no unit harness. Explainability outranks feature count: every line must be defensible to a reviewer without notes.
- Out of scope: backup implementation (verification only), multi-node/zero-downtime/Helm, maintenance mode, retry/resume within a stop, Runner binary upgrades, secrets manager.

## Technical Decisions

- One self-contained Bash file plus vendored stop-list YAML; no sourced files, readable top-to-bottom. Toolchain is Bash 3.2+ (POSIX-sh-compatible subset: no assoc arrays, mapfile, case-modification) plus curl, git, docker/compose CLIs only — no Python. Source layout: constants, strictness+trap, log/die, probes, phases in execution order, arg-parse, main.
- Single `die()` halt contract with fixed log format; halt line carries dynamic runner/container values and a fixed gate vocabulary (`validate plan pre pause mutate monitor proceed unpause closeout`); INT/TERM traps route into `die()` with the current-phase gate. External-command failures halt directly; in-pipeline parse failures use explicit shape-assert-die.
- Exclusive single-run lock via `mkdir`, taken first, released via trap. Secrets travel via a curl config file (mode 600, trap-removed), never argv. Admin token serves version/runners APIs, smoke token serves clone, health probes use no token.
- JSON is parsed with `jq -r` when present, else a `grep -oE` fallback; every probe defines both forms producing byte-identical bare output, and the parser is detected once at startup, exported, never re-detected.
- Container state is checked before trusting HTTP: every scripted exec passes `-T`, every curl carries a timeout, refused/timeout resolves through container state, unexpected 404-with-Running reads allowlist-suspect, and a generous grace window follows container recreation before startup is declared failed.
- Current version comes from the live version API with the admin token, normalized on both sides and compared with exact equality against the startup-derived expected edition. The stop list is read from the vendored YAML via a short grep/sed pipeline over the pinned shape (major/minor pairs with optional per-stop notes); anything outside that shape halts. Every stop is taken as a normal stop including conditional ones; no following entry halts stating already-at-head. The target is pinned to the latest patch by polling the Hub tags API with pagination, strict tag filtering, numeric patch sort, and max-pick; Hub failure or an empty set halts with no retry or fallback.
- No state file and no concurrency: every phase re-derives state from the live instance and re-runs are stateless.

## UX & Interaction Patterns

- Before any pause or backup, a live run shows the target note (when non-blank) and prompts exactly `Type ACK <stop> to proceed:`, proceeding only on an exact match; a decline leaves zero side effects and each acknowledgement is logged. Preview mode never prompts and never needs a TTY; a live run without a TTY halts.

## Cross-Story Dependencies

- Stories 1.1–1.3 are substrate: 1.1 (skeleton, halt contract) first, then 1.2 (config validation, lock) and 1.3 (probe library, parser detection) — 1.4–1.7 build on all three.
- Story 1.5 depends on 1.4 (stop list) for next-stop lookup and on 1.2 for the expected edition used in version comparison; 1.6 depends on 1.5's resolved stop; 1.7 depends on 1.5+1.6 for the printed plan.
- Epic 1's preview mode rehearses Epic 2's pre-implementation gate read-only, so its checklist must stay aligned with that gate's checks; later epics consume this epic's plan resolution, probes, and halt contract unchanged.
