# Review — Stack Version Verification

- **Target:** `_bmad-output/architecture/architecture-gitlab-backup-2026-11-03/ARCHITECTURE-SPINE.md`, "Stack" table
- **Date:** 2026-11-03
- **Method:** web search per pinned technology; checked existence, current version as of November 2026, and fit for a bash-only on-prem GitLab backup script
- **Verdict:** PASS WITH FINDINGS — 1 stale pin (GitLab range), 2 pins needing a patch-level refresh note (age, BATS); all technologies exist and fit

## Per-technology results

### 1. bash — ≥5.0, prefer 5.3 (latest stable Jul 2025) — CONFIRMED

- Bash 5.3 (released July 2025) remains the latest stable major in 2026 across multiple sources.
- Upstream is at patch 5.3.20 (September 2026); e.g. Ubuntu 26.04 LTS ships 5.3.9.
- The spine's pin is accurate. No change needed. The ≥5.0 floor is reasonable for a portable backup script (and macOS still ships 3.2, so the floor matters if the script is ever tested there — out of scope but worth knowing).

Sources: copyprogramming bash guides (2026), devops-daily guide (updated 10/24/2026, cites 5.3.20 Sep 2026).

### 2. gitlab-backup via GitLab Docker image 16.x–17.x — STALE, UPDATE REQUIRED

- **Current GitLab is 19.x.** On 21 Oct 2026 GitLab shipped patches 19.5.1, 19.4.3, 19.3.6, 19.2.9, 19.1.9, 19.0.10 and 18.11.13 (endoflife.date confirms 19.5 released 15 Oct 2026). Supported lines are 18.11 and 19.x.
- **There is no fixed release below the 18.11 line** for the October 2026 CVSS-10 RCEs (CVE-2026-110264 spans releases back to 7.0; CVE-2026-97229 patched in 19.4.2/19.3.5/19.2.8). A host still on 16.x–17.x cannot be patched — it must be upgraded through required stops (18.2, 18.5, 18.8, 18.11, then 19.2, 19.5...).
- The **mechanism** is still correct: official GitLab Docker backup docs confirm `docker exec -t <container name> gitlab-backup create`, and `STRATEGY=copy` remains documented (avoids tar/gzip streaming errors; introduced in 8.17).
- **Recommendation:** change the spine pin to GitLab Docker image **18.11 / 19.x** (e.g. `gitlab/gitlab-ce:19.5.x-ce.0`), and add a note that the reference/POC host must itself be on a supported GitLab — backing up an unpatchable 16.x/17.x host is a finding in its own right. Keep the `docker exec … STRATEGY=copy` invocation as-is.

Sources: privatedevops (Oct 2026 patches), endoflife.date/gitlab (29 Oct 2026), devopsity CVE-2026-110264 guide, docs `gitlab-org.gitlab.io/.../docker/backup.html`, GitLab backup_restore docs (STRATEGY=copy).

### 3. age (vendored static binary) — 1.3.x (CLI 1.3.1 Dec 2025) — RANGE OK, PINPOINT STALE

