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

FR1: Operator obtains the next required stop with its exact pinned image: the script detects the current version from the live instance via `GET /api/v4/version` (AD-3 normalization) and prints the one-hop plan to the next required stop per the vendored `upgrade_path.yml`, resolved to an exact `X.Y.z` latest-patch tag.
FR2: Stop list comes from the vendored `upgrade_path.yml` (major.minor only) via a short grep/sed pipeline over the pinned YAML shape; anything else in the file dies; every stop is taken as a normal stop including conditional ones.
FR3: Latest-patch pin per stop via the Docker Hub tags API (`name=<major.minor>&page_size=100`, follow `next`, filter `^<M>.<m>.[0-9]+-(ce|ee).0$`, POSIX numeric patch sort, pick max); Hub failure or empty set dies with no retry or fallback.
FR4: The target note (if non-blank) is shown with the plan and acknowledged up front via the exact prompt `Type ACK <stop> to proceed:` before any pause/backup; a live run without a TTY halts with GATE=plan; each ack is logged.
FR5: Planning is gated: before resolving the target, the run asserts no leftover unfinished migrations via the rake signal and halts with GATE=plan if any remain; halt stating already-at-head when no entry follows the current version.
FR6: Read-only `--plan` mode performs any read, runs the same gated planning (dying in-format if unplannable), and prints the one-hop plan plus the fixed checklist in stable order; never requires a TTY or acknowledgement.
FR7: Pre-upgrade gate (before any container change): `/-/health` OK, `/health_check` success, no leftover unfinished migrations, rake table all `finished`, backup-contract verification passes, CI paused/drained.
FR8: Backup verification (~15 lines) against the pinned demo layout: `$BACKUP_PATH/` holds `data/`, `secrets/`, `BACKUP_CREATED_AT` (epoch seconds); fresh means `RUN_START - BACKUP_CREATED_AT <= 86400`; halt naming the missing or stale item.
FR9: CI quiet via the Runners API: enumerate `GET /runners/all?per_page=100` following `Link rel="next"`, pause each via `PUT --form paused=true` (zero is a logged no-op), drain until zero running jobs across all runners (10 s poll with heartbeat, no timeout), assert-all-paused before mutate; unpause-all only on the success path at proceed-gate step 6.
FR10: Mutate scoped to `$COMPOSE_SERVICE`: `cp` the compose file beside itself as `$F.bak-<target>-<epoch>` (kept, never auto-restored), `sed` anchored to the service stanza asserting exactly one `image:` line, `pull`, then `down` and `up -d` (never `-v`); identical tag proceeds as a logged idempotent re-run.
FR11: Health-during monitor: 10 s heartbeat log entries with runtime telemetry (Layer-0 state, `/-/health`, `/-/liveness`, `/health_check/database`, `/health_check/cache`, cpu/mem/block-IO/net-IO from one `docker stats --no-stream --format` sample) plus rake finished-count deltas; readiness excluded (expected red).
FR12: Hang verdict: 30 consecutive 10 s heartbeats with zero rake finished-count movement AND cpu integer-part zero AND block-I/O raw string unchanged halts with GATE=monitor; any finished movement resets the counter; liveness 503 or failing `/health_check/database`/`/cache` halts immediately.
FR13: Proceed gate in fixed order: (1) version match with edition re-assert, (2) rake all `finished`, (3) `/health_check` success, (4) `/-/readiness?all=1` green with per-service statuses recorded, (5) seeded-project `main` clone-and-push smoke test, (6) full health re-check then unpause-all (success path only).
FR14: Close-out on success: full Phase 1 health checks re-run, runners unpaused, jobs flowing; on failure: diagnostics bundle plus 4-line rollback story, runners left paused.
FR15: Failure bundle: fetch standalone `gitlabsos.rb` pinned to toolbox SHA `cb73cacc` at failure time, `docker cp` in and run with embedded ruby to `./failure-bundle-<target>-<epoch>/`; on fetch/run failure fall back to the native manifest (logs tail, inspect, replayed readiness/health lines, best-effort rake) with logged degradation; bundle always includes recorded readiness per-service statuses plus `/health_check` failure messages.
FR16: Channel discipline: Layer 0 (`docker compose ps` + `docker inspect`, every `compose exec` with `-T`, every curl with `--max-time`) checked first; 10-minute grace for `/-/health` after `up -d`; refused/timeout resolves through container state; unexpected 404 with Running reads allowlist-suspect; Exited halts with exit code plus log tail; every poll logs Layer-0 state alongside HTTP results.
FR17: Halt contract: one `die()` with fixed log format exiting non-zero, `die()` never mutates after detection except logs/bundle, dynamic `RUNNERS=`/`CONTAINER=` values, GATE vocabulary `validate plan pre pause mutate monitor proceed unpause closeout`, single-quoted values, `|| die` on fallible external commands, shape-assert-die on parses, never retry `up` in the down window, INT/TERM trap into `die()` with the current-phase GATE.
FR18: Config via env vars with strict startup validation (required: `GITLAB_URL GITLAB_ADMIN_TOKEN GITLAB_SMOKE_TOKEN GITLAB_COMPOSE_FILE COMPOSE_SERVICE BACKUP_PATH SEED_PROJECT_PATH`; optional with defaults: `GITLAB_IMAGE_REPO LOG_FILE UPGRADE_PATH_FILE`); normalize URL/token; exclusive `mkdir` lock first with trap release; secrets via curl `-K` file (mode 600, trap rm), never argv; token map version+runners=admin, clone=smoke, health probes=none.
FR19: JSON parsing via `jq -r` when present else `grep -oE` fallback, each probe defining its jq filter AND grep regex AND byte-identical bare output; `PARSER` detected once at startup, exported, never re-detected.

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
- Env validation order: lock first, then required-nonempty (URL scheme+host assert), then token-trim, then optional defaults, then file/dir existence (compose, YAML, backup), then edition/repo coherence.
- Hang-counter pseudocode: `flat=0`; each heartbeat: if `rake_delta>0` then `flat=0` else if cpu-int==0 and bio-string-unchanged then `flat+=1` else `flat=0`; `flat>=30` dies GATE=monitor.
- Failure-path exec lines: `docker cp /tmp/gitlabsos.rb $CID:/tmp/gitlabsos.rb`, `compose exec -T $SVC /opt/gitlab/embedded/bin/ruby /tmp/gitlabsos.rb -o /tmp/sos`, `docker cp $CID:/tmp/sos ./failure-bundle-<t>-<e>/`; any step failing falls to the native manifest.
- Probe contracts are byte-identical jq/grep pairs (version, runners list/id-paused pairs, drain `[]`, rake pipe-shape, Hub tags name/next) per BUILD-NOTES.
- Accepted residual risks: Hub legacy tags path may retire (dies loudly; namespaced `/v2/namespaces/.../tags` is the documented successor); 17.x `:status` grammar padding drift (pipe-shape assert halts, never mis-parses); host-locale telemetry string sensitivity (negligible on single-maintainer demo host).
- Out of scope (must not generate stories): backup implementation, zero-downtime/multi-node/Helm, maintenance mode, Geo/external Gitaly/Elasticsearch/K8s agents, Runner binary/container upgrades, retry/resume within a stop, troubleshooting detail beyond the failure bundle and rollback statement, archive scraping, secrets manager.

