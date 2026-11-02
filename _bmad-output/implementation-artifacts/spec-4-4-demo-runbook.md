---
title: 'Seed fake GitLab 16.11 demo environment (Story 4.4 phase 1)'
type: 'chore'
created: '2026-11-02'
status: 'done'
route: 'dispatch'
review_loop_iteration: 1
context: []
baseline_commit: '417ef0e6f9de5d3b2f262f123b7e2adfda73fdfa'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Story 4.4's live demo needs a seeded GitLab 16.11 (reachable API, admin + smoke tokens, seed project with main + CI, fresh backup, compose file), but no setup exists anywhere — the demo cannot run until a fake environment is built from scratch.

**Approach:** Build `test-gitlab-server/` on this machine: Docker Compose running a pinned gitlab/gitlab-ce 16.11.z, bootstrap root + tokens, create seed/demo with main and minimal valid CI config, hand-make a backup-contract backup, and record every setting + env export in the folder so the demo phase starts from a README.

## Decisions (from scoping)

- Execution scope: full live demo authorized; deferred until the seed exists (see deferred-work.md).
- Seed location: `test-gitlab-server/` (kebab-case; the asked "test gitlab server" cannot contain spaces — shell paths).
- `docker compose` use explicitly authorized by the user.
- Split: seed first; live hops + hang injection + 4.4 evidence deferred.
- GitLab Runner: skipped — zero-runner no-op pause + loud-warning close-out (documented degraded path); seed stays lighter.
- Docker execution: user runs compose/setup on their host; agent verifies from the test side (flipped per user: "i can run the compose and u can test from there").
- Volumes: all GitLab data co-located in the folder as bind mounts (`volumes/config`, `volumes/logs`, `volumes/data`) for easy management — no named volumes.

## Boundaries & Constraints

**Always:** Everything seed-related lives under `test-gitlab-server/` (compose file, setup script, volumes, backups, `.env.example` with placeholders only, README with exports); pin the exact 16.11.z image tag and record it; root password comes from gitignored `.env` via `GITLAB_ROOT_PASSWORD`; `external_url` derives from `GITLAB_URL` with matching port mapping; wait up to 10 min for `/-/health` + `/health_check` green before any bootstrap step; tokens get minimal scopes (admin: `api`, covering the manage_runner right; smoke: read/write_repository); real secrets live only in a gitignored local `.env`, never committed; the setup script is idempotent (safe to re-run); ports are env-overridable and the setup halts naming any occupied one.

**Never:** No edits to `runner/`, the runbook, or the four frozen spec files; no real data — fake seed only; no volume deletion outside the seed folder (wipe = `rm -rf volumes/ backups/` only); never commit `.env` or live tokens.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Compose up | Pinned 16.11.z image, free ports, ≥10GB disk | Service healthy, `/-/health` OK + `/health_check` success | Boot timeout (10 min) halts naming the service + log tail |
| Bootstrap | Healthy 16.11 | Root login works; admin + smoke tokens created via rails runner and stored in `.env` | Token failure halts with console output |
| Seed project | Tokens valid | `seed/demo` exists with `main` + minimal valid CI config (pending without a runner); smoke-token clone + push works | Push failure halts naming auth/repo cause |
| Backup | Instance up | `backups/<stamp>/{data/,secrets/,BACKUP_CREATED_AT}` fresh (setup refreshes ≤24h at demo time), `backups/latest` symlink | Missing/stale item halts naming it |
| Settings bundle | All above green | README reproduces all 7 env exports + compose path from a clean shell | N/A |

</frozen-after-approval>

## Code Map

- `test-gitlab-server/` (new) — `docker-compose.yml` (pinned `gitlab/gitlab-ce:16.11.10-ce.0`), `setup.sh` (idempotent: wait → tokens → seed → backup), `volumes/{config,logs,data}` (bind mounts), `.env` (gitignored secrets), `.env.example` (placeholders), `README.md` (exports + paths), `backups/<stamp>/` + `backups/latest`
- `.gitignore` (new) — ignores `test-gitlab-server/.env`, `volumes/`, `backups/`
- `runner/upgrade-gitlab.sh` — consumer contract, read-only: env header :12, `verify_backup` :1010, `smoke_test` :1595, phase order `main()` :1958
- `runner/upgrade_path.yml` — 16.11 is a valid start stop (:82); demo range 16.11 → 17.1 → 17.3 → 17.5
- `_bmad-output/implementation-artifacts/demo-runbook.md` — "What the demo host needs" + Settings defines seed done-ness
- `_bmad-output/specs/spec-deliverable-gitlab-update/backup-contract.md` — backup layout (`data/`, `secrets/`, epoch `BACKUP_CREATED_AT`, ≤24h)
- `_bmad-output/specs/spec-deliverable-gitlab-update/health-gates.md` — endpoint roles for readiness checks
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — story key `4-4-demonstrated-proof-on-the-seeded-instance` stays `review` until the deferred demo phase completes
- `_bmad-output/implementation-artifacts/deferred-work.md` — demo execution entry (live hops + injection + evidence)

