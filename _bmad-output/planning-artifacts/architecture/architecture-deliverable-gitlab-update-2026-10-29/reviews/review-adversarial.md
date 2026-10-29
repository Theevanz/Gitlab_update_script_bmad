# Adversarial Review — Architecture Spine (GitLab Stepwise Upgrade Runner)

- **Spine:** `_bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md`
- **Date:** 2026-10-29
- **Role:** adversarial reviewer
- **Method:** for each hole, construct Unit A and Unit B that both obey every AD to the letter yet build incompatibly. Every such pair is a hole. Each finding ends with a concrete AD fix (new or tightened).
- **Verdict:** FIX (do not build on this spine as-is; 2 critical + several high-severity holes)

## Summary of findings

| ID | Severity | Hole | ADs to change |
|----|----------|------|---------------|
| F-1 | Critical | Re-run after partial success skips the finished-migrations wait | Tighten AD-2, AD-10; fix plan/pre-gate order |
| F-2 | Critical | Failure close-out: AD-8 frozen vs AD-13 unpause-all contradiction | Tighten AD-8, AD-13 |
| F-3 | High | Spine vs SPEC contradictions: maintenance mode; down/up vs pull/up | Resolve in AD-9 + Deferred + map |
| F-4 | High | Pinned-tag resolution unpinned (pagination, sort, suffix, edition) | New AD-14 (pin algorithm) + tighten AD-3 |
| F-5 | High | --plan vs live-run divergence (reads allowed, binding, env, TTY) | Tighten AD-11 |
| F-6 | High | Halt posture undefined by phase; down-window; partial pause; GATE vocabulary | Tighten AD-8 |
| F-7 | High | Pause-vs-pre-gate order; two owners of CI-paused and leftover-migration checks | Tighten AD-13, AD-10 + paradigm order |
| F-8 | High | Env required-vs-optional + normalization undefined | Tighten AD-6 |
| F-9 | High | Log envelope + heartbeat fields/units unpinned; LOG_FILE target paradox | Tighten conventions into AD-8/AD-10 |
| F-10 | Medium | Note-ack UX unpinned (prompt shape, timing, no-TTY vs --plan, empty notes) | Tighten AD-5 |
| F-11 | Medium | Runners pagination + drain query + timeout unpinned | Tighten AD-13 |
| F-12 | Medium | jq/grep fallback output shapes diverge; hang-delta source conflict (rake vs /health_check/migrations) | Tighten conventions + AD-10 |
| F-13 | Medium | Compose sed scope + backup path + pull/down/up blast radius | Tighten AD-9 |
| F-14 | Medium | Backup layout + timestamp source + run-start definition | New convention or AD-15 |
| F-15 | Medium | Bundle invocation + output path + rollback-story shape | Tighten AD-12 |
| F-16 | Low-Med | Secret handling: PRIVATE-TOKEN in argv, token→call map, set -x | Tighten AD-6/conventions |

---

## F-1 — Critical: re-run after partial success skips the migration wait

**ADs:** AD-2 (letter), AD-10 (scope), paradigm order.

**Letter of AD-2:** "each run advances exactly the next required stop after the detected current version."

**Unit A (naive planner, compliant):**
```bash
current="$(api_version)"          # e.g. 17.1.0 after previous run's up -d succeeded
target="$(next_stop_after "$current")"  # plans 17.2
# proceed directly to pause/mutate for 17.2
```
**Unit B (cautious planner, compliant):**
```bash
current="$(api_version)"
assert_migrations_finished        # rake all finished BEFORE planning next stop
target="$(next_stop_after "$current")"
```
Both obey AD-2: both advance exactly the next stop after detected current. AD-10 binds only CAP-4/CAP-5 (monitor + proceed), not planning, so A claims no rule forces a pre-plan migration check. B adds one voluntarily.

**Incompatibility:** consider a run that did `up -d` to 17.1, then halted during monitor (operator Ctrl-C, hang false-positive, host reboot). Container now reports 17.1 with migrations unfinished. Re-run under A plans 17.2 and starts mutating — two stops without a finished wait between them, exactly the schema-corruption sequence the SPEC exists to prevent. Under B the re-run halts safely on leftover migrations.

**Demo exploit:** kill the runner mid-wait at stop 1, re-run. A jumps to stop 2; B halts. Same spine, opposite safety outcomes.

**Fix (tighten AD-2 + AD-10):**
- AD-2 add: "Planning is gated: before resolving next-stop, the run asserts leftover migrations finished (same rake signal as AD-10) and halts with GATE=pre if unfinished. Detected-current advancing never skips an unfinished stop."
- AD-10 scope: explicitly include the pre-plan leftover check as the same single source (not CAP-4/5 only).
- Paradigm order: insert `leftover-check` before `plan` resolves target (or as first pre-gate item that runs before note-ack/pause).

