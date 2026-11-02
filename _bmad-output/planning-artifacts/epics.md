---
status: final
stepsCompleted: ["step-01-validate-prerequisites", "step-02-design-epics", "step-03-create-stories", "step-04-final-validation"]
inputDocuments:
  - _bmad-output/specs/spec-deliverable-gitlab-update/SPEC.md
  - _bmad-output/specs/spec-deliverable-gitlab-update/upgrade-procedure.md
  - _bmad-output/specs/spec-deliverable-gitlab-update/health-gates.md
  - _bmad-output/specs/spec-deliverable-gitlab-update/backup-contract.md
  - _bmad-output/planning-artifacts/briefs/brief-deliverable-gitlab-update-2026-10-29/brief.md
  - _bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md
  - _bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/BUILD-NOTES.md
---

# deliverable-gitlab-update - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for deliverable-gitlab-update, decomposing the requirements from the SPEC (which serves as the requirements source in place of a PRD) and Architecture requirements into implementable stories. There is no UX design input (Bash CLI tool, no UI).

## Requirements Inventory

### Functional Requirements

_Ordered by runtime phase (validate → plan → pre → mutate → monitor → proceed → close-out), then cross-cutting substrate. FR numbers are stable IDs, not sequence._

#### Validate

FR18: Take all configuration from env vars and reject bad config before doing anything: strict startup validation (required: `GITLAB_URL GITLAB_ADMIN_TOKEN GITLAB_SMOKE_TOKEN GITLAB_COMPOSE_FILE COMPOSE_SERVICE BACKUP_PATH SEED_PROJECT_PATH` — except `BACKUP_PATH`, which under `--nobackup` may be unset and is not existence-checked; optional with defaults: `GITLAB_IMAGE_REPO LOG_FILE UPGRADE_PATH_FILE`); normalize URL/token; take the exclusive `mkdir` lock first with trap release; pass secrets via curl `-K` file (mode 600, trap rm), never argv; token map is version+runners=admin, clone=smoke, health probes=none. Runs once at startup — no phase re-validates config later.

#### Plan

FR1: Detect the live instance's exact current version by pinging `GET /api/v4/version` (AD-3 normalization) — this answers "where are we", not "where next": it yields the running version only, and the next required stop (FR2, as bare `X.Y`) plus its exact latest-patch pin (FR3, `X.Y.z`) are resolved downstream before the one-hop plan prints.
FR2: Stop list comes from the vendored `upgrade_path.yml` — flat `major:`/`minor:` pairs (major.minor only, no patches), each optionally carrying a `comments:` note that is shown to the operator at plan time (see FR4); read via a short grep/sed pipeline over this pinned shape, and anything outside it dies; every stop is taken as a normal stop including conditional ones; halt stating already-at-head when no entry follows the current version (an outcome of lookup, not a separate check).
FR3: Pick the latest patch per major.minor stop by polling the Docker Hub tags API (`name=<major.minor>&page_size=100`, follow `next`, filter `^<M>.<m>.[0-9]+-(ce|ee).0$`, POSIX numeric patch sort, pick max), resolving the bare `X.Y` from FR2 into an exact `X.Y.z` image tag; Hub failure or empty set dies with no retry or fallback.
FR4: Require the operator to ACK the exact stop/version about to be installed: the target note (if non-blank) is shown with the plan, then a live run prompts exactly `Type ACK <stop> to proceed:` before any pause/backup and proceeds only on an exact match (a decline leaves zero side effects); `--plan` mode never prompts; a live run without a TTY halts with GATE=plan; each ack is logged.
FR5: REMOVED — merged into FR7. Planning performs no health gating; the leftover-migration tripwire now lives only in the single pre-implementation gate. The already-at-head halt moved to FR2.
FR6: Rehearse the FR7 suite read-only and stop before the first mutation (`--plan`): same resolution and plan print (FR1–FR3), every FR7 check that is readable without mutating (`/-/health`, `/health_check`, rake leftover, backup verification (skipped loudly under `--nobackup`), runners enumeration reported as "would pause N, M running" and never paused), the fixed checklist in stable order, halting in-format on the first failure — never an ACK, never a TTY, full config validated (a plan always preludes a live run); pause, drain, push, and container change never execute. FR6 defines no checks of its own — its list is FR7's.

#### Pre-implementation gate