## Tasks & Acceptance

**Execution:**
- [x] `.gitignore` -- create ignoring `test-gitlab-server/.env`, `volumes/`, `backups/` -- secrets and runtime data never committed (first, before setup creates them)
- [x] `test-gitlab-server/docker-compose.yml` -- create pinned 16.11 CE service with co-located bind-mount volumes + env-overridable ports (defaults 8080/8443/2222) -- reproducible fake host, one folder to manage
- [x] `test-gitlab-server/setup.sh` -- create idempotent bootstrap (prereqs → compose up → 10-min health wait → rails-runner tokens → seed/demo + CI → fresh backup → smoke clone/push → print exports) -- one-command seed
- [x] `test-gitlab-server/.env.example` + `test-gitlab-server/README.md` -- document placeholders + quick start, layout, all 7 exports, teardown -- demo settings live with the env
- [x] `runner/upgrade-gitlab.sh` -- run `--plan` rehearsal against the seed (execute only, never edit) -- read-only proof the seed satisfies "what the demo host needs"

**Acceptance Criteria:**
- Given a fresh checkout, when setup completes, then compose is healthy, health endpoints green, and tokens work (version API + runners list + clone/push).
- Given setup complete, when the folder is inspected, then config/logs/data volumes, backups, and settings all live under `test-gitlab-server/`.
- Given setup complete, when the backup dir is inspected, then layout + freshness satisfy the backup contract.
- Given the seed is complete, when the `--plan` rehearsal runs with recorded settings, then it passes read-only with zero mutations.
- Given all green, when the README is followed from a clean shell, then all 7 env exports reproduce the working config.

## Implementation Notes

- User directed immediate simple build: review findings applied inline (root password via env, rails-runner tokens, external_url wiring, 10-min wait, CI wording, port halt-vs-remap, disk prereq, gitignore first, manage_runner wording, /health_check verify).
- User runs compose/setup on their host; agent verifies after (health + --plan).

## Session handoff (2026-11-02)

- DONE (seed live): user ran `setup.sh` — GitLab 16.11.10 up, `seed/demo` on main with CI, tokens in `.env`, fresh backup; `healthcheck.sh` 6/6 OK; `--plan` rehearsal exit 0 (pre-health/pre-migrations/pre-backup pass, nothing changed). Code review round 2 done: 53 findings triaged (2 medium + 14 low patched and re-verified live, 1 high deferred — secrets in pushed history 9311a0d need rotation decision). Spec status: in-review.
- WAITING ON: user to decide the deferred secrets rotation (see deferred-work.md); worktree committed locally by the build run (push when ready).
- NEXT: resume deferred demo (live hops 16.11→17.1→17.3→17.5 + hang injection + 4.4 evidence) from deferred-work.md.

## Spec Change Log

- Review pass 1 (subagent): fixed HIGH 1-3 (root-password method, token-creation method, external_url wiring) + MEDIUM 5 (CI wording vs zero-runner) + nits (gitignore create-first, manage_runner wording, /health_check verify, port behavior, disk prereq). Added user-directed volumes co-location + user-runs/agent-tests flip. KEEP: one-folder layout, idempotent setup, --plan as seed acceptance.

## Review Triage Log

- HIGH 1-3, MEDIUM 5: valid — fixed in spec + implementation. MEDIUM 4/6/7, LOW 8-12: valid nits — fixed. No false findings.

### Code review (round 2, 2026-11-02; verification-gap layer: no findings)

Blind layer:
- B1 spec handoff vs [x] tasks — low — handoff text is stale (user did run setup; live run proven) but fix is a spec edit; rejected per rule, handoff refreshed separately.
- B2 healthcheck.sh undocumented — low — header comment states its role but README/spec never point to it; patch (README one-liner; spec side dropped).
- B3 .env was committed with live secrets — high — 9311a0d is pushed to origin with root password + tokens; rotation + history decision needs the human; deferred + flagged.
- B4 exports vs .env.example mismatch — false — names match demo-runbook Settings exactly; COMPOSE_FILE/BACKUP_PATH are derived outputs by design.
- B5/E19 URL/port desync unchecked — medium — overriding HTTP port without editing URL breaks external_url; failure surfaces only as a 10-min timeout; patch (consistency halt).
- B6 df measures repo fs, not docker storage — low — true on Desktop/remote daemons but fine as a proxy on this host; proper fix complex; rejected.
- B7/E2 port check skipped when project exists — low — deliberate idempotency trade-off; docker still fails loudly on real conflicts; rejected.
- B8 HTTP probe of SSH port — false — outcomes correct: free→curl exit 7, anything else→busy halt; no wrong verdict reachable.
- B9 set_env sed injection — low — real fragility but unreachable with GitLab's token charset; patch (escape replacement; behavior-preserving).
- B10/E25 fixed /tmp/seed-token.err — low — concurrent runs clobber each other; patch (mktemp).
- B11/E11 token embedded in clone URL — low — token charset is URL-safe so breakage unreachable; ps exposure transient on single-user box; swapping proven oauth2 auth is riskier than the defect; rejected.
- B12 GID grep whitespace — false — disproven by the successful live run; GitLab emits compact JSON.
- B13 no 16.11.z version assertion — low — pin is explicit in compose; drift is self-inflicted and --plan surfaces it; rejected.
- B14 :Z bind mounts — false — required on this SELinux host (proven by live run); ignored on Docker Desktop.
- B15/E22 README cwd/teardown ambiguity — low — both setup paths work, but teardown from root confuses; rm -rf of absent paths is a no-op so no data loss; patch (qualify with cd).
- B16 backup never exercised — false — --plan ran the pre-backup check green; hand-made fake backup is the stated intent.
- B17 wide monitoring_whitelist — low — localhost demo with non-sensitive endpoints; narrowing knobs add surface for no gain; rejected.

