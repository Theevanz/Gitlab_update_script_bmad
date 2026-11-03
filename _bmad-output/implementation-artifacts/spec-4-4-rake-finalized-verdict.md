---
title: 'Accept finalized rake rows as complete (unblock 17.1→17.3)'
type: 'bugfix'
created: '2026-11-03'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context: []
baseline_commit: 'c5bea08ba34fe02aa2f4160c8b5c05e0826b0518'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The runner's rake verdict counts only `finished` rows, but live GitLab 17.1 reports terminal-complete rows as `finalized` — so the leftover, monitor, and proceed gates false-positive forever (proven: 59 finished + 2 finalized blocking hop 2 in 3 false-positive halts (stop-2 attempts 2–4) over ~15h on a healthy instance), and no 17.1+ instance can ever advance.

**Approach:** Count `finalized` rows as done in the one shared rake parser (the fix flows to all three gates), state verdicts honestly as complete (finished or finalized), amend the contradicting AD-10 sentence, and prove it with a focused regression check plus the live hop-2 gate run.

## Decisions (from scoping)

- Chosen over scoped partial proof: fix the parser under this bugfix spec, then resume the demo (user decision on the live-demo blocker).
- `finalized` means safe-to-upgrade: GitLab's batched-migration enum treats it as done (terminal state, further along than finished), upgrade guides accept finished-or-finalized, and the live instance finalized both rows itself with zero errors.
- The regression check sources the real runner through a minimal entry guard (spec-review resolution: the tail runs `main "$@"` unconditionally, so sourcing is impossible without it; testing a copied parser would be worthless).

## Boundaries & Constraints

