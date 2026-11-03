# Review — Stack Version Verification (Round 2, Delta)

- **Target:** `_bmad-output/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md`, "Stack" table
- **Date:** 2026-11-03
- **Prior pass:** [review-versions.md](./review-versions.md) (same day) — this round checks ONLY what is stale or changed since; confirmed-and-unchanged items are carried forward without redo
- **Method:** web search/fetch spot-checks on the 5 changed or date-pinned rows
- **Verdict:** PASS WITH FINDINGS — 4 of 5 re-checked rows confirmed current; 1 required change (rsync floor regressed to ≥3.2)

## Delta results (changed since prior pass)

### 1. gitlab-backup pin reworded ("16.x–17.x" → mechanism + "12.2+ through 19.x") — CONFIRMED

- Spine now pins the mechanism (`docker exec -t <container> gitlab-backup create STRATEGY=copy`) instead of a GitLab version window, with the GitLab version "pinned by the compose file under backup".
- Verified live against official docs just now: [Back up GitLab](https://docs.gitlab.com/administration/backup_restore/backup_gitlab/) documents both `docker exec -t <container name> gitlab-backup create` and `sudo gitlab-backup create STRATEGY=copy` ("to use the `copy` strategy instead of the default streaming strategy").
- The "12.2+" floor is consistent with the documented "users of GitLab 12.1 and earlier should use `gitlab-rake gitlab:backup:create` instead" cutoff (per prior pass + current doc mirrors, e.g. university GitLab help mirrors). "Through 19.x" matches the current major (19.5.x per prior pass; no newer major found this round).
- The unpatchable-16.x/17.x concern from round 1 is now correctly out of the spine's hands (compose-file-owned), though it remains a POC-host finding for whoever owns the compose file.
- No change needed.

### 2. age 1.3.1 → 1.3.2 (Aug 2026) — CONFIRMED CURRENT

- Round-1 refresh adopted. Re-checked: **v1.3.2 remains the latest upstream release** — no v1.3.3 exists. Evidence: [FreshPorts security/age](https://www.freshports.org/security/age/) (1.3.1→1.3.2 on 30 Aug 2026; the later 1.3.2_3 entry of 20 Oct 2026 is a FreeBSD port Go-rebuild revision, not a new upstream release); Alpine edge packages 1.3.2-r0 (built 28 Sep 2026); vuln DB lists v1.3.2 as latest as of 31 Oct 2026.
- Spine's "(Aug 2026; X25519 recipients)" parenthetical is accurate.
- No change needed. Build note: vendor the upstream v1.3.2 release binary, not a distro port revision.

### 3. rsync floor now "system ≥3.2; prefer ≥3.5.1" — STALE FLOOR, CHANGE REQUIRED

- Round-1 recommendation (raise floor to ≥3.5.1) was **not adopted** — the floor instead reads ≥3.2, lower than even the ≥3.4 the prior pass saw.
- Re-checked currency: **3.5.1 (21 Sep 2026) remains the latest release** ([rsync.samba.org](https://rsync.samba.org/), linuxiac, Arch 3.5.1-4 built 25 Oct 2026). No 3.5.2 exists.
- The security case is unchanged and now has a citable upstream line: the rsync project says versions older than 3.5.0 should be upgraded; 3.5.0 fixed 33 security issues and 3.5.1 fixed 3.5.0's regressions plus protocol 33.
- **Recommendation (carried over, now required):** change the floor to **≥3.5.1** (both ends, per protocol-33 note in round 1). A backup tool whose spec tolerates rsync 3.2–3.4 blesses 33 known CVEs in the SHIP stage. If a low floor must stay for legacy hosts, add an explicit "unsupported below 3.5.1 for security" caveat — but prefer the hard floor.

### 4. BATS pinned "bats-core ≥1.13 (1.14.0 Oct 2026)" — CONFIRMED CURRENT

- Round-1 pin adopted. Re-checked: **v1.14.0 remains the latest** — [PyPI bats-core 1.14.0](https://pypi.org/project/bats-core/) (released 24 Oct 2026), [FreshPorts 1.13.0→1.14.0](https://www.freshports.org/devel/bats-core/) (26 Oct 2026), readthedocs shows "Bats 1.14.0". No 1.14.x patch or 1.15 found.
- Distro-lag note (no action): MacPorts still ships 1.13.0, which is why the ≥1.13 floor is the right call.
- No change needed.

### 5. OpenSSH "≥9.x, prefer 10.x (10.6 Oct 2026)" — CONFIRMED CURRENT (spot-check)

- Unchanged since round 1; spot-checked because date-pinned. **10.6 (6 Oct 2026) remains the newest release** as of 25 Oct 2026 ([openssh.org release-10.6](https://www.openssh.org/txt/release-10.6), Safeguard release history). No 10.7 found.
- Heads-up for build time (no action now): the OpenSSH team stated it will ship releases more often for now to get fixes out faster (helpnetsecurity, 7 Oct 2026) — re-check the "prefer" pin when the script is built, not just at spine time.
- No change needed.

## Carried forward (unchanged, not re-checked)

- **bash ≥5.0, prefer 5.3** — CONFIRMED in round 1 (same day); spine text identical. No redo.
- **sha256sum (coreutils, system)** — CONFIRMED in round 1 (same day); spine text identical. No redo.

## Actions for the spine author

1. **rsync floor ≥3.2 → ≥3.5.1** (required; pre-3.5.0 carries the 33 audited CVEs, 3.5.0 had regressions fixed by 3.5.1 — round-1 finding still open and now more urgent given the lower floor).
2. No change: GitLab mechanism pin, age 1.3.2, OpenSSH 10.6-prefer, BATS 1.14.0-prefer, bash 5.3-prefer, sha256sum system.
