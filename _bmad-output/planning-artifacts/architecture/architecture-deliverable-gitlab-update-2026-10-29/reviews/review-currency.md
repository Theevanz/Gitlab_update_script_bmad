# Tech-Currency Review — Architecture Spine (GitLab Stepwise Upgrade Runner)

- **Spine:** `_bmad-output/planning-artifacts/architecture/architecture-deliverable-gitlab-update-2026-10-29/ARCHITECTURE-SPINE.md`
- **Reviewer role:** tech-currency (versions, existence, live defaults)
- **Date:** 2026-10-29
- **Method:** live host checks (`bash/curl/jq/git/docker/compose --version`), live HTTP fetches (Docker Hub tags API, gitlab-org `background_migrations.rake` @ 16-11-stable-ee, `config/upgrade_path.yml` @ master, toolbox `gitlabsos.rb` @ main, Docker CLI reference), current GitLab + Docker docs via web search.
- **Verdict:** FIX (one HIGH finding requires rework of AD-10 before build; rest are clarifications)

## Spot-check results (requested items)

| # | Claim leaned on | Result |
|---|---|---|
| 1 | Docker Hub legacy tags API path | CONFIRMED LIVE. `GET https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=2&name=16.11` returned 200 with `results[].name` (`16.11.10-ce.0`, …), unauthenticated. Caveat: official docs now steer to `/v2/namespaces/{ns}/repositories/{repo}/tags` (API 2-beta); legacy path works today but is the non-preferred surface. See F-4. |
| 2 | `gitlab:background_migrations:status` task name for 16.11–17.x | NAME CONFIRMED. Read the actual source at `16-11-stable-ee:lib/tasks/gitlab/background_migrations.rake` — `task status` exists under `gitlab:background_migrations`. BUT output shape contradicts AD-10 (no header row). See F-1 (HIGH). Spine's "renamed :list in 18.9+" is roughly right per current docs tabs (18.9+ `:list` / 18.8− `:status`), though `:list` was introduced in 18.5; irrelevant inside the 16.11–17.x envelope. |
| 3 | `/api/v4/version` endpoint shape | CONFIRMED. Since 15.5 it mirrors the Metadata API: `{version, revision, kas:{…}, enterprise, plan}`. Example: `"version": "18.1.1-ee", "enterprise": true`. Requires authentication (200 for authenticated users) — matches AD-3's admin-token usage. Normalization rule needs tightening. See F-3. |
| 4 | Maintenance-mode tier (Premium+) | CONFIRMED. Docs: Tier Premium/Ultimate, Self-Managed only; absent from CE. (EE-without-license + registration features can expose it — irrelevant to a CE demo.) Deferral is correct. |
| 5 | Runners API pause endpoints | CONFIRMED. `PUT /runners/:id` with `paused=true` is the current pause path; `active=false` is deprecated-but-listed. Drain side: "list jobs processed by a runner" endpoint exists. Token needs `manage_runner` scope (+ admin for instance runners) — worth documenting for `GITLAB_ADMIN_TOKEN`. See F-6. |
| 6 | gitlabsos availability in 16.x/17.x images | NOT BUNDLED there — bundling with Linux package/Docker image started in GitLab 18.3. So AD-12's curl-fetch approach is the *right* call for this envelope, and the fetch target is live: fetched `gitlabsos.rb` @ main from `gitlab-com/support/toolbox/gitlabsos` (35.78 KiB) successfully; `-o/--output-file` flag confirmed in source; README documents the Docker pattern (`docker exec … bash -c "curl …/raw/main/gitlabsos.rb | /opt/gitlab/embedded/bin/ruby"`). Caveats in F-5. |
| 7 | Compose v2 CLI flags | `pull`, `down` (sans `-v`), `up -d`, `ps`, `logs`, `exec`, `stats --no-stream` all exist in current reference. Two flags-level issues: no `docker compose inspect` subcommand exists; `compose exec` allocates a TTY by default. See F-2. |

## Additional verifications (passed)

- **Stack table versions — all current and all match the live demo host.** Host reports: bash 5.3.9, curl 8.18.0, jq 1.8.1, git 2.53.0, Engine 29.9.2, Compose v5.6.1 — exactly the spine's table. Cross-checked recency: Compose v5.6.1 released 21 Oct 2026 (latest stable); Engine 29.9.2 released 20 Oct 2026 (latest); bash 5.3 is the current series (patchlevel 20 latest upstream; distro 5.3.9 plausible). No stale pins.
- **Seed tag exists:** `gitlab/gitlab-ce:16.11.10-ce.0` confirmed live on Hub (`tag_status: active`, pushed 2024-09-17).
- **Vendored file shape (AD-4):** fetched live `config/upgrade_path.yml` @ master — flat `- major: / minor:` pairs with optional `comments:` (17.1 conditional-stop entry present with comment text). grep/sed extraction premise holds. Vendored header should cite `https://gitlab.com/gitlab-org/gitlab/-/blob/master/config/upgrade_path.yml` as source URL.
- **Health endpoints:** `/-/health` ("GitLab OK"), `/-/readiness[?all=1]`, `/-/liveness` all current; localhost allowlist default fits the beside-compose runner. Legacy `/health_check` still documented.
- **`docker compose stats`** exists with `--no-stream` + `--format` — suitable for the "container telemetry" heartbeat line.