**Always:** A row counts as done when its status is `finished` OR `finalized` and nothing else — active, paused, pending, failed, and unknown statuses still block (fail-closed); fix once in the shared `parse_rake_status` (no per-site verdicts — preserves AD-10's single-signal rule); keep every heartbeat and log field name, counter name, and the `finished total` print contract unchanged (`rake_finished` keeps its name; its done-count meaning is documented in the code comment); verdict messages state complete honestly and never print "all finished" while finalized rows are present; zero rows still counts as clear; malformed tables still reject; amend the one AD-10 rule sentence in the spine (both the verdict phrase and the finished-count delta phrase) citing the live evidence; add a minimal execution guard at the entry point so the regression check can source the parser without running main (executed behavior unchanged); keep the regression check with the project, runnable without Docker.

**Never:** No runner changes beyond the parser verdict, its messages and comments, and the source guard — no timing or cadence tweaks, no new flags, and no bypass or force flag around any gate; no tampering with GitLab's migration rows to satisfy the parser; no spine changes beyond the one AD-10 rule sentence; no demo-flow changes (this spec unblocks hop 2 — the live-demo spec still owns the demo); never weaken the parser to accept an unknown status.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| All finished | 61 finished rows | Clear (61/61 complete) | Unchanged behavior — must keep passing |
| Finished + finalized | 59 finished + 2 finalized (live 17.1 table) | Clear (61/61 complete) | The old block verdict is the bug being fixed |
| One active | 60 done + 1 active row | Block, leftovers named | Must still halt (fail-closed) |
| Malformed table | Missing banner or bad row shape | Reject with parse error | Must still halt (shape contract) |
| Empty table | Banner only, zero rows | Clear | Must not block |
| Sourced load | Check script sources the runner | Functions defined, main not run, zero output | Any run or output means the guard is broken |
| Live hop-2 pre-gate | Healthy 17.1.8 instance, 59+2 table | Leftover check passes; health, backup, CI checks unchanged | Any other gate failure → diagnose; never force past it |

</frozen-after-approval>

## Code Map

- `runner/upgrade-gitlab.sh` `parse_rake_status` :510-556 — the fix: count `finalized` as done alongside `finished`; keep the `finished total` print contract; document the done-count meaning in the comment
- `runner/upgrade-gitlab.sh` entry tail :1975 (`main "$@"`, unconditional) — add the minimal execution guard here so sourcing defines functions without running
- `runner/upgrade-gitlab.sh` leftover check :989-1006 — verdict consumer; message must state complete honestly; refresh the stale :990 comment
- `runner/upgrade-gitlab.sh` plan leftover :1112 — message already says "unfinished", accurate as-is
- `runner/upgrade-gitlab.sh` monitor :1469-1589 — verdict :1584 and hung detail :1589 consume the same counter; finalized rows are static so delta semantics are preserved; refresh the stale :1469 comment and note the done-count meaning at heartbeat emit :1409
- `runner/upgrade-gitlab.sh` proceed verdict :1676-1698 — third consumer: die EXPECTED/OBSERVED :1696 and step log :1698 (exact replacements pinned in task 1)
- `_bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md` AD-10 :109-113 — amend the rule sentence :113 (verdict phrase + finished-count delta phrase) to finished-or-finalized / done-count, citing live evidence; heartbeat vocabulary :166 stays untouched (field names frozen)
- `_bmad-output/implementation-artifacts/demo-evidence-4-4/rake-status-17.1-leftovers.log` — the live 59+2 table: primary realistic fixture and false-positive proof
- `_bmad-output/implementation-artifacts/demo-evidence-4-4/run-stop2-17.3-attempt2-prehalt.log` (+attempt3/4) — the false-positive halts this fix resolves
- `_bmad-output/implementation-artifacts/spec-4-4-live-demo-execution.md` — blocked consumer (in-progress); resumes hop 2 after this fix verifies

## Tasks & Acceptance

**Execution:**
- [x] `runner/upgrade-gitlab.sh` — count `finalized` as done in `parse_rake_status` (:539), add a minimal execution guard at the entry (:1975) so the check script can source the parser, and apply these exact verdict strings: leftover pass :1006 `leftover check: $finished of $total complete (finished or finalized)`, leftover fail :1003 `leftover check: $finished of $total complete, $((total - finished)) unfinished`, monitor done :1585 `migrations all complete ($finished of $total), wait ends`, monitor hung detail :1589 `complete=$finished/$total`, proceed EXPECTED/OBSERVED :1696 `every batched migration complete (finished or finalized)` / `complete=$finished/$total`, proceed step :1698 `step 2/6: migrations all complete ($finished of $total)`; refresh the stale comments at the parser, leftover :990, and monitor :1469, and note the done-count meaning at heartbeat emit :1409 — one shared fix for all gates, field and counter names unchanged
- [x] `runner/check-rake-verdict.sh` (new, executable) — sources the real runner through the entry guard (never a copied parser) and asserts `parse_rake_status` on self-contained inline fixtures: all-finished, finished+finalized, one-active, zero-rows, malformed; exit 0 all-pass / 1 any-fail, no Docker needed — pins the fix without a test harness (AD-11)
- [x] `_bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md` AD-10 rule (:113) — amend the verdict phrase and the finished-count delta phrase to finished-or-finalized / done-count, with the live-evidence citation — keep the adopted architecture truthful
- [x] Live hop-2 pre-gate on the healthy 17.1.8 instance — user runs, agent reviews the output — proves the unblock on the exact failing case

**Acceptance Criteria:**
- Given the live 59 finished + 2 finalized table, when the parser runs, then it reports 61/61 done.
- Given a table with one active, paused, or failed row, when the parser runs, then it reports unfinished (fail-closed preserved).
- Given a malformed table, when the parser runs, then it rejects it (shape contract preserved).
- Given the check script sources the runner instead of executing it, when it loads, then no run starts and `parse_rake_status` is callable with zero output.
- Given the fixed runner on the healthy 17.1.8 instance, when hop 2 runs, then the pre-gate leftover check passes with health, backup, and CI behavior unchanged.
- Given the fix, when heartbeat and verdict lines print, then all field names are unchanged and no message claims "all finished" while finalized rows are present.

## Implementation Notes

- Implemented directly (no subagent dispatch): the durable-test-collateral guidance for this edit sits with this session and cannot pass through a verbatim dispatch; user-executed live verify interleaves here as with the demo spec.
- Failing-first order: entry guard → check script written → ran RED on the finalized fixture (`2 3` vs `3 3`, exit 1) → verdict fix + messages + comments → GREEN (11/11, exit 0). No test weakened.
- Entry guard `${BASH_SOURCE[0]:-$0}`: bash-correct both modes, degrades to old behavior under sh. Sourcing safety verified: top level is assignments + inert traps (`cleanup` no-ops idle) + defs; sourced-load probe asserts zero output; executed-path proof ran main to the expected validate halt (exit 1, log to /tmp, repo untouched).
- User-added status legend comment at the verdict line (numbers omitted: script matches names, ids are version-dependent; finalized described as terminal-complete however reached).
- LIVE PROOF (Nov 3 02:17Z): hop 2 ran clean to `run complete: 17.1.8 -> 17.3.7` — pre-gate `61 of 61 complete (finished or finalized)` (the exact failing case), monitor `114 of 114`, proceed 6/6 incl. smoke clone+push, close-out green. Bugfix step-03 complete; step-04 review deferred until hop 3 finishes (no runner edits while a live run executes it).

## Spec Change Log

## Review Triage Log

- blind-1 blocking fixtures cover only `active`: medium — confirmed, fixtures exercise finished/finalized/active only, so an over-broad done-match counting `finalizing`/`failed` as done would still pass 11/11. Groups with verif-1. → patch.
- blind-2 shape/contract fixtures missing: false — parser already handles multi-banner (counter), skips blank lines, and fails closed on header/case/CR shapes; the live 61-row table parses 61/61. No bad outcome shown.
- blind-3 probe never asserts functions defined: false — every `run_case` invokes `parse_rake_status` directly, so undefined functions yield FAIL lines and exit 1, never a silent pass.
- blind-4 guard misfires on `bash script`/sh: false — experiment: `bash runner/upgrade-gitlab.sh --help` prints help and exits 0 (bash sets $0 to the script path, so the guard fires); sh behavior matches the old unconditional tail.
- blind-5 partial rename / stale greps: false — field names frozen by the spec Always-clause; repo search finds no runbook or automation matching the old message strings.
- blind-6 proof log untracked: false — the cited log exists in the tree at the cited path (2 finalized rows; parser yields 61/61 on it); the citation resolves.
- blind-7 sprint-status done while evidence untracked: low — done-with-untracked-evidence is normal mid-flow, but the `# 4.4 ... live execution needs a connected host` comment is stale now that hop 3 ran. Owned by the demo flow, not this spec. → defer.
- blind-8 deferred-work formatting/timestamps: false — entry starts at column 0 (reviewer misread the diff context prefix); `generated` is a creation stamp and correctly untouched.
- blind-9 compose jump + clutter: low — setup.sh never pins the image, so the tree's 17.5.5 drift would seed the wrong version on re-run; reset is documented-not-executed. Groups with verif-3; demo flow owns the seed env. → defer.
- blind-10 no CI/call-site coverage: false — a standalone check is spec-intended (AD-11, no harness); all three call sites were verified by the live hop-2 run (leftover 61/61, monitor 114/114, proceed 6/6).
- blind-11 diff artifact lists + sos: false — double-listing is a review-artifact quirk, not a code defect; no unredacted secret was shown in any bundle.
- edge-1 cd breaks via PATH/symlink: low — PATH invocation passes ($0 carries the resolved path), but symlink-from-elsewhere aborts loud with exit 1 (verified); one-line BASH_SOURCE-dir fix. → patch.
- verif-1 non-active blocking states unpinned (pre-verified): medium — spec Always-clause + AC require paused/failed/etc. to block, but only `active` is pinned; filed disposition patch. Groups with blind-1. → patch.
- verif-2 executed path unpinned (pre-verified): medium — only the sourced branch is probed, so a never-firing guard would exit 0 doing nothing with all checks green; temp-CWD + temp-LOG_FILE probe is feasible (LOCK_DIR CWD-relative, LOG_FILE env-overridable). → patch.
- verif-3 compose drift vs seed contract: low — drift is real but uncommitted-as-documented with a documented reset; nothing is committed. Groups with blind-9. → defer.

## Verification

**Commands:**
- `./runner/check-rake-verdict.sh` — expected: exit 0, every fixture case passes
- `bash -n runner/upgrade-gitlab.sh` — expected: exit 0, no output (syntax intact)
- Hop-2 run on the 17.1.8 instance (user runs, output reviewed) — expected: `leftover check` passes at 61/61 complete, run proceeds past pre-gate