FR7: The single pre-implementation gate — prove the instance is safe to touch before any container change: `/-/health` OK, `/health_check` success, no leftover unfinished migrations with rake table all `finished` (the only migration check in the run; planning performs no health gating), backup-contract verification passing (FR8, unless `--nobackup`), and CI paused/drained (FR9) — with health/backup/migration checks run before pausing to fail fast, and the full set re-asserted after the drain. Its read-only rehearsal is FR6.
FR8: Verify the backup, never create it: `$BACKUP_PATH/` must hold `data/`, `secrets/`, and `BACKUP_CREATED_AT` (epoch seconds), fresh meaning `RUN_START - BACKUP_CREATED_AT <= 86400`; halt naming the missing or stale item — unless `--nobackup` is passed, which skips this check run-wide (gate, plan rehearsal, close-out re-check) with a loud logged warning, for testing before the backup producer exists. Backup creation itself is out of scope — FR8 only checks the artifact exists and is fresh, feeding the FR7 gate.
FR9: Silence CI to produce the paused-and-drained state FR7 requires before mutate: enumerate `GET /runners/all?per_page=100` following `Link rel="next"`, pause each runner via `PUT --form paused=true` (zero runners is a logged no-op), drain until zero running jobs across all runners (10 s poll with heartbeat, no timeout), and assert-all-paused before mutate. FR9 pauses only — unpause-all happens solely on the success path at proceed-gate step 6 (FR13); on failure runners stay paused (FR14).

#### Mutate

FR10: Swap the docker compose container's version config to the FR3-pinned version, scoped strictly to `$COMPOSE_SERVICE`, in three steps: (1) back up the compose file beside itself as `$F.bak-<target>-<epoch>` (the compose text only — not the data, which FR8 verified; kept as evidence, never auto-restored); (2) mutate the service's `image:` line via `sed` anchored to the service stanza, asserting exactly one such line, writing the exact `X.Y.z` tag FR3 resolved; (3) `pull` the new image with docker tooling, then `down` and `up -d` (never `-v`). An identical tag proceeds as a logged idempotent re-run. FR10 changes the container and nothing else — no health verdicts (FR11/FR12), no proof of done (FR13).

#### Monitor

FR11: Watch GitLab migration health through the online wait: 10 s heartbeat log lines carrying GitLab application signals (HTTP `/-/health`, `/-/liveness`, `/health_check/database`, `/health_check/cache`, plus rake finished-count deltas via `exec -T`), with container-runtime telemetry from docker (Layer-0 state plus cpu/mem/block-IO/net-IO from one `docker stats --no-stream --format` sample) riding along as supporting context for FR12's verdict. Batched background migrations run while GitLab serves traffic, so HTTP is expected to answer — a 503 or backend failure halts per FR12; only readiness is excused (expected red). FR11 only observes and logs; the halt verdicts belong to FR12.
FR12: Hang verdict from GitLab and docker status combined: a hang means zero rake finished-count movement for 30 consecutive 10 s heartbeats while docker shows an idle box (cpu integer-part zero AND block-I/O raw string unchanged) — flat progress plus flat resources, i.e. wedged rather than slow-but-working; any finished-count movement resets the counter. Separately, GitLab backend failures — liveness 503 or failing `/health_check/database`/`/cache` — halt immediately without waiting out the window. Both halt with `GATE=monitor`. FR12 judges the signals FR11 collects; it collects nothing itself.

#### Proceed

FR13: Prove GitLab works normally by running every check and testing the system: six steps in fixed order: (1) version match with edition re-assert, (2) rake all `finished`, (3) `/health_check` success, (4) `/-/readiness?all=1` green with per-service statuses recorded, (5) seeded-project `main` clone-and-push smoke test, (6) full health re-check then unpause-all — step 6 on the success path only. FR13 is the proof of done, not the close-out: success/failure wrap-up belongs to FR14.

#### Close-out

FR14: Confirm FR13's proof endures, then close out: on success re-run the full Phase 1 health checks (backup check skipped under `--nobackup`), confirm runners unpaused with jobs flowing — the live proof of normal use (the step-5 smoke test is not re-run; it proved the push path once); on failure leave runners paused and produce a diagnostics bundle (FR15) plus a 4-line rollback story. FR14 never retries or remediates — it reports the outcome and parks the instance in its safe end state.
FR15: Capture a diagnostics bundle on failure: fetch standalone `gitlabsos.rb` pinned to toolbox SHA `cb73cacc` at failure time, `docker cp` it in and run it with embedded ruby into `./failure-bundle-<target>-<epoch>/`; if fetch or run fails, fall back to the native manifest (logs tail, inspect, replayed readiness/health lines, best-effort rake) with logged degradation. Either path always includes the recorded readiness per-service statuses plus `/health_check` failure messages. The bundle is evidence for a human — nothing in FR15 fixes or retries.