---

## F-2 — Critical: failure close-out unpauses a broken instance (AD-8 vs AD-13)

**ADs:** AD-8 ("halted instance stays frozen as-at-detection (runners paused, container untouched)"), AD-13 ("close-out unpauses ALL runners"), CAP-6 map ("close-out phase (re-check or diagnostics bundle + rollback story)" governed by AD-12, AD-13).

**Unit A (frozen-wins, compliant):** reads AD-13 as success-path-only. Failure path: `die()` → bundle → exit, runners left paused.
**Unit B (literal close-out, compliant):** reads "close-out unpauses ALL" + "close-out phase (re-check **or** bundle)" as covering both paths. Failure path: bundle → unpause-all → exit. Cites AD-8 parenthetical as describing the moment of detection, not the end of close-out.

Both cite spine text verbatim. The spine never says "success-only" or "failure leaves paused."

**Incompatibility:** same failed run: A leaves CI quiet on a sick instance (safe, matches SPEC intent); B resumes all runners including pre-existing paused ones onto a broken GitLab, flooding it with jobs during diagnosis. Opposite CI states, opposite blast radius.

**Fix (tighten AD-8 + AD-13):**
- AD-13 add: "Unpause-all runs ONLY on the success path after the proceed gate passes. The failure path never unpauses; runners stay as-at-detection."
- AD-8 add: posture matrix (see F-6) with explicit `RUNNERS=` value on every halt, and "failure close-out does not alter runner or container state except writing logs/bundle."

---

## F-3 — High: spine contradicts SPEC on maintenance mode and on down/up

Two direct authority conflicts; two implementers following different sources both claim compliance.

### F-3a Maintenance mode

- SPEC Constraints: "Script enables maintenance mode at the start of every stop and disables it after the proceed-gate passes."
- health-gates.md proceed step 6: "unpause CI and turn off maintenance mode (mode is ON for every stop, script-controlled)."
- Spine Deferred: "Maintenance mode (Premium+; Free-tier demo quiesces via downtime + paused CI + recreation)."

**Unit A** implements maintenance mode per SPEC. **Unit B** skips it per spine Deferred. If A is right, the spine is missing a phase step (where? before pause? after? who owns on/off? what API/file? what if Free tier rejects it — halt or warn?). If B is right, the spine silently overrides SPEC with no waiver recorded.

**Fix:** decide and record. Either (i) adopt maintenance-mode AD with exact on/off points + Free-tier behavior + halt semantics, or (ii) keep deferred with an explicit SPEC-waiver note ("SPEC constraint X overridden because Free-tier demo; SPEC to be amended"). Silence is not a decision.

### F-3b pull/up vs down/up

- upgrade-procedure.md Phase 2 step 3: "`docker compose pull && docker compose up -d`" (no `down`).
- AD-9: "`docker compose pull`, then `down` and `up -d`."

**Unit A** follows SPEC (pull + up -d only: recreates changed service, preserves project networks/other services). **Unit B** follows AD-9 (full `down`: tears down every service in the file including co-located postgres/runner, then up). Downtime, blast radius, and Layer-0 behavior diverge; the halt-during-down-window case (F-6) exists only under B.

**Fix:** tighten AD-9 to name exact commands with service scoping, e.g. `pull "$COMPOSE_SERVICE"`, `up -d "$COMPOSE_SERVICE"` with or without preceding `down`, and reconcile the SPEC sentence (amend one or the other; do not leave both).

---

## F-4 — High: pinned-tag resolution is referenced but never pinned

The map says plan phase does "extract, pin via Hub API, print, note ack" but no AD defines the pin algorithm. AD-3 covers only comparison stripping; AD-4 covers only YAML extraction. Everything between is folklore.

**Unit A (page-1 lexicographic, compliant):**
```bash
tags="$(curl "$HUB/tags?page_size=100" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-ce\.0')"
latest="$(printf '%s\n' $tags | sort | tail -1)"   # lexicographic: 17.3.10 < 17.3.9
```
**Unit B (paginated version-sort, compliant):**
```bash
# follow ?page= until next==null, filter ^X\.Y\.[0-9]+-(ce|ee)\.0$, sort -V, tail -1
```
Both "pin via Hub API." A picks a stale/wrong patch when the stop has ≥10 patches or >100 tags; B picks correctly. Same YAML, different pinned tags, different images pulled.

**Suffix handling:** AD-3 "stripping the `-ce.0`/`-ee.0` tag suffix."
- A: `sed 's/-ce\.0$//'` (CE-only; EE tag never strips → version-match gate always fails on EE).
- B: `sed -E 's/-(ce|ee)\.[0-9]+$//'` (strips -ce.1 too).
Both match the sentence. EE behavior and future fourth-component tags diverge.