- **Latest is v1.3.2**, not v1.3.1. FreshPorts logged the 1.3.1→1.3.2 port update on 30 Aug 2026; release notes describe v1.3.2 as "a minor release with a wide range of fixes and hardening improvements"; a vulnerability DB lists v1.3.2 as latest as of 31 Oct 2026. (v1.3.1, Dec 2025, matches the spine's date.)
- The `1.3.x` range still covers reality, but the parenthetical names 1.3.1 as if current.
- Fit: age is active, maintained by Filippo Valsorda, Go-based (static binaries — vendoring story holds). v1.3.0+ added hybrid post-quantum recipients (X25519 + ML-KEM-768); plain X25519 recipients as the spine assumes remain supported and default-compatible.
- **Recommendation:** refresh pin to **1.3.2** (vendor that binary); no design change.

Sources: github.com/FiloSottile/age/releases, FreshPorts security/age, vulertsecurity (31 Oct 2026).

### 4. rsync — ≥3.4, prefer 3.5.x (3.5.1 Sep 2026; 3.5.0 fixed 33 CVEs) — CONFIRMED

- rsync 3.5.1 released **21 September 2026** (rsync.samba.org, Wikipedia) — fixes 3.5.0 regressions, adds protocol 33. The "33 CVEs / 33 security fixes in 3.5.0" claim is confirmed (linuxiac, openSUSE Tumbleweed Sep 2026 notes, FreeBSD VuXML).
- **Recommendation (minor):** raise the floor — prefer/require **≥3.5.1** rather than ≥3.4. Pre-3.5.0 versions carry the 33 audited vulnerabilities, and 3.5.0 itself had regressions fixed by 3.5.1. Shipping a backup tool that tolerates rsync 3.4 weakens the "ship" stage. Also note protocol 33: both ends should be 3.5.1+ for the new statistics (graceful otherwise, but pin both sides).

Sources: rsync.samba.org, linuxiac (3.5 and 3.5.1 articles), openSUSE Tumbleweed Sep 2026, FreeBSD VuXML, Red Hat RHSA-2026 advisories.

### 5. OpenSSH (key auth, Ed25519) — ≥9.x, prefer 10.x (10.6 Oct 2026) — CONFIRMED

- **OpenSSH 10.6 released 6 October 2026**, newest release as of late Oct 2026 (openssh.org release notes, Safeguard release history 25 Oct 2026). Fixes ~10 CVEs incl. a plaintext-recovery/compression side-channel item; disables LZ77 compression by default; enables hybrid PQ signature algorithm `ssh-mldsa44-ed25519`.
- Ed25519 key auth is unaffected by the 10.6 changes (the PQ note concerns experimental keys needing replacement — not Ed25519).
- **Caveat (no action):** distro lag is real — Debian 12/13 had no fixed 10.6 package as of 7 Oct 2026. The spine's ≥9.x floor accommodates that; "prefer 10.x" is right.

Sources: openssh.org/txt/release-10.6, helpnetsecurity (7 Oct 2026), windowsforum/gbhackers summaries, prepaid-host (Debian tracker state).

### 6. sha256sum (coreutils, system) — "system version; output format stable" — CONFIRMED

- Current coreutils is **9.12** (September 2026; man pages confirm), via 9.10 (Feb 2026). `sha256sum` output format is unchanged and `sha256sum -c` compatible — the spine's non-pin ("system version") is the right call; nothing to version-lock.
- No change needed.

Sources: man.archlinux.org / manpages.opensuse.org (coreutils 9.12, Sep 2026), Debian manpages (9.10, Feb 2026).

### 7. BATS (tests) [ASSUMPTION] — "system / vendored — de-facto bash test standard" — CONFIRMED, PIN IT

- bats-core is active and is the de-facto TAP-compliant bash test framework: **v1.14.0 released ~24 Oct 2026** (PyPI bats-core 1.14.0, FreshPorts 1.13.0→1.14.0 on 26 Oct 2026; v1.13.0 was Apr 2026). Supports Bash 3.2+.
- **Recommendation:** resolve the vagueness — pin **bats-core ≥1.13, prefer 1.14.0**, and decide system-vs-vendored at build time (vendoring matches the age air-gap posture if the test box is offline). No design risk either way.

Sources: pypi.org/project/bats-core, FreshPorts devel/bats-core, Gentoo portage (bats-1.14.0).

## Fit check (bash-only on-prem backup script)

All seven technologies exist, are maintained, and fit: bash sequencing + one-tool-per-stage (gitlab-backup, tar, age, sha256sum, rsync/ssh) with BATS for tests is a coherent, dependency-light design. No named technology is dead, renamed, or mismatched to the task. The only reality gap is the GitLab version window, which trails the supported releases by two majors.

## Actions for the spine author

1. **GitLab pin 16.x–17.x → 18.11/19.x** (required; the cited range is unpatchable as of Oct 2026).
2. **age pin 1.3.1 → 1.3.2** (patch refresh; vendor the newer binary).
3. **rsync floor ≥3.4 → ≥3.5.1** (recommended; pre-3.5 carries 33 CVEs, 3.5.0 had regressions).
4. **BATS: pin bats-core ≥1.13 / 1.14.0** instead of "system / vendored" (resolves the vagueness).
5. No change: bash 5.3, OpenSSH 10.x prefer, sha256sum system.