#### Cross-cutting substrate

FR16: Read the docker container status (Layer 0: `docker compose ps` + `docker inspect`) before trusting HTTP: every `compose exec` passes `-T`, every curl carries `--max-time`; allow a 10-minute grace for `/-/health` after `up -d`; resolve refused/timeout through container state; treat unexpected 404-with-Running as allowlist-suspect; halt with exit code plus log tail on Exited; log container state alongside every HTTP poll result. A cross-cutting reading rule for all probes — it performs no phase's checks itself.
FR17: Halt loudly and uniformly through one `die()`: fixed log format, non-zero exit, single-quoted values, dynamic `RUNNERS=`/`CONTAINER=`, GATE vocabulary `validate plan pre pause mutate monitor proceed unpause closeout`; `die()` never mutates after detection except log/bundle writes; `|| die` on fallible external commands with shape-assert-die on parses; never retry `up` in the down window; INT/TERM trap routes into `die()` with the current-phase GATE. FR17 defines how every halt looks — the *when* belongs to each phase's own FR.
FR19: Parse JSON portably: `jq -r` when present, else `grep -oE` fallback, with every probe defining both its jq filter AND its grep regex producing byte-identical bare output; `PARSER` is detected once at startup, exported, and never re-detected. Parsing mechanics only — each probe's fields and shape asserts live with that probe's FR.

### NonFunctional Requirements

NFR1: The runner is one self-contained Bash file plus vendored `upgrade_path.yml`, readable top-to-bottom; Bash 3.2+ running a POSIX-sh-compatible subset (no assoc arrays, mapfile, case-modification).
NFR2: Explainability outranks feature count: every line and every technology choice must be defensible to the mentor without notes; no helper functions that obscure rather than clarify.
NFR3: Toolchain limited to Bash + curl (+jq with grep fallback) + git + docker/compose CLIs; no Python or other runtimes — line-by-line auditability is the grading criterion.
NFR4: Detect-and-halt everywhere with each issue written to the log for a human to fix; the script never upgrades a sick instance and never auto-remediates.
NFR5: Log format: UTC ISO-8601 timestamps, standard line `<ts> phase=<p> msg="<..>"`, die line adding `GATE= EXPECTED= OBSERVED= ACTION= RUNNERS= CONTAINER=`; heartbeat ordered fields `hb elapsed_s=<int> health=<OK/FAIL> liveness=<200/503/REFUSED> cpu_raw="<..>" mem_raw="<..>" bio_raw="<..>" net_raw="<..>" rake_finished=<int> rake_total=<int> rake_delta=<signed>`.
NFR6: No unit harness; verification is runs against the seeded instance plus the injected-failure halt plus read-only `--plan` mode.
NFR7: Demo proves DONE-per-stop across 2–3 real required stops (16.11 → current 17.x chain, one stop per run) and one injected failure (disk pressure or stalled migration) proving hang detection halts with actionable logs.
NFR8: No state file and no concurrency; every phase re-derives state from the live instance; re-runs are stateless.
NFR9: Telemetry lines stay terse (single log line per 10 s heartbeat, ~8640 lines/day) so multi-day waits stay greppable.
NFR10: Health gates follow official endpoint semantics: comprehensive `/health_check` checks for monitoring only, readiness for traffic decisions, liveness for deadlock detection, localhost plus allowlist for access.

### Additional Requirements

- No starter template: greenfield single-file script per the structural seed (`runner/upgrade-gitlab.sh` + vendored `upgrade_path.yml` with source-URL + fetch-date header); Epic 1 Story 1 creates the skeleton, not a template install.
- Source layout top-to-bottom: constants, strictness+trap, log/die, probes, phases in execution order, arg-parse, main.
- Env validation order: lock first, then required-nonempty (URL scheme+host assert), then token-trim, then optional defaults, then file/dir existence (compose, YAML, backup unless `--nobackup`), then edition/repo coherence.
- Hang-counter pseudocode: `flat=0`; each heartbeat: if `rake_delta>0` then `flat=0` else if cpu-int==0 and bio-string-unchanged then `flat+=1` else `flat=0`; `flat>=30` dies GATE=monitor.
- Failure-path exec lines: `docker cp /tmp/gitlabsos.rb $CID:/tmp/gitlabsos.rb`, `compose exec -T $SVC /opt/gitlab/embedded/bin/ruby /tmp/gitlabsos.rb -o /tmp/sos`, `docker cp $CID:/tmp/sos ./failure-bundle-<t>-<e>/`; any step failing falls to the native manifest.
- Probe contracts are byte-identical jq/grep pairs (version, runners list/id-paused pairs, drain `[]`, rake pipe-shape, Hub tags name/next) per BUILD-NOTES.
- Accepted residual risks: Hub legacy tags path may retire (dies loudly; namespaced `/v2/namespaces/.../tags` is the documented successor); 17.x `:status` grammar padding drift (pipe-shape assert halts, never mis-parses); host-locale telemetry string sensitivity (negligible on single-maintainer demo host).
- Out of scope (must not generate stories): backup implementation, zero-downtime/multi-node/Helm, maintenance mode, Geo/external Gitaly/Elasticsearch/K8s agents, Runner binary/container upgrades, retry/resume within a stop, troubleshooting detail beyond the failure bundle and rollback statement, archive scraping, secrets manager.