### UX Design Requirements

None — Bash CLI tool with no UI. The only operator interaction is the `Type ACK <stop> to proceed:` TTY prompt (covered by FR4).

### FR Coverage Map

### FR Coverage Map

FR1: Epic 1 - Detect current version via API, print one-hop plan to next stop
FR2: Epic 1 - Stop list from vendored YAML via grep/sed, every stop normal
FR3: Epic 1 - Latest-patch pin via Hub tags API, fail-closed
FR4: Epic 1 - Target note shown and ACKed up front before any change
FR5: Epic 1 - Gated planning: leftover-migration assert, already-at-head halt
FR6: Epic 1 - Read-only --plan mode with fixed checklist
FR7: Epic 2 - Pre-upgrade health gate before any container change
FR8: Epic 2 - Backup-contract verification (~15 lines)
FR9: Epic 2 - CI quiet via Runners API (pause, drain, assert)
FR10: Epic 3 - Mutate: compose backup, sed pin, pull, down/up
FR11: Epic 3 - Health-during monitor: heartbeat telemetry + rake deltas
FR12: Epic 3 - Hang verdict: 5-minute flat window halts, backends halt fast
FR13: Epic 4 - Proceed gate: ordered 6-step proof of done + unpause
FR14: Epic 4 - Close-out: re-check on success, bundle + rollback story on failure
FR15: Epic 4 - Failure bundle: pinned gitlabsos fetch with native fallback
FR16: Epic 1 - Layer-0-first channel discipline and probe library
FR17: Epic 1 - Halt contract: die(), log format, GATE vocabulary, traps
FR18: Epic 1 - Env-var config, strict startup validation, lock, secret handling
FR19: Epic 1 - jq with grep fallback, byte-identical probe outputs

## Epic List

### Epic 1: Safe Upgrade Planning