## Findings

### F-1 (HIGH) — AD-10's "header row shape" does not exist in 16.11–17.x `:status` output

Reality-checked against the 16-11-stable-ee rake source (`display_migration_status`): the task prints, per database, a `Database: <name>` banner line followed by zero or more rows shaped `<status-padded> | <job_class,table,column,args-json>` (printf format `"%-<n>s | %s\n"`). There is **no header row** (`id | table_name | …` is the new 18.5+ `:list` format, not `:status`).

Consequences for AD-10 as written:

1. "The header row shape is asserted before any cell is trusted; unexpected shape dies loudly" would **die loudly on every real 16.x/17.x run**, because the expected header never appears.
2. "Every status cell `finished`" needs restating against the real grammar: status is the first `|`-separated field of each row; the verdict is "every row's status field == `finished`" (plus define the vacuous case: zero rows after the banner = nothing outstanding = pass, not an error).
3. There are no per-migration progress percentages in this output, so "heartbeat progress deltas" can only be derived from finished-count/total-count across polls — state that explicitly so the implementer doesn't look for a `%` column.

Fix: rewrite AD-10's parse contract against the verified 16.x/17.x grammar (banner line + `status | csv` rows + empty-means-clear), and note the 18.x `:list` table format as out-of-envelope.

### F-2 (MEDIUM) — `docker compose inspect` does not exist; `compose exec` TTY default unaddressed

- The structural-seed diagram says the runner drives "compose ps/inspect/logs/stats". The current compose subcommand list (verified against the official reference) contains `ps`, `logs`, `stats`, `exec` — but **no `inspect`**. `docker inspect` (Engine CLI) exists. Clarify which binary each Layer-0 probe uses so the implementer doesn't emit a nonexistent `docker compose inspect`.
- `docker compose exec` allocates a TTY by default; the reference notes `--no-tty`/`-T` (and `--interactive=false`) for script use. AD-10's rake parsing and any machine-read `exec` output should mandate `-T` to avoid TTY escape/width corruption. (GitLab's own Docker docs use `docker exec -t` for human use — the runner wants the opposite.)

### F-3 (MEDIUM) — Version-string normalization is underspecified for both sides

AD-3 says "compare `X.Y.z` only after stripping the `-ce.0`/`-ee.0` tag suffix". Live shapes:

- Docker tag: `17.5.1-ee.0` → strip `-ee.0` gives `17.5.1`. Fine.
- API `version`: documented example is `"18.1.1-ee"` — i.e. EE responses carry an `-ee` suffix with **no** `.0`. Stripping only `-ee.0` leaves `18.1.1-ee ≠ 18.1.1`.
- CE API shape is **unconfirmed** (could not verify a live CE instance; plausibly bare `17.5.1` with `enterprise: false`, but not checked).

Fix: specify normalization on *both* sides (tag minus `-{ce,ee}.0`, API value minus optional `-{ce,ee}`), and confirm the CE `version` string shape against the seeded instance during build (one curl; cheap).

### F-4 (LOW) — Hub tags-API pinning leans on the legacy path

The legacy `/v2/repositories/…/tags` path works unauthenticated today (verified live), but Docker's current API docs present `/v2/namespaces/…/tags` (2-beta) as the tags surface. Risk is retirement or auth tightening of the legacy path, plus unauthenticated rate limits. Mitigations: keep the legacy call but treat Hub lookup as fallible-with-clear-error per AD-8 (already the posture for failures generally — make it explicit for this call), and note the namespaces-path alternative in the build notes. No spine change strictly required.

### F-5 (LOW) — gitlabsos fetch details to pin down at build

- Fetch from `main` branch raw URL is unpinned; pin to a commit SHA in the script (with the fetch-date convention already used for `upgrade_path.yml`) to keep failure bundles reproducible.
- Standalone curl-piped mode skips the `gitlab.rb` sanitizer and fast-stats (both need a clone/packaged layout) — acceptable for a failure bundle, but the native fallback (AD-12) should be treated as the norm for config capture, not a degraded afterthought.
- Must run **inside** the container (needs `/opt/gitlab/*`, `gitlab-ctl`) via `compose exec -T` (no `-it`), as root or with `--skip-root-check` consequences understood; the script also `nice`s and tars — allow time in the failure path.

### F-6 (LOW) — Document the `manage_runner` scope on `GITLAB_ADMIN_TOKEN`

Current Runners API docs require a token with the `manage_runner` scope (plus admin/owner role as appropriate) for `PUT /runners/:id`. The spine's env table should state the required scope so a minimally-scoped token doesn't fail the pause phase opaquely. (A classic `api`-scope PAT covers it; fine for the disposable demo.)

## Verdict rationale

**FIX**, driven solely by F-1: AD-10 as written cannot be implemented against the verified 16.11–17.x `:status` output (asserts a header row that doesn't exist there) and would halt every run. F-2 and F-3 need small wording fixes in the same pass. Everything else spot-checked — stack versions, endpoint existence, tier gating, file shapes, seed tag — is current and confirmed, so no broader staleness concern.