### UX Design Requirements

None — Bash CLI tool with no UI. The only operator interaction is the `Type ACK <stop> to proceed:` TTY prompt (covered by FR4).

### FR Coverage Map

_Same runtime-phase order as the inventory above._

FR18: Story 1.2 - Env-var config, strict startup validation, lock, secret handling
FR1: Stories 1.5, 1.7 - Ping live version via API; anchors the printed one-hop plan (target resolved via FR2+FR3)
FR2: Stories 1.4, 1.5 - Stop list + per-stop notes from vendored YAML via grep/sed, every stop normal, already-at-head halt
FR3: Story 1.6 - Latest-patch pin via Hub tags API, fail-closed
FR4: Story 1.7 - Target note shown and ACKed up front before any change
FR5: REMOVED — merged into FR7
FR6: Story 1.7 - --plan rehearses the FR7 suite read-only, stops before first mutation
FR7: Story 2.3 - Single pre-implementation gate before any container change
FR8: Stories 2.1, 4.2 - Backup-contract verification (~15 lines); skipped under --nobackup incl. close-out
FR9: Story 2.2 - CI quiet via Runners API (pause, drain, assert)
FR10: Story 3.1 - Mutate: compose backup, sed pin, pull, down/up
FR11: Story 3.2 - Health-during monitor: heartbeat telemetry + rake deltas
FR12: Story 3.3 - Hang verdict: 5-minute flat window halts, backends halt fast
FR13: Stories 4.1, 4.2 - Proceed gate: ordered 6-step proof of done + unpause
FR14: Stories 4.2, 4.3 - Close-out: re-check on success, bundle + rollback story on failure
FR15: Story 4.3 - Failure bundle: pinned gitlabsos fetch with native fallback
FR16: Story 1.3 - Layer-0-first channel discipline and probe library
FR17: Story 1.1 - Halt contract: die(), log format, GATE vocabulary, traps
FR19: Story 1.3 - jq with grep fallback, byte-identical probe outputs

## Epic List

### Epic 1: Safe Upgrade Planning

The operator can validate the environment and preview the exact one-stop upgrade plan (current → pinned target) without changing anything, and the script refuses to plan an unsafe or unplannable run.
**FRs covered:** FR18, FR1, FR2, FR3, FR4, FR6, FR16, FR17, FR19

### Epic 2: Pre-Upgrade Protection

The runner verifies the instance is healthy, backed up, and quiet before touching it — a sick, unbacked-up, or busy instance is never upgraded, unless testing with `--nobackup`.
**FRs covered:** FR7, FR8, FR9

### Epic 3: One-Stop Upgrade with Hang-Aware Monitoring

The runner advances the instance exactly one required stop and watches the migration wait with heartbeats and progress deltas, halting on hang instead of waiting silently.
**FRs covered:** FR10, FR11, FR12

### Epic 4: Proof of Done and Close-Out

The runner proves the stop is complete through the ordered proceed gate, resumes CI only on success, and closes every run out with re-verified health or a diagnostics bundle plus rollback story.
**FRs covered:** FR13, FR14, FR15

## Epic 1: Safe Upgrade Planning

The operator can validate the environment and preview the exact one-stop upgrade plan (current → pinned target) without changing anything, and the script refuses to plan an unsafe or unplannable run.

> Foundation epic: Stories 1.1–1.3 build the script skeleton and cross-cutting substrate (halt contract, config, probes) with no operator-visible value alone; the epic demos end-to-end once 1.4–1.7 land (`--plan` against the seeded instance).

### Story 1.1: Script skeleton with loud, consistent halts