Edge layer:
- E1/E18 non-numeric port — low — curl exit 3 misreported as busy; SSH interpolation would break ruby config; patch (numeric guard on all three ports).
- E3 daemon-down raw failure — low — docker's own error is clear but a named halt is cheaper to diagnose; patch (docker info guard).
- E4 dead container polls 10 min — low — slow but still halts with log tail; per-iteration exit checks add noise; rejected.
- E5 logs failure skips named halt — low — under set -e a failing logs call exits before halt; patch (|| true).
- E6 BSD sed -i — low — out of scope: intent is this-machine Linux demo; rejected.
- E7 transient 500 orphans tokens — low — duplicates harmless; re-runs converge on a working token; rejected.
- E8 transient GET then POST 409 — low — rare race; idempotent re-run converges; rejected.
- E9 pre-existing master-branch project — low — out-of-flow precondition; rejected.
- E10 clone/push stderr discarded — medium — spec matrix requires naming auth/repo cause; raw stderr would leak the token so redaction is required; patch (redacted tails for clone + push).
- E12 clone checks out master — false — project is created with default_branch=main and clone follows remote HEAD; proven live.
- E13 future BACKUP_CREATED_AT — low — needs clock tampering and self-heals; rejected.
- E14/E36 unquoted export printf — low — safe on this box but %q is zero-risk hardening; patch.
- E15 decorative COMPOSE_SERVICE/SEED vars in .env.example — low — nothing reads them; prints carry the true constants; patch (delete the two lines).
- E16 healthcheck SKIP without token — low — deliberate explicit SKIP alongside visible endpoint results; rejected.
- E17 no smoke-token check — low — naive probe wrongly FAILs on valid minimal-scope tokens (403); correct check subtle; setup covers smoke at seed time; rejected.
- E20 short root password idles 10 min — low — plausible typo with slow failure; patch (length guard, min 8).
- E21 df parsing fragility — low — wrapped output mis-shifts fields; patch (df -kP).
- E23 README hardcodes :8080 — low — port-overriding users pasting verbatim misconfigure; patch (derive URL from .env in the example).
- E24 volumes root-owned by daemon — low — host wipe may need sudo; patch (mkdir -p before up).
- E26 raw compose-up failure — low — docker errors are informative but a SETUP-HALT wrapper keeps halt discipline; patch.
- E27 mktemp failure raw exit — low — non-scenario (/tmp broken); rejected.
- E28 healthcheck without compose v2 — low — same-host assumption; setup already gates compose; rejected.
- E29 deleted .env.example raw cp error — low — self-inflicted; cp's error is clear; rejected.
- E30/E31 .env syntax error raw abort — low — self-inflicted edit error; shell names the line; rejected.
- E32 whitespace-padded placeholder — low — negligible on localhost demo; rejected.
- E33 second checkout name clash — low — out of scope: single seed per box; rejected.
- E34 backups/latest as real dir — low — needs manual tampering; rejected.
- E35 backup-before-smoke claim — false — premise inverted: smoke clone/push (lines 100-108) runs before backup (110-123).

## Verification

**Commands:**
- `docker compose -f test-gitlab-server/docker-compose.yml config -q` -- expected: exit 0 (valid compose file)
- `bash -n test-gitlab-server/setup.sh` -- expected: exit 0, no output
- `docker compose -f test-gitlab-server/docker-compose.yml ps` -- expected: gitlab service running/healthy (after user runs setup)
- `curl -sf $GITLAB_URL/-/health && curl -sf $GITLAB_URL/health_check` -- expected: HTTP 200 + success (after user runs setup)
- `./runner/upgrade-gitlab.sh --plan` (with seed env) -- expected: plan print + read-only checks pass, exit 0, container untouched

**Manual checks (if no CLI):**
- README exports work from a clean shell; `.env` untracked by git; `seed/demo` visible in UI with `main` + CI config; backup dir holds `data/`, `secrets/`, recent-epoch `BACKUP_CREATED_AT`.