**Edition derivation:** AD-3 "startup asserts the API `enterprise` flag matches the expected edition" — expected edition is never sourced.
- A derives from `GITLAB_IMAGE_REPO` suffix (`*-ee` → expect true).
- B hardcodes `false` (demo is CE).
Override repo to `gitlab/gitlab-ee`: A passes, B dies. Both compliant.

**Hub failure / rate-limit:** no rule. A dies; B retries 3× then dies; C (greedy) falls back to "keep tag suffix on minor" and proceeds unpinned. All letter-compliant; C silently floats versions, violating CAP-1 intent while obeying every AD.

**Fix (new AD-14 — pin algorithm, + tighten AD-3):**
- Endpoint + pagination (follow `next` until null), tag regex `^<major>\.<minor>\.[0-9]+-(ce|ee)\.0$`, numeric `sort -V`, pick max; Hub failure/empty-set always dies (no fallback tags).
- Suffix strip regex (exact, e.g. `s/-(ce|ee)\.0$//`), applied to tag side; comparison is exact string equality post-strip.
- Expected edition derived from `GITLAB_IMAGE_REPO` basename suffix (`gitlab-ce`→false, `gitlab-ee`→true; anything else dies); assert at startup AND at proceed-gate (catch edition flip from a wrong pull).

---

## F-5 — High: --plan vs live-run divergence (AD-11 "without touching anything")

AD-11: "read-only `--plan` mode printing the one-hop plan (current → target, pinned tag, note) and gate checklist without touching anything."

**Pair 1 — reads allowed:** A reads "touching" strictly (no network at all): parses version from compose `image:` line. B reads "touching" as mutate-only: calls version API + Hub API. After a manual compose edit, A prints stale current→target while B prints live truth. Worse, A's compose-derived version directly violates AD-3 — the spine forces A to pick which AD to break. Both readings are defensible from one vague word.

**Pair 2 — binding:** Hub publishes a new patch between `--plan` and the live run. A treats plan output as advisory and re-resolves live (live tag ≠ planned tag; the operator-approved note/tag drift). B treats `--plan` as binding and reuses the printed tag (stale patch, but matches what was reviewed). No AD says which. Version-match gate input differs.

**Pair 3 — env/TTY:** A runs full AD-6 strict validation + AD-5 no-TTY halt in `--plan` (CI `plan` with no TTY and no admin token dies — useless for audit). B exempts `--plan` from tokens/TTY (needs only URL+YAML). Same CI job passes on B, dies on A.

**Pair 4 — checklist contents:** A prints pre-gate items only; B prints pre + proceed + close-out. Both satisfy "gate checklist."

**Fix (tighten AD-11):**
- Allow-list `--plan` reads: version API yes, Hub API yes, YAML yes; health probes / runners list / rake: no (or explicitly yes — pick one).
- Binding rule: live run re-resolves and MUST equal `--plan` output or halt with GATE=plan-drift (or: plan is advisory and live always re-resolves — pick one; recommend halt-on-drift for auditability).
- Env subset for `--plan` (URL + repo + compose path + YAML; tokens required only if version API needs them — state it), `--plan` never requires TTY, exit codes (0 plan-ok; non-zero with same die format on unplannable).
- Checklist = exact item list (pre-gate 6 + proceed 6 + close-out 2, by name), stable order for diffing.

---

## F-6 — High: halt posture undefined by phase; GATE vocabulary open

AD-8: "the halted instance stays frozen as-at-detection (runners paused, container untouched) with the posture stated in the log."

**Pair 1 — halt before pause:** validate/plan/pre-gate halts happen with runners NOT paused. A logs dynamic posture (`RUNNERS=unpaused CONTAINER=untouched`); B logs the AD-8 parenthetical literally ("runners paused, container untouched") — a lie in the audit log. The parenthetical reads as mandate to B, example to A.