As an operator,
I want the single-file runner skeleton to exist, with every failure halting in one clear log line,
So that later stories have a substrate to land on and I always know what failed, where, and what to do next.

**Acceptance Criteria:**

**Given** any phase detects a failure
**When** it calls `die()`
**Then** the run exits non-zero and appends one UTC ISO-8601 line carrying `GATE= EXPECTED= OBSERVED= ACTION= RUNNERS= CONTAINER=` with single-quoted values
**And** `RUNNERS=`/`CONTAINER=` show live values, never literals (FR17, NFR5)

**Given** a failure is detected
**When** `die()` runs
**Then** nothing mutates after detection except log and bundle writes: never retry `up` in the down window, and the failure path never unpauses (FR17)

**Given** the script receives INT/TERM mid-run
**When** the trap fires
**Then** the run dies in-format with the current-phase GATE from `validate plan pre pause mutate monitor proceed unpause closeout` (FR17)

**Given** a fallible external command fails
**When** the `|| die` pattern triggers
**Then** the halt names the command and phase; in-pipeline search/parse uses `|| true` plus explicit shape-assert-die (FR17)

**Given** a fresh checkout
**When** this story lands
**Then** `runner/upgrade-gitlab.sh` exists as the single self-contained runner plus vendored `runner/upgrade_path.yml` carrying a source-URL + fetch-date header; no sourced files, no starter template (AD-1, NFR1)

**Given** the script source
**When** read top-to-bottom
**Then** layout is constants, strictness+trap, log/die, probes, phases in execution order, arg-parse, main; Bash 3.2+ running a POSIX-sh-compatible subset (no assoc arrays, mapfile, case-modification); toolchain is Bash + curl (+jq with grep fallback) + git + docker/compose CLIs only, no Python or other runtimes (NFR1, NFR3)

**Given** any phase
**When** it needs state
**Then** it re-derives it from the live instance; there is no state file, no concurrency beyond the single-run lock, and re-runs are stateless (NFR8)

### Story 1.2: Strict startup configuration and single-run lock

As an operator,
I want the script to reject bad or missing configuration before doing anything,
So that a typo never causes a half-upgraded instance.

**Acceptance Criteria:**

**Given** any required env var (`GITLAB_URL GITLAB_ADMIN_TOKEN GITLAB_SMOKE_TOKEN GITLAB_COMPOSE_FILE COMPOSE_SERVICE BACKUP_PATH SEED_PROJECT_PATH`) is missing or empty (`BACKUP_PATH` exempt under `--nobackup`)
**When** the script starts
**Then** it halts before any action, naming every missing variable (FR18)

**Given** `GITLAB_URL` has a trailing slash or a token has surrounding whitespace
**When** validation runs
**Then** the URL is normalized with scheme+host asserted and the token trimmed; empty optional means the default (`GITLAB_IMAGE_REPO`=`gitlab/gitlab-ce`, `LOG_FILE`=`./upgrade-gitlab.log`, `UPGRADE_PATH_FILE`=script-dir `upgrade_path.yml`) (FR18)

**Given** another run holds `./upgrade-gitlab.lock`
**When** a second run starts
**Then** it dies immediately; the exclusive `mkdir` lock is taken first and released via trap (FR18)

**Given** probes need tokens
**When** curl runs
**Then** secrets travel via a curl `-K` file (mode 600, trap rm), never argv; version+runners use the admin token, clone uses the smoke token, health probes use none (FR18)

**Given** the script starts
**When** validation runs
**Then** checks execute in fixed order: exclusive lock first, then required-nonempty (URL scheme+host assert), then token-trim, then optional defaults, then file/dir existence (`GITLAB_COMPOSE_FILE`, `UPGRADE_PATH_FILE`, `BACKUP_PATH` unless `--nobackup`), then edition/repo coherence (FR18)

**Given** a referenced file or directory is missing
**When** validation runs
**Then** the run halts before any action, naming every missing path (FR18)

**Given** `GITLAB_IMAGE_REPO`
**When** edition coherence is checked at startup
**Then** basename `gitlab-ce` means CE, `gitlab-ee` means EE, anything else dies (FR18, AD-3)

**Given** the token contract
**When** validation runs
**Then** the admin token is documented as requiring `manage_runner` scope and the smoke token `write_repository`; a wrong-scoped token surfaces as a loud API halt, never silent misbehavior (FR18)

### Story 1.3: Probe library with Layer-0-first discipline

As an operator,
I want every health signal read through one disciplined probe set,
So that "down" is never confused with "sick".

**Acceptance Criteria:**

