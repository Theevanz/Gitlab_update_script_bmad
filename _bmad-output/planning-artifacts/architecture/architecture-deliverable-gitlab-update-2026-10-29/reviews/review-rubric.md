# Rubric Review — Architecture Spine: GitLab Stepwise Upgrade Runner

- **Spine:** `_bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md`
- **Driving spec:** `_bmad-output/specs/spec-deliverable-gitlab-update/SPEC.md` (+ `upgrade-procedure.md`, `health-gates.md`, `backup-contract.md`)
- **Reviewer role:** rubric-walker
- **Date:** 2026-10-29
- **Verdict: FIX** — 3 spec-alignment conflicts buried in Deferred/ADs, 2 missing load-bearing decisions (hang verdict, patch pinning), plus enforceability gaps in 5 ADs.

## Checklist walk

### 1. Fixes the real divergence points for the level below, misses none — FAIL

Missing decisions that two implementers would resolve differently:

- **F1 (Major) — Patch-pinning rule missing.** CAP-1 success requires "every entry is an exact `X.Y.z` latest-patch tag resolvable to a published image"; `upgrade-procedure.md` Phase 1.3 mandates the "`X.Y.z` rule via Docker Hub tags API or packages page". The spine mentions "pin via Hub API" only inside a Capability-Map cell — there is no AD fixing: Tags API vs packages page, pagination, semver-vs-date ordering for "latest" (lexicographic sort gives `17.10 < 17.9`), pre-release filtering, auth/rate-limit handling, or fail-open vs fail-closed when the API is unreachable. Two builds will diverge here, possibly pinning wrong tags.
- **F2 (Major) — Hang-verdict rule missing.** CAP-4 / `health-gates.md` define the core gate criterion: no progress deltas + flat telemetry for 5 minutes = hung = halt. The spine's paradigm says "monitor: heartbeat + deltas" and the map row says "heartbeat + deltas + hang verdict", but the 5-minute rule, what counts as "flat" per signal, and which signals gate (liveness 503 → halt is also unstated) appear nowhere in ADs or conventions. This is the single most load-bearing missing decision.
- **F3 (Medium) — Proceed-gate ordered contract missing.** `health-gates.md` requires an ordered 6-step sequence (version → migrations → `/health_check` → readiness `all=1` → smoke → re-checks/unpause). The spine distributes fragments across AD-3/AD-10/conventions but never fixes the order, the per-step halt behavior, or the endpoint-role discipline (readiness vs health_check confusion is the spec's "classic failure"). Partially covered ≠ decided.
- **F4 (Medium) — Pre-gate vs pause-CI ordering contradiction.** The pipeline orders `pre-gate → pause CI`, but the Capability Map defines the pre-gate phase as "(health + backup contract + CI paused)" while `health-gates.md` lists "CI/CD paused" among pre-gate must-holds. As written, the gate checks paused-ness before the pause phase runs — unimplementable. Decide: either pause lives inside the pre-gate phase, or CI-paused verification moves after Q. (Spec's own Phase 1 order — checks then pause — supports the latter; the map cell is then wrong.)
- **F5 (Medium) — Rollback-story content unfixed.** CAP-6 requires a stated rollback story on failure; the map mentions it but no AD/convention fixes its content (restore which backup artifact? sed tag back? `up -d`? human steps?). Two close-outs will state different stories.
- **F6 (Low) — Telemetry source unfixed.** Conventions require "container telemetry" per heartbeat; `health-gates.md` says `docker stats --no-stream` (or `docker compose stats` where available). The spine never picks — minor divergence on flags/parsing.
- **F7 (Low) — curl probe timeouts unfixed.** Only the 10-minute startup grace is fixed; per-probe `--max-time`/retry behavior is silent. With no timeout decision, a wedged probe hangs the 10 s heartbeat cadence.

### 2. Every AD's Rule is enforceable and actually prevents its stated divergence — PARTIAL

| AD | Assessment |
|----|-----------|
| AD-1 | **Weak.** "Size governed by the mentor-presentation acceptance test, not a line ceiling" is subjective and unverifiable — a reviewer cannot pass/fail it. Keep the single-file + no-source rules (enforceable); replace the size clause with something checkable or drop it. (Low) |
| AD-2 | Enforceable, but see F9 (overrides spec's loop model without acknowledgment). |
| AD-3 | **Gap.** "Startup asserts the API `enterprise` flag matches the expected edition" — the expected edition has no source: no env var in the AD-6 list, no derivation rule from `GITLAB_IMAGE_REPO`. Under-specified, not checkable. (Medium) |
| AD-4 | **Weak.** "Flat `major:`/`minor:` pairs with optional `comments:` text kept next to each stop; extraction asserts the expected shape" — the pinned shape is never pinned: no schema, no example, no association rule for `comments:`. "Kept next to" and "expected shape" cannot be verified. Include the exact vendored-file schema (or a normative example) in the spine. (Medium) |
| AD-5 | Enforceable. Note-ack + TTY-halt + `--plan` exemption are checkable. |
| AD-6 | Enforceable (modulo the missing expected-edition input, see AD-3). |
| AD-7 | Enforceable. Layer-0-first + grace + never-mutate are checkable. |
| AD-8 | Acceptable. "`\|\| die` on every fallible call" is slightly open-ended (what counts as fallible?) but reviewable in a single file. (Low) |
| AD-9 | **Gap.** "`sed` the `image:` line" breaks on multi-service compose files — which line? The `COMPOSE_SERVICE` env exists but the rule never scopes the sed to that service. Two implementers diverge (first match vs service-scoped block edit). Also, mandating `down` + `up -d` deviates from `upgrade-procedure.md` step 3 (`pull && up -d`) with no recorded rationale. (Medium) |
| AD-10 | Acceptable. "Header row shape asserted" leans on the assert-shape-first convention; fine for this altitude. |
| AD-11 | Enforceable, but see F8 (one-hop `--plan` vs CAP-1 full-chain plan). |
| AD-12 | **Gap.** Verified: `gitlabsos.rb` exists in `gitlab-com/support/toolbox/gitlabsos` with `-o/--output-file`. But the AD never fixes *where* it runs: host ruby (not in Stack; "no Python" is stated, ruby is silent) vs `docker exec` into the container (gitlabsos expects omnibus paths; Docker usage is a known awkward case per toolbox issue #34). Two close-outs diverge. Also no pinning/checksum of the fetched script (supply chain; Low for a demo, but state it). (Medium) |
| AD-13 | Enforceable. `PUT /runners/:id paused=true` + drain + unpause-all-with-logged-caveat are checkable. Minor: "drain-check via jobs query" — which endpoint/status filter? (Low) |

### 3. Nothing under Deferred could let two units diverge — FAIL

- **F8 contributor (Major) — Maintenance mode deferred contradicts the spec.** SPEC Constraints: "Script enables maintenance mode at the start of every stop and disables it after the proceed-gate passes"; `health-gates.md` proceed gate step 6: "mode is ON for every stop, script-controlled". The spine defers it ("Premium+; Free-tier demo quiesces via downtime + paused CI + recreation") with no AD, no open question, no spec-change record. Verified: Maintenance Mode is Premium/Ultimate per GitLab docs, so the spec constraint is likely unimplementable on CE — but that makes this a *conflict to resolve explicitly*, not a line in Deferred. As-is, one builder follows the spec (toggle MM), another follows the spine (skip it): textbook divergence. Escalate to an AD or Open Question and reconcile the spec.
- **F9 contributor (Medium) — Runner upgrade deferred contradicts the procedure.** `upgrade-procedure.md` Phase 2 step 2: "Upgrade GitLab Runner to the target version." Spine Deferred: "GitLab Runner container/binary upgrade (out of scope…)". Same burying problem as maintenance mode — a deliberate scope cut contradicting the driving procedure, with no rationale or spec reconciliation.
- Other Deferred items (secrets manager, retry/resume + lockfile with "re-run from scratch" as the rule, multi-node/zero-downtime/Helm, backup *implementation*, concurrent-run support) are legitimately deferred and non-divergent. Note the lockfile bullet conflates resume (decided: re-run) with concurrency (unde decided: two simultaneous runs could corrupt the compose file) — acceptable at this altitude if explicit, but the wording implies both are handled. (Low)

### 4. Named tech is verified-current — PARTIAL (mostly current, 3 stale + 1 inaccurate claim)

Checked 2026-10-29:

| Stack entry | Finding |
|---|---|
| bash 5.3.9 | Major correct (5.3 current since Jul 2025), but `5.3.9` is non-standard upstream notation (bash uses patchlevels, e.g. `bash53-009`; Debian is at `5.3-4`). Clarify notation or re-verify. (Low) |
| curl 8.18.0 | **Stale.** Current is 8.23.0 (2026-10-14, includes 24 security fixes). Bump or qualify as pinned demo-host version. (Low-Medium) |
| jq 1.8.1 | **Stale.** 1.8.2 released 2026-06-20 with security fixes (CVE-2026-44777 et al.). Bump recommended. (Low-Medium) |
| git 2.53.0 | **Stale.** Current is 2.56.0 (2026-09-28). Cosmetic for clone/push usage. (Low) |
| Docker Engine 29.9.2 | Current (29.9.x is latest; Desktop ships 29.9.2). ✓ |
| Docker Compose v5.6.1 | Current (5.6.1 released 2026-10-21). ✓ |
| GitLab CE 16.11.10-ce.0 | Verified resolvable: Docker Hub Tags API returns 200/active for `gitlab/gitlab-ce:16.11.10-ce.0`. ✓ |
| `gitlab:background_migrations:status` | Task exists and current docs still document `:status` alongside `:list`. **But** the parenthetical "(renamed :list in 18.9+)" is unverified — current docs show both tasks coexisting; no rename evidence found. Drop or correct the claim. (Low) |
| `GET /api/v4/version` + `enterprise` flag | Verified via Metadata API docs (`enterprise: boolean`); requires token (401 unauthenticated), consistent with AD-3's admin-token usage. ✓ |
| Hub Tags API for pinning | Exists and reachable (used for the check above); unauthenticated rate limits apply — worth one line in the future pinning AD. |
| `PUT /runners/:id` `paused` | Standard Runners API. ✓ |

Recommendation: either retitle Stack as "pinned demo-host versions" (frozen, fine) or bump curl/jq to current; either way fix the `:list` rename claim.

### 5. Covers the driving spec's capabilities — PARTIAL

| Capability | Coverage |
|---|---|
| CAP-1 stop chain + pinned images | ⚠️ Full-chain print required by CAP-1 success ("Printed plan lists stops in required order starting from 16.11…") but AD-11 defines `--plan` as a *one-hop* plan (current → target). Unreconciled: does the normal-run plan print show the full chain? Fix the plan-print contract (F8's sibling). Pinning rule missing (F1). |
| CAP-2 pre-upgrade gate | ⚠️ Health + backup + CI covered in map; backup verification (~15 lines, freshness 24 h) has no AD/convention detail (artifact layout at `BACKUP_PATH`, timestamp format, boundary semantics) — small but real divergence surface. Pre-gate/pause ordering contradiction (F4). |
| CAP-3 one stop advance | ⚠️ AD-2 enforces one-stop-per-**run** with re-runs, but the spec models a **loop** ("exactly one required stop per loop iteration", "stop loop, one iteration per required stop"). Deliberate and defensible, but it overrides the spec's execution model without acknowledgment or rationale — needs an explicit decision record + spec reconciliation (part of F9). |
| CAP-4 health-during | ❌ Hang-verdict rule missing (F2). Heartbeat format covered in conventions. |
| CAP-5 proceed gate | ⚠️ Fragments covered (AD-3, AD-10); ordered 6-step contract missing (F3). Smoke-test mechanics covered (credential helper / `GIT_ASKPASS`, no token on CLI). |
| CAP-6 close-out | ⚠️ Bundle mechanism covered (AD-12 modulo run-location gap); rollback-story content missing (F5); "jobs flowing" verification after unpause unfixed (Low). |
| Constraints (no-Python, downtime single-node, detect-and-halt, endpoint semantics) | Mostly honored. Maintenance-mode constraint explicitly violated (see Deferred finding). "Official Phase 1→2→3 ordering mirrored" — spine's phase order matches except pause/measurement placement (F4) and the loop→rerun change (CAP-3). |

### 6. Every dimension the altitude owns is decided, deferred, or an open question — PARTIAL

Altitude is `feature`, single-file script — appropriately narrow. Status per dimension:

- Decided: paradigm, phase skeleton, single-file structure, config source + validation, log format, halt contract, check-vs-mutate discipline, verification approach (seeded runs + `--plan`), stack, file layout, secrets posture (plain disposables, explicit).
- Explicitly deferred (fine): secrets manager, retry/resume, multi-node/zero-downtime/Helm, backup implementation, concurrency.
- **Silent dimensions (no decision, deferral, or question):**
  1. **Hang-detection parameters** (F2) — operational envelope gap: the 5-minute/flat-signal rule is the core runtime verdict and it is simply absent.
  2. **Patch-resolution policy** (F1) — environment-interaction gap: how the runner talks to Docker Hub (endpoint, ordering, failure mode).
  3. **Proceed-gate step order and per-step halt semantics** (F3).
  4. **Rollback-statement content** (F5).
  5. **HTTP client robustness**: per-probe timeouts/retries (F7); proxy behavior in "connected environment" (Low).
  6. **Signal handling** (Ctrl-C mid-mutate leaves what posture?) — Low at this altitude, but the halt contract claims a frozen posture; an interrupt path is worth one line.
  7. **Privilege assumption** (docker socket access: root vs docker group) — Low; one line in the structural seed would close it.
- **The spine has no Open Questions section at all.** At minimum, the maintenance-mode-vs-CE conflict and the loop-vs-rerun deviation should be open questions (or resolved ADs with spec reconciliation), not silent Deferred lines.

## Required fixes (ordered)

1. **Resolve the three spec deviations explicitly** (maintenance mode, Runner upgrade, loop→rerun): each needs either an AD with rationale + a spec-change note, or an Open Question. None may remain as bare Deferred lines. (Major)
2. **Add the hang-verdict decision** (5-min rule, flat-signal definitions, liveness-503 halt). (Major)
3. **Add the patch-pinning AD** (source, ordering, filtering, failure mode). (Major)
4. **Fix pre-gate/pause ordering** (F4) and the **plan-print contract** (full chain vs one-hop vs CAP-1). (Medium)
5. **Harden AD-3/AD-4/AD-9/AD-12** (expected-edition source, vendored schema, service-scoped sed + down rationale, gitlabsos run location). (Medium)
6. **Bump or re-scope stale stack entries** (curl, jq, git), clarify bash notation, drop the `:list` rename claim. (Low-Medium)
7. **Add missing small contracts**: proceed-gate order, rollback-story content, backup-verification detail, probe timeouts. (Medium-Low)
8. **Add an Open Questions section** (or resolve into ADs): at least MM-on-CE and loop-vs-rerun. (Process)

## Strengths (for the record)

- Paradigm is crisp and genuinely constraining (linear gated pipeline, no loop, no state file, re-derive everything).
- AD-2, AD-5, AD-7, AD-8, AD-10, AD-13 are well-formed: each names a real divergence and a checkable rule.
- Channel discipline (Layer 0 first, checks never mutate) and the halt contract are the right load-bearing decisions for this problem.
- Stack is ambitious about currency (Compose v5.6.1, Engine 29.9.x both verified latest) — the staleness is only in minor tooling.
- Verification strategy (seeded runs + read-only `--plan`, no harness) correctly serves the presentability mandate.