**Pair 2 — halt in the down/up window (exists under AD-9's `down`):** script took the container down, `up -d` fails. "Container untouched" is false — the script itself did it. A leaves it down, logs `CONTAINER=down-by-script`; B retries `up -d` once, calling it "completing the interrupted primitive, not remediation." B's retry is remediation-shaped; A's extended downtime surprises. Both claim AD-8 ("frozen" vs "no auto-remediation" tension, unresolved).

**Pair 3 — partial pause:** pause loop dies on runner 3 of 5. Posture is mixed. A leaves mixed frozen; B unpauses-all "to restore known state." Same failure, opposite CI states (see also F-2).

**Pair 4 — GATE vocabulary:** AD-8 mandates `GATE=` but never enumerates values. A emits `GATE=pre-gate`; B emits `GATE=pre`. Forensic `grep GATE=pre` misses half the halts. Same for EXPECTED/OBSERVED quoting: OBSERVED containing spaces/newlines breaks naive `VAR=...` grepping; no escaping rule.

**Pair 5 — "explicit `|| die` on every fallible call":** `grep -oE` returns 1 on no-match — fallible (die) or expected-empty (shape-assert next)? A writes `ver=$(... | grep -oE '...' || die ...)` → false halts inside pipelines; B writes `... || true` + explicit shape assert. Both obey "fallible" because the word is undefined. Same input, one halts, one proceeds.

**Fix (tighten AD-8):**
- Posture matrix by phase: before-pause / paused-pre-mutate / down-window / up-post-mutate, each with mandated `RUNNERS=` + `CONTAINER=` values; posture fields dynamic, never literal.
- Down-window rule: never retry `up` on failure (leave down, log exit code + tail); state it.
- Partial pause: halt leaves as-is, log lists paused-vs-unpaused runner IDs; failure path never unpauses (tie to F-2).
- Enumerate GATE values (`validate plan pre pause mutate monitor proceed unpause closeout`) and quoting rule (single-quote values, `%20`-escape or JSON-string — pick one).
- Define fallible: process-exit-nonzero on external commands (curl/docker/compose/rake/git) gets `|| die`; in-pipeline search/parse (grep/sed/jq-filter-no-match) uses `|| true` + explicit shape-assert-die. Ban bare `cmd | grep` under `pipefail` without the pattern.

---

## F-7 — High: pause-vs-pre-gate order; two owners of CI-paused and leftover checks

Paradigm order: `... → G1[pre-upgrade gate] → Q[pause runners + drain] → M[mutate]`. But the CAP map says pre-gate phase covers "health + backup contract + CI paused," and health-gates.md pre-upgrade gate lists "CI/CD paused: runners paused, new jobs blocked, running jobs finished" under "All must hold."

**Unit A (map/spec reading):** pre-gate asserts CI paused → must pause BEFORE G1: order validate→plan→pause→pre-gate→mutate. First-ever run halts (runners start unpaused) unless pause precedes the gate — so A reorders phases against the paradigm diagram, citing the map.
**Unit B (diagram reading):** order G1→Q; G1 checks health+backup only, Q pauses and self-checks. The "CI paused" line in the map is read as "the pause step lives nearby."

Both obey every AD (AD-13 only says "before any container change"). Consequences: A's G1 GATE=pre failures include not-paused (operator confusion: "I haven't paused yet, that's the script's job"); B has two check sites for pausedness (Q's self-check + nothing in G1) so a pause that silently under-pauses (pagination bug, F-11) is never re-verified before mutate.

Same split for leftover migrations: health-gates.md pre-gate requires "no leftover unfinished" + "batched all finished"; AD-10 binds CAP-4/5 only.
- A uses rake in pre-gate (same owner as proceed).
- B uses `/health_check/migrations` only in pre-gate (argues AD-10 doesn't bind CAP-2).
Same leftover instance: different signals, different halt messages, possible miss.

**Fix:**
- Single order in paradigm + map (recommend: validate→plan→pre-gate(health+backup+leftover, NO pausedness)→pause+drain→paused-assert→mutate). State that CI-paused is asserted exactly once, by the pause step, after draining, immediately before mutate.
- AD-10 scope: explicitly cover pre-gate leftover + pre-plan check (F-1) with the same rake signal. One owner (rake table) for all three sites.

---

## F-8 — High: env required-vs-optional + normalization undefined

AD-6: "all configuration arrives as environment variables; a startup validation block names every missing/empty variable and halts before any action." Conventions list 9 vars with one explicit default (`GITLAB_IMAGE_REPO` → `gitlab/gitlab-ce`) and one implied (`LOG_FILE` → `./upgrade-<target>.log`).

**Pair 1 — required set:** A treats all 9 as required (dies if `LOG_FILE` or `GITLAB_IMAGE_REPO` unset, reading "every missing" literally). B treats the two with documented defaults as optional. Same env: A dies, B runs.

**Pair 2 — normalization:** `GITLAB_URL=https://host/` (trailing slash). A concatenates `$URL/api/v4/version` → double slash (works or 404 by server); B strips trailing `/`. Token with trailing newline (copied from UI): A uses raw (auth fails, halt blames GitLab); B trims whitespace. Empty-string-with-default (`GITLAB_IMAGE_REPO=""`): dies as empty, or falls back to default? Both readings fit "missing/empty."

**Pair 3 — unknown vars / tunable constants:** timeouts (10 min grace, 10 s heartbeat, 5 min hang) — hardcoded literals or env? AD-6 "all configuration arrives as env" suggests env, but they're absent from the list. A hardcodes; B invents `HANG_WINDOW_S` etc. A's strict validator either ignores B's extras (open set) or dies on them (closed set) — unspecified either way.

**Fix (tighten AD-6):**
- Closed table: each var required|optional+default, in one place. Reconcile LOG_FILE default (see F-9 target paradox — default likely must not contain `<target>`).
- Normalization rules: strip trailing `/` from URL (die if result lacks scheme/host), trim leading/trailing whitespace on tokens (or die on embedded whitespace — pick), empty ≡ unset for optional (default applies), empty ≡ missing for required (die).
- Constants vs env: name the three timeouts as literals (recommend: literals, not env, for presentability) and state the env set is closed (unknown `GITLAB_*` vars warn, not die — pick and state).

---

## F-9 — High: log envelope + heartbeat fields/units unpinned; LOG_FILE target paradox

Conventions: "ISO-8601 timestamps, `phase=` + gate prefix per line, `die()` lines carry `GATE= EXPECTED= OBSERVED= ACTION=`; heartbeat one terse line per 10 s with elapsed runtime, `/-/health` + `/-/liveness` results, container telemetry, progress deltas."

**Pair 1 — envelope:** A emits `2026-10-29T12:00:00+00:00 phase=monitor [proceed?] msg...`; B emits `2026-10-29 12:00:00 phase=monitor GATE=monitor ...`. "Gate prefix" is never exemplified — bracket tag or GATE field? Timestamp local vs UTC (`date --iso-8601=seconds` vs `date -u +%FT%TZ`) — correlation with 24 h backup freshness and elapsed math diverges by timezone.

**Pair 2 — heartbeat fields:** A: `elapsed=123s health=OK liveness=200 cpu_pct=12 mem=812MiB/4GiB bio=1.2GB/3.4GB net=12MB/8MB pending=4`. B: `t=02:03 H='GitLab OK' L=ok cpu=0.12 mem=851M io_flat=true`. Both contain "elapsed, health, liveness, telemetry, deltas" per the sentence. No consumer (human grep, hang verdict, mentor demo) can rely on either. Units (s vs mm:ss, % vs fraction, raw counters vs rates), order, quoting, and delta encoding (absolute pending count? diff since last? rake digest?) all vary. The hang verdict (F-12) parsed from these lines disagrees across A/B.

**Pair 3 — LOG_FILE target paradox:** default `./upgrade-<target>.log` needs `<target>`, known only after plan resolution. Early lines (validate, version detect, YAML extract) predate it. A opens `./upgrade-unknown.log`, then switches to the target file mid-run (audit trail split across two files; "single append-only file" violated in spirit). B buffers early lines and flushes after plan (a crash before flush loses the validate failure — the exact lines needed for diagnosis). C ignores the default and uses fixed `./upgrade.log` (single chain file across re-runs, but contradicts the default). All three defensible; pick one in the spine.

**Fix (promote conventions into AD text):**
- Exact envelopes, e.g. `<UTC ISO-8601> phase=<phase> msg="<...>"` and die: `<ts> phase=<phase> GATE=<vocab> EXPECTED='<..>' OBSERVED='<..>' ACTION='<..>' RUNNERS=<..> CONTAINER=<..>` with quoting rule from F-6.
- Heartbeat schema: ordered field list with units, e.g. `hb elapsed_s=<int> health=<OK|FAIL:code> liveness=<200|503|REFUSED> cpu_pct=<float> mem_mib=<int> mem_lim_mib=<int> bio_r_mib=<int> bio_w_mib=<int> net_r_mib=<int> net_w_mib=<int> rake_pending=<int> rake_delta=<signed int since last hb>`. One line, fixed order, machine-greppable.
- LOG_FILE: resolve once at startup to a target-free default (recommend `./upgrade-gitlab.log`, append across re-runs; target recorded per-line via `target=` field), overridable by env. Kill the `<target>` default.

---

## F-10 — Medium: note-ack UX unpinned (AD-5)

AD-5: "the target's `comments:` note, if any, is shown with the plan print and must be operator-acknowledged before any container change in that run; acknowledgement (stop, note text, timestamp) is logged; halt if no TTY; `--plan` mode displays notes without requiring acknowledgement."

**Pair 1 — prompt shape:** A: `read -rp 'Acknowledge 17.1 note? [y/N] '` accepts `y`. B: requires typing `ACK 17.1`. Both are "operator-acknowledged." Automation/expect scripts and mentor-demo instructions diverge; B's strictness blocks A-trained operators.

**Pair 2 — timing:** "before any container change" — is `cp` backup a container change? Is runner pause? A prompts at end of plan phase (decline leaves zero side effects). B prompts just before `sed` (decline/Ctrl-C leaves runners paused + backup file written — a different halt posture, cf. F-6). Both are "before any container change."

**Pair 3 — no-TTY vs --plan:** A halts on no-TTY even in `--plan` (reads "halt if no TTY" absolutely). B exempts `--plan` (reads the `--plan` sentence as carve-out). CI `--plan` audit job passes on B, dies on A.

**Pair 4 — empty/missing notes:** stop with no `comments:` key vs `comments: ""`. A prompts for every stop regardless ("ack the stop"); B skips prompting when no note text. First-run UX diverges; A's log has ack rows for noteless stops, B's doesn't.

**Fix (tighten AD-5):**
- Exact prompt (`Type ACK <stop> to proceed:`), exact match, no timeout, Ctrl-C/EOF = halt with GATE=plan; ack happens in plan phase before pause/backup (decline = zero side effects).
- No-TTY rule: live run halts when ack required AND stdin is not a TTY; `--plan` never requires ack and never needs TTY.
- Ack required iff non-blank note text; log `ack stop=<s> at=<ts> note_sha=<8> note="<first 200 chars>"` (hash covers full text, keeps one line).

---

## F-11 — Medium: runners pagination + drain query + timeout (AD-13)

AD-13: "pause via `PUT /runners/:id` with `paused=true` and drain-check via jobs query before any container change; close-out unpauses ALL runners (zero registered is a logged no-op)."

**Pair 1 — pagination:** A lists `GET /runners?per_page=20` page 1 only. B follows `X-Next-Page` to exhaustion. Instance with 25 runners: A pauses 20, declares done — 5 runners keep taking jobs through the upgrade (safety hole: jobs writing during migration wait). Both obey the AD sentence.

**Pair 2 — drain query:** A polls `/api/v4/jobs?scope=running`; B polls `scope=running,pending`. A declares drained while pending jobs wait to start (they won't start once paused — but "running jobs finished" vs "blocked new" semantics differ); also project-vs-global scope, per_page, and which states count as busy are unstated.

**Pair 3 — drain timeout:** A waits forever (long job hangs the run overnight); B waits 10 min then dies (long job halts the upgrade). Both "drain-check before any container change."

**Pair 4 — unpause-all enumeration:** same pagination hole on the unpause path: A unpauses page 1 only, leaving 5 runners paused forever with "close-out complete" logged.

**Fix (tighten AD-13):**
- List contract: `GET /runners?per_page=100` + follow `X-Next-Page`; log count + IDs paused/unpaused; zero = logged no-op.
- Drain contract: query, scopes, poll interval (10 s with heartbeat), timeout (recommend: none/literal wait with heartbeat, die only on query failure — or explicit timeout; pick one), and definition of drained (`running==0`; pending allowed only if all runners already paused — state it).
- Unpause path uses the same enumeration; log per-runner result.

---

## F-12 — Medium: parser shapes diverge; hang-delta source conflict

### Parser shapes

Conventions: "`jq -r` when present else `grep -oE` fallback, detected once at startup, logged, used uniformly; every parse asserts shape first and dies on unexpected shape."

**Unit A (jq host):** `version=$(curl ... | jq -r .version)` → `17.3.7`. **Unit B (grep host):** `version=$(curl ... | grep -oE '"version":"[^"]+"')` → `"version":"17.3.7"` (key + quotes included). A downstream strip/compare written against A's shape fails on B's (or vice versa). Both use the mandated tool preference; the AD pins the tool, not the output contract. Same script behaves differently on jq vs non-jq hosts — the demo host has jq 1.8.1, the mentor's laptop may not.

Also "detected once" vs per-call: A snapshots `PARSER` at startup; B re-checks `command -v jq` per call. `jq` installed mid-run (unlikely but legal): A stays grep, B flips mid-run, shapes change mid-run.

**Fix:** per-probe canonical contract: each probe defines its jq filter AND its grep regex AND the exact expected output string (e.g. `X.Y.z` bare, no quotes/key), plus a shared `norm()` (trim quotes/space). Assert output shape, not just input shape. Detect once, export `PARSER`, never re-detect.

### Hang-delta source conflict

- AD-10: "rake table is the single source for both the proceed-gate verdict and heartbeat progress deltas."
- health-gates.md health-during table: "`/health_check/migrations` | Tracked over time | Migration sub-check movement feeds the progress-delta signal."

**Unit A** (AD-10 literal): deltas = rake pending-count diff only; `/health_check/migrations` text change does not reset the 5-min timer. **Unit B** (spec table literal): either signal moving resets the timer. A stalled-rake-but-flapping-subcheck run: A halts hung, B waits forever. Both cite authority.

Related: "no movement for 5 minutes" — 30 consecutive flat heartbeats? Sliding window? What about a single blip? CPU "near-zero" threshold (1%? 5%?), I/O "flat" (byte-identical counters? within noise?). A uses exact-equality on counters; B allows ±1%. Same telemetry, different verdicts.

**Fix (tighten AD-10):**
- Deltas = rake pending-count diff per heartbeat ONLY; `/health_check/migrations` is observed+logged, never resets the timer. Resolve the spec-table sentence (amend health-gates.md).
- Hang rule exact: `N=30` consecutive heartbeats with `rake_delta==0` AND `cpu_pct < 2` AND block-I/O counters unchanged → halt GATE=monitor. Any nonzero delta resets counter to 0. State thresholds as literals.

---

## F-13 — Medium: compose sed scope + backup path + blast radius (AD-9)

AD-9: "`cp` a timestamped backup of the compose file (kept, never auto-restored), `sed` the `image:` line to the exact pinned tag, `docker compose pull`, then `down` and `up -d` (never `-v`)."

**Pair 1 — which image line:** compose file with `gitlab:`, `runner:`, `postgres:` services, each with `image:`. A runs `sed -i "s|image: .*|image: $REPO:$TAG|" file` (first/all matches — rewrites runner/postgres lines too, bricking them). B scopes to the `COMPOSE_SERVICE` block (awk range or yq-less stanza edit). Both "sed the image: line." Multi-service demo files break under A.

**Pair 2 — backup path:** convention names `docker-compose.yml.bak-<target>-<timestamp>` (relative, fixed basename) while source is `$GITLAB_COMPOSE_FILE` (absolute, arbitrary name). A writes `$GITLAB_COMPOSE_FILE.bak-$target-$ts` (beside original); B writes `./docker-compose.yml.bak-...` (cwd). Operator told "backups are beside the compose file" finds nothing under B and vice versa. Timestamp format (epoch vs `%FT%T` with colons — illegal on some filesystems) also unstated.

**Pair 3 — pull/down/up scope:** A runs bare `compose pull` / `compose down` / `compose up -d` (whole project: bounces postgres+runner, slow pull of unrelated images). B scopes every command to `$COMPOSE_SERVICE`. Downtime and risk diverge; combined with F-3b (down vs no-down), four distinct mutate behaviors all claim AD-9.

**Fix (tighten AD-9):**
- Scope: every compose command takes `"$COMPOSE_SERVICE"`; sed anchored to the service stanza (state the stanza-location method, e.g. awk `/^  $SERVICE:/,/^  [a-z]/` — or mandate single-service demo file and assert exactly one `image:` line, dying otherwise; recommend the latter for presentability).
- Backup: `cp "$FILE" "$FILE.bak-<target>-<epoch>"` beside original; epoch timestamp; log path; assert pre-image differs from target (no-op sed still proceeds to pull/up — state it).
- Reconcile F-3b down-vs-up here with exact command list.

---

## F-14 — Medium: backup layout + timestamp source + run-start (contract gap)

backup-contract.md: "snapshots plus secrets/config copies at a known path. A timestamp on the artifact." Consumer: "expected snapshot and secrets/config copies exist at the known path; timestamp within 24 hours of run start."

**Unit A:** `$BACKUP_PATH/gitlab-backup-*.tar` + `$BACKUP_PATH/secrets/` exist; freshness = newest tar mtime vs `RUN_START`. **Unit B:** `$BACKUP_PATH/manifest.json` with `{"created_at": "<iso>"}`; freshness = field parse. Same hand-made demo backup passes A, dies on B ("manifest missing"). Both "verify the contract."

**Run-start:** captured when? A snapshots `RUN_START=$(date +%s)` at script entry; B at pre-gate entry. Operator dwelling 40 min at note-ack: A's window is 40 min more lenient. A backup 23.5 h old passes under A, fails under B.

**Fix (new AD-15 or tightened convention):** pin demo layout exactly (paths relative to `$BACKUP_PATH`, e.g. `data/` + `secrets/` + `BACKUP_CREATED_AT` file containing epoch), freshness = `RUN_START - created_at <= 86400`, `RUN_START` captured as the first statement of the script (before validation), logged. ~15-line reference check in the spine appendix.

---

## F-15 — Medium: bundle invocation + output path + rollback story (AD-12)

AD-12: "fetch standalone `gitlabsos.rb` from the toolbox repo via curl at failure time and run it with an explicit `-o` output path; on fetch failure fall back to a native-only bundle."

**Pair 1 — how to run:** A: `ruby /tmp/gitlabsos.rb -o /tmp/sos-$ts/` on the host (fails: ruby/gitlab env absent on host). B: `docker compose exec -T $SERVICE ruby /tmp/gitlabsos.rb -o ...` (needs the file inside the container — cp first? unstated). C: `gitlab-rake gitlab:sos` (different tool entirely). All "run it."

**Pair 2 — output path:** A: `/tmp/gitlabsos-<target>-<ts>.tar.gz`; B: `./diagnostics/<ts>/`; C: `$BACKUP_PATH/sos-...`. Operator/mentor told "the bundle is at X" finds nothing under the other two. `-o` file-vs-dir (tool expects dir?) unstated.

**Pair 3 — fallback contents:** "compose logs, inspect, recorded probe statuses, migration table" — how many log lines? Which service? Probe statuses from where (re-probe a dead instance, or replay log lines)? A re-probes (refused-connections against dead container, slow); B replays recorded log excerpts. Bundle contents diverge.

**Pair 4 — rollback story:** "states the rollback story." A logs one line (`rollback: restore $BACKUP_PATH then up -d`); B prints a multi-line runbook (sed revert command, pull, up -d, unpause). Audit completeness diverges.

**Fix (tighten AD-12):** exact fetch URL (pinned tag/commit, not main), checksum assert or die-to-fallback, exact exec line (host vs container — pick; recommend container exec with `docker cp` of the script), `-o` dir convention (`./failure-bundle-<target>-<epoch>/`, logged), fallback manifest (exact commands: `compose logs --tail=500 $SERVICE`, `inspect`, `grep` of recorded readiness/health lines from LOG_FILE, `rake status` best-effort), rollback-story template (4 fixed lines: backup path, image revert command, up command, unpause command marked HUMAN-ACTION).

---

## F-16 — Low-Medium: secret handling letter vs practice

Conventions: "no token ever on a command line or in the log — smoke-test clone via credential helper / `GIT_ASKPASS`."

**Pair 1 — header transport:** A: `curl -H "PRIVATE-TOKEN: $GITLAB_ADMIN_TOKEN" ...` — token in argv, visible in `ps` to any host user. A claims "not on the command line" means "not a literal in the script." B: header via temp file (`-H @/tmp/hdr`) with `trap rm`. Same AD sentence, different exposure.

**Pair 2 — token→call map:** unstated. A uses admin token for version+runners+clone; B uses smoke token for clone. A's `GIT_ASKPASS` script echoes the admin token into a git child (over-privileged; any git credential echo/debug leaks admin).

**Pair 3 — `set -x`:** operator running `bash -x` for learning (the demo's purpose!) prints every expanded token. No AD addresses trace mode. A leaves it lethal; B adds `[[ $- == *x* ]] && die` guard. Both compliant today.

**Fix:** map each call to its token (version+runners=admin; clone=smoke; health endpoints=none); mandate header-file or stdin transport (never argv); mandate `set +x` guard + `trap` cleanup of temp secrets; state that `GIT_ASKPASS` helper carries only the smoke token.

---

## Cross-cutting notes

1. **AD-7 "checking functions never change anything" vs logging.** Heartbeat writers both probe and append to the log. Strict reading forbids it; intended reading means "never change GitLab/container state." Tighten to: "checks never change container, runner, file (except the log append), or remote state."
2. **AD-1 "readable top-to-bottom"** underdetermines source layout (execution-order vs dependency-order vs main-first). State: constants → strictness → log/die → probes → phases in execution order → arg-parse → main. Trivial but closes presentation-order drift for the mentor demo.
3. **Rake header regex + cell normalization** (AD-10): pin the header assert regex for 16.11–17.x, case rule (`finished` exact lowercase after `tr -d ' '`), trim rule. Today's "shape asserted" lets two regexes disagree on the same table.
4. **Proceed-gate edition re-assert** (see F-4): startup-only assert misses edition flips from a wrong pull. Add to proceed step 1.
5. **Concurrent runs:** Deferred punts lockfiles, leaving concurrent-run corruption unaddressed (both runs sed/pull/down concurrently). Minimum: AD stating concurrent runs are operator error + best-effort guard (die if a backup for the target with mtime <1 h exists? or `flock` one-liner — pick; even "documented risk, no guard" is better than silence).

## Proposed AD change list (minimal close-out)

- Tighten AD-2 (gated planning + leftover check), AD-3 (strip regex + edition source + re-assert), AD-5 (prompt/timing/TTY/empty-note), AD-6 (closed env table + normalization + literals), AD-8 (posture matrix + GATE vocab + quoting + fallible def + down-window rule), AD-9 (exact scoped commands + backup path + reconcile SPEC), AD-10 (scope incl. pre-checks + hang rule exact + header regex), AD-11 (plan reads/binding/env/checklist), AD-12 (URL/exec/path/fallback manifest/story template), AD-13 (pagination + drain + success-only unpause).
- New AD-14 (pin algorithm), AD-15 (backup demo layout) — or fold both into tightened AD-4/AD-6 conventions.
- Resolve SPEC conflicts: maintenance mode (adopt or waive), down/up vs pull/up (F-3). Spine must not silently contradict SPEC.

## Verdict rationale

Two critical safety holes (migration-wait skip on re-run; unpause-on-failure) plus silent SPEC contradictions and an unpinned version-resolution core mean two letter-compliant builds can corrupt data, flood a broken instance with CI, or pin different images. The spine's paradigm and halt-first instincts are sound — the gaps are all closable with the tightened AD text proposed above — but it is not build-ready until F-1 through F-9 are closed.