**Given** the script starts
**When** parser detection runs
**Then** `PARSER` is set once (`jq` if present else `grep`), exported, never re-detected; each probe defines its jq filter AND grep regex with byte-identical bare output (FR19)

**Given** any HTTP probe runs
**When** curl executes
**Then** it carries `--max-time` and its output is shape-asserted; every scripted `compose exec` passes `-T` (FR16)

**Given** a probe gets connection-refused or timeout
**When** the result is resolved
**Then** container state (`docker compose ps` plus `docker inspect`) is checked first: down halts with no HTTP probes, unexpected 404 with Running reads allowlist-suspect (FR16)

**Given** `up -d` just ran
**When** `/-/health` is polled
**Then** up to 10 minutes grace is allowed before startup-failed; Exited (or Restarting past the timeout) halts with the exit code plus log tail (FR16)

**Given** any poll runs
**When** results are logged
**Then** Layer-0 state is recorded alongside the HTTP results; checks mutate nothing except the log append (FR16)

### Story 1.4: Stop-list extraction from vendored YAML

As an operator,
I want the required-stop list read from the vendored file with zero ambiguity,
So that a malformed file halts loudly instead of mis-planning.

**Acceptance Criteria:**

**Given** the vendored `upgrade_path.yml`
**When** extraction runs
**Then** a short grep/sed pipeline reads `major:`/`minor:` pairs with each optional `comments:` kept next to its stop; anything else in the file dies; the file carries a source-URL + fetch-date header (FR2)

### Story 1.5: Current version detection and next-stop lookup

As an operator,
I want the script to find my exact current version and the single next required stop,
So that no required stop is ever skipped.

**Acceptance Criteria:**

**Given** a running instance
**When** version detection runs
**Then** the current version comes from `GET /api/v4/version` with the admin token, both sides normalized (tag minus `-(ce|ee).0`, API value minus optional `-(ce|ee)`) and compared with exact equality against the startup-derived expected edition (Story 1.2) (FR1)

**Given** the detected current version
**When** lookup runs
**Then** the single next entry is selected with every stop taken as a normal stop (no conditional-stop logic); no following entry halts stating already-at-head (FR2)

### Story 1.6: Latest-patch pin via Hub tags API

As an operator,
I want the target pinned to the exact latest patch,
So that no version ever floats between plan and run.

**Acceptance Criteria:**

**Given** a major.minor stop
**When** pin resolution runs
**Then** it queries the legacy Hub tags path with `name=<major.minor>&page_size=100`, follows `next` to null, filters `^<M>.<m>.[0-9]+-(ce|ee).0$`, POSIX-numeric-sorts the patch, and picks the max (FR3)

**Given** a Hub failure or empty tag set
**When** resolution runs
**Then** the run dies: single attempt, no retry, no fallback (FR3)

**Given** a pinned target
**When** the plan prints
**Then** the target is an exact `X.Y.z` tag resolvable to a published image (FR3)

### Story 1.7: Plan print, note acknowledgement, and read-only --plan

As an operator,
I want to see and approve the exact plan before anything changes — or preview it read-only,
So that upgrades never surprise me.

**Acceptance Criteria:**

**Given** a resolved plan
**When** a live run prints it
**Then** it shows the one hop from detected current to pinned target plus the target note when non-blank (FR1, FR4)

**Given** a non-blank target note
**When** a live run proceeds
**Then** it prompts exactly `Type ACK <stop> to proceed:` before any pause/backup, requires an exact match, leaves zero side effects on decline, and logs `ack stop=<s> at=<ts> note="<first 200 chars>"` (FR4)

**Given** no TTY on a live run
**When** acknowledgement is required
**Then** the run halts with GATE=plan; `--plan` never requires a TTY or acknowledgement (FR4, FR6)

**Given** `--plan` is passed
**When** it runs
**Then** only reads execute: the same resolution plus every readable pre-pause check from FR7 (`/-/health`, `/health_check`, rake leftover, backup verification (reported skipped under `--nobackup`), runners enumeration reported as would-pause and never paused), dying in-format on the first failure, printing the one-hop plan plus the fixed checklist in stable order; it validates the full config like a live run (FR6)

## Epic 2: Pre-Upgrade Protection

The runner verifies the instance is healthy, backed up, and quiet before touching it — a sick, unbacked-up, or busy instance is never upgraded, unless testing with `--nobackup`.

Runtime order: backup verification (2.1) and health pre-checks (2.3) run before pausing so a sick instance halts before CI is touched; pause and drain (2.2) follows; the final all-green assert (2.3) is the last step before any container change.

