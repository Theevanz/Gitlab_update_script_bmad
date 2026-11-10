---
title: 'Update stale operational docs after verified backup'
type: 'chore'
created: '2026-11-10'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Four operational docs are stale after the verified live backup set 20261110-024852: backup.env.example shows /srv placeholders with a wrong header, vendor/README claims the age binary is absent, restore.md lacks POC operating notes, and test-gitlab-server/README cites GitLab 16.11 vs the actual 17.5.5.

**Approach:** Refresh those four files to match verified repo state (script POC defaults, vendored age 1.3.2, compose 17.5.5, live set), preserving all BATS-asserted strings and leaving frozen planning artifacts and sprint tracking untouched.

</frozen-after-approval>

## Implementation Notes

- Spec placed here (gitlab-backup/_bmad-output/implementation-artifacts/) instead of the parent _bmad-output path: the parent path is outside this session's write sandbox, and this module's sprint artifacts already live here.
- Files changed (4): backup/backup.env.example (POC placeholders + override notes, all 13 ^VAR= kept), backup/vendor/README.md (vendored-state rewrite), docs/restore.md (verified-set demo line + POC operating notes appendix), test-gitlab-server/README.md (17.5.5 + pipeline-sets layout + keys row).
- Decisions: example keeps script defaults (GITLAB_CONTAINER=gitlab, NAS_HOST=nas) with POC-override comments rather than hardcoding POC values; restore.md stays generic with a labeled POC appendix; test-gitlab-server setup.sh 16.11 comment left alone (code, out of docs scope); sprint-status untouched (tracking, not docs).
- Surprise: test-gitlab-server/README sits outside the write sandbox; staged the new content via /tmp and copied with one escalated bash call.
- Verified: all 13 example vars present, all 9 restore.md BATS strings preserved, no 16.11 left in the test-server README.
- Review (blind-hunter, 22 findings): patched 14 simple items (example POC values, vendor details, runbook clarifications, teardown note); rejected 1 low (shell-quoting guidance); deferred 5 groups to deferred-work.md (restore-drill corrections, runbook extensions, BACKUP_PATH question, keys gitignore, quick-start gaps). Skipped commit per git safety rule (no explicit commit request).

## Review Triage Log

- F1 example GITLAB_CONTAINER contradiction: medium, patched — value set to test-gitlab-server with service/default note.
- F2 example NAS_HOST placeholder: low, patched — POC IP value with script-default note.
- F3 BACKUP_DIR pre-create note: low, patched — mkdir comment added.
- F4 shell-sourcing/quoting guidance: low, rejected — POC values are spaceless and proper guidance needs examples.
- F5 ENV_FILE self-loading note: low, patched — export-required parenthetical added.
- F6 age-line strictness + SSH 600: low, patched — two short comments added.
- F7 vendor asset filename dropped: low, patched — filename restored (own regression).
- F8 version-confirm + keygen note: low, patched — step 5 added.
- F9 provenance wording: low, patched — aligned to publisher digest.
- F10 re-verify cwd/mismatch/-c: low, patched — checkout-root path, mismatch action, comment-only note.
- F11 AGE_BIN literal: low, patched — e.g. AGE_BIN=age added.
- F12 restore step 5 stop-container: medium, deferred — pre-existing, drill-owned.
- F13 runbook missing elements: medium, deferred — enhancement, drill will surface.
- F14 decrypt-location topology: medium, deferred — needs design decision.
- F15 step 6 paths + sudo: low, patched paths; sudo rejected (generic steps + POC appendix by design).
- F16 nobody token + retention pointer: low, patched token; retention deferred (no enforcement exists).
- F17 NAS/output/reconfigure/healthcheck: low, patched expected-OK line; rest deferred.
- F18 BACKUP_PATH/latest staleness: maybe-false (medium if true), deferred — parent contract + demo-runbook would settle.
- F19 keys/ gitignore: medium, deferred — planned hygiene next step.
- F20 quick-start gaps: low, deferred — enhancement beyond scope.
- F21 demo-shell ambiguities: low, deferred — enhancement beyond scope.
- F22 teardown survival note: low, patched — Notes bullet added.