The operator can validate the environment and preview the exact one-stop upgrade plan (current → pinned target) without changing anything, and the script refuses to plan an unsafe or unplannable run.
**FRs covered:** FR1, FR2, FR3, FR4, FR5, FR6, FR16, FR17, FR18, FR19

### Epic 2: Pre-Upgrade Protection

The runner verifies the instance is healthy, backed up, and quiet before touching it — a sick, unbacked-up, or busy instance is never upgraded.
**FRs covered:** FR7, FR8, FR9

### Epic 3: One-Stop Upgrade with Hang-Aware Monitoring

The runner advances the instance exactly one required stop and watches the migration wait with heartbeats and progress deltas, halting on hang instead of waiting silently.
**FRs covered:** FR10, FR11, FR12

### Epic 4: Proof of Done and Close-Out

The runner proves the stop is complete through the ordered proceed gate, resumes CI only on success, and closes every run out with re-verified health or a diagnostics bundle plus rollback story.
**FRs covered:** FR13, FR14, FR15

## Epic 1: Safe Upgrade Planning

The operator can validate the environment and preview the exact one-stop upgrade plan (current → pinned target) without changing anything, and the script refuses to plan an unsafe or unplannable run.

### Story 1.1: Loud, consistent halts with actionable log lines

As an operator,
I want every failure to halt the run with one clear log line,
So that I always know what failed, where, and what to do next.

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

### Story 1.2: Strict startup configuration and single-run lock

As an operator,
I want the script to reject bad or missing configuration before doing anything,
So that a typo never causes a half-upgraded instance.

**Acceptance Criteria:**

**Given** any required env var (`GITLAB_URL GITLAB_ADMIN_TOKEN GITLAB_SMOKE_TOKEN GITLAB_COMPOSE_FILE COMPOSE_SERVICE BACKUP_PATH SEED_PROJECT_PATH`) is missing or empty
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

### Story 1.4: Current version detection and next-stop lookup

As an operator,
I want the script to find my exact current version and the single next required stop,
So that no required stop is ever skipped.

**Acceptance Criteria:**

**Given** a running instance
**When** version detection runs
**Then** the current version comes from `GET /api/v4/version` with the admin token, both sides normalized (tag minus `-(ce|ee).0`, API value minus optional `-(ce|ee)`) and compared with exact equality; expected edition derives from the `GITLAB_IMAGE_REPO` basename (`gitlab-ce` false, `gitlab-ee` true, anything else dies) (FR1)

**Given** the vendored `upgrade_path.yml`
**When** extraction runs
**Then** a short grep/sed pipeline reads `major:`/`minor:` pairs with each optional `comments:` kept next to its stop; anything else in the file dies; the file carries a source-URL + fetch-date header (FR2)

**Given** the detected current version
**When** lookup runs
**Then** the single next entry is selected with every stop taken as a normal stop (no conditional-stop logic); no following entry halts stating already-at-head (FR2, FR5)

**Given** planning starts
**When** the leftover check runs
**Then** any unfinished migrations via the rake signal halt with GATE=plan before the target is resolved (FR5)

### Story 1.5: Latest-patch pin via Hub tags API

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
**Then** the target is an exact `X.Y.z` tag resolvable to a published image (FR1, FR3)

### Story 1.6: Plan print, note acknowledgement, and read-only --plan

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
**Then** only reads execute with the same gated planning (dying in-format if unplannable), printing the one-hop plan plus the fixed checklist in stable order; it needs only URL+repo+compose+YAML+admin token (FR6)

## Epic 2: Pre-Upgrade Protection

The runner verifies the instance is healthy, backed up, and quiet before touching it — a sick, unbacked-up, or busy instance is never upgraded.

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
**Then** the script polls every 10 s with heartbeat until zero running jobs across all runners, with no timeout; it dies only on query failure (FR9)

**Given** draining completes
**When** the assert runs
**Then** all-paused is asserted before mutate; unpause-all happens only at proceed-gate step 6 on the success path; the log notes pre-existing paused runners also resume (FR9)

### Story 2.3: Pre-upgrade health gate

As an operator,
I want the full pre-upgrade gate enforced before any container change,
So that a sick instance is never upgraded.

**Acceptance Criteria:**

**Given** the gate runs
**When** checks execute
**Then** all must hold: `/-/health` returns `GitLab OK`, `/health_check` reports `success` (failure message logged), no leftover unfinished migrations, the rake table shows all `finished`, backup verification passes, and CI is paused and drained (FR7)

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
**Then** the full Phase 1 health checks re-run, runners are unpaused, and jobs flowing is confirmed (FR14)

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