### Story 2.1: Backup-contract verification

As an operator,
I want the run to halt without a fresh backup,
So that there is always a rollback path.

**Acceptance Criteria:**

**Given** `$BACKUP_PATH`
**When** verification runs
**Then** `data/`, `secrets/`, and `BACKUP_CREATED_AT` must all exist; a missing item halts naming it (FR8)

**Given** the `BACKUP_CREATED_AT` epoch
**When** freshness is checked
**Then** `RUN_START - BACKUP_CREATED_AT <= 86400` must hold or the run halts naming the staleness; `RUN_START` is captured as the script's first statement and logged (FR8)

**Given** verification fails
**When** the run halts
**Then** Phase-1 recon never proceeds; the check stays ~15 lines, verification only, no backup implementation (FR8)

**Given** `--nobackup` is passed
**When** verification runs
**Then** the check is skipped run-wide with a loud logged warning (`msg="backup verification skipped (--nobackup)"`); the run proceeds with no rollback path (FR8)

### Story 2.2: CI quiet via Runners API

As an operator,
I want all CI activity drained before the upgrade,
So that no job writes mid-migration.

**Acceptance Criteria:**

**Given** runners exist
**When** enumeration runs
**Then** `GET /runners/all?per_page=100` follows `Link rel="next"` and each runner is paused via `PUT --form paused=true`; count plus IDs are logged, zero runners is a logged no-op (FR9)

**Given** paused runners
**When** draining runs
**Then** the script polls every 10 s with heartbeat until zero running jobs across all runners, with no timeout; it dies with GATE=pause only on query failure (FR9)

**Given** draining completes
**When** the assert runs
**Then** all-paused is asserted before mutate; unpause-all happens only at proceed-gate step 6 on the success path; the log notes pre-existing paused runners also resume (FR9)

### Story 2.3: Pre-upgrade health gate (final pre-mutate assert)

As an operator,
I want the full pre-upgrade gate enforced before any container change,
So that a sick instance is never upgraded.

**Acceptance Criteria:**

**Given** the pre-gate phase starts, before any pause
**When** health checks execute
**Then** all must hold: `/-/health` returns `GitLab OK`, `/health_check` reports `success` (failure message logged), no leftover unfinished migrations, the rake table shows all `finished`, and backup verification (Story 2.1) passes or is skipped via `--nobackup`; any failure halts before CI is touched (FR7)

**Given** pause and drain complete (Story 2.2)
**When** the final assert runs
**Then** every check above is re-asserted green plus CI paused and drained; the first failure halts (FR7)

**Given** any check fails
**When** the run halts
**Then** the log names each failing item for a human to fix; no container change has occurred; nothing auto-remediates (FR7)

## Epic 3: One-Stop Upgrade with Hang-Aware Monitoring

The runner advances the instance exactly one required stop and watches the migration wait with heartbeats and progress deltas, halting on hang instead of waiting silently.

### Story 3.1: One-stop container mutation

As an operator,
I want the container moved to exactly the pinned image,
So that the stop advance is explicit and human-reversible.

**Acceptance Criteria:**

**Given** the pinned target
**When** mutate runs
**Then** the compose file is copied beside itself as `$F.bak-<target>-<epoch>`; the backup is kept and never auto-restored (FR10)

**Given** the `$COMPOSE_SERVICE` stanza
**When** sed runs
**Then** exactly one `image:` line is replaced, anchored to the service stanza, else die (FR10)

**Given** the pinned compose file
**When** recreation runs
**Then** the sequence is `pull`, `down`, `up -d` (never `-v`); an identical tag proceeds as a logged idempotent re-run; the container image changes exactly once per run (FR10)

### Story 3.2: Migration-wait monitor with heartbeat telemetry

As an operator,
I want a live heartbeat with telemetry and progress deltas during the wait,
So that I can tell slow progress from silence.

**Acceptance Criteria:**

**Given** the wait starts
**When** monitoring runs
**Then** every 10 s one log line carries the ordered heartbeat (`hb elapsed_s=<int> health=<OK/FAIL> liveness=<200/503/REFUSED> cpu_raw="<..>" mem_raw="<..>" bio_raw="<..>" net_raw="<..>" rake_finished=<int> rake_total=<int> rake_delta=<signed>`) from a single `docker stats --no-stream --format` sample; readiness is excluded (FR11, NFR9)

**Given** each heartbeat
**When** probes run
**Then** `/-/health` OK, liveness 200, and `/health_check/database` + `/health_check/cache` success are recorded; `/health_check/migrations` is observed and logged only and never resets the hang timer (FR11)

**Given** the rake table
**When** it is parsed
**Then** at least one `Database: <name>` banner holds with every other non-blank line shaped `status | csv`, else die; the verdict is every status `finished`; zero rows means clear; deltas come from finished-count movement (FR11)

**Given** the wait continues
**When** all batched migrations read `finished`
**Then** the monitor exits to the proceed gate (FR11)

### Story 3.3: Hang detection with fast backend halts

As an operator,
I want a hung migration to halt loudly within minutes,
So that I never mistake a hang for slow progress.

**Acceptance Criteria:**

**Given** the monitor runs
**When** 30 consecutive 10 s heartbeats show zero rake finished-count movement AND cpu integer-part zero AND block-I/O raw string unchanged
**Then** the run halts with GATE=monitor; any finished movement resets the counter to 0 (FR12)

**Given** liveness 503 or `/health_check/database`/`/health_check/cache` non-success
**When** observed during the wait
**Then** the run halts immediately without waiting out the window (FR12)

**Given** an injected stall (disk pressure or a stalled migration) in the demo
**When** it occurs
**Then** flat deltas and/or failing backend sub-checks fire the halt with actionable logs instead of silent waiting (FR12, NFR7)

## Epic 4: Proof of Done and Close-Out

The runner proves the stop is complete through the ordered proceed gate, resumes CI only on success, and closes every run out with re-verified health or a diagnostics bundle plus rollback story.

### Story 4.1: Ordered proceed gate (proof of done)

As an operator,
I want continuation allowed only on demonstrated done-ness,
So that an unfinished stop never chains into the next.

**Acceptance Criteria:**

**Given** the stop wait ends
**When** the gate runs steps 1–5 in order
**Then** version match (AD-3 normalization, edition re-asserted), rake all `finished`, `/health_check` success, `/-/readiness?all=1` green, and the seeded-project `main` clone-and-push smoke test must all pass; the first failure halts (FR13)

**Given** step 4 runs
**When** readiness is queried
**Then** the per-service statuses are written to the log (FR13)

### Story 4.2: Recheck, unpause, and success close-out

As an operator,
I want CI resumed only after the full re-check passes,
So that jobs never resume onto a broken instance.

**Acceptance Criteria:**

**Given** proceed steps 1–5 pass
**When** step 6 runs
**Then** the full upgrade health checks re-run green, and only then unpause-all executes (FR13)

**Given** the run succeeds
**When** close-out runs
**Then** the full Phase 1 health checks re-run (backup check skipped under `--nobackup`), runners are unpaused, and jobs flowing is confirmed (FR8, FR14)

### Story 4.3: Failure bundle and rollback story

As an operator,
I want every failed run to leave a diagnostics bundle and a rollback story,
So that recovery starts from evidence.

**Acceptance Criteria:**

**Given** a failure
**When** bundling runs
**Then** standalone `gitlabsos.rb` pinned to toolbox SHA `cb73cacc` is fetched at failure time, `docker cp`'d into the container, and run via `exec -T` with the embedded ruby and explicit `-o` dir `./failure-bundle-<target>-<epoch>/` (logged) (FR15)

**Given** fetch or run failure
**When** falling back
**Then** the native manifest is collected (`logs --tail=500`, inspect, replay of recorded readiness/health lines from the log, best-effort rake status) with the degradation logged (FR15)

**Given** any failure
**When** the run ends
**Then** the bundle includes the recorded readiness per-service statuses plus `/health_check` failure messages, the 4-line rollback story is stated (backup path; image-revert sed; up command; unpause marked HUMAN-ACTION), and runners stay paused (FR14, FR15)

### Story 4.4: Demonstrated proof on the seeded instance

As the author,
I want the full contract demonstrated on a real instance,
So that the mentor sees proof, not assertions.

**Acceptance Criteria:**

**Given** a seeded Docker GitLab at 16.11
**When** runs execute
**Then** 2–3 real required stops advance one per run toward the current 17.x chain, each showing DONE-per-stop: 10 s heartbeats with telemetry, version match, migrations `finished`, `/health_check` success, readiness `all=1` green, and a passing `main` clone-and-push (NFR6, NFR7)

**Given** one injected failure (disk pressure or a stalled migration)
**When** it occurs
**Then** hang detection halts within the 5-minute window with actionable logs (NFR7)

**Given** the demo
**When** presenting
**Then** every line and every technology choice is explainable without notes — assessed in the demo, not in CI (NFR2)
