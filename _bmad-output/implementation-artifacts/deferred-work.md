- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/_bmad-output/implementation-artifacts/spec-4-4-demo-runbook.md`
  summary: Rotate GitLab root password + admin/smoke tokens and decide whether to rewrite pushed history containing them (commit 9311a0d on origin).
  evidence: High (verified): .env with live secrets was committed in 9311a0d which is pushed to origin; worktree is fixed (.env untracked + ignored) but history still exposes the credentials.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/_bmad-output/implementation-artifacts/spec-4-4-rake-finalized-verdict.md`
  summary: Reset test-gitlab-server compose drift (17.5.5 in tree vs documented 16.11 seed pin) or document 17.5.5 as the new seed baseline.
  evidence: setup.sh never pins the image, so a re-run boots 17.5.5 instead of the README-pinned 16.11.10; evidence-summary documents the drift and the revert procedure but the reset was never executed.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/gitlab-backup/_bmad-output/implementation-artifacts/spec-update-all-docs.md`
  summary: Correct restore.md steps 5-7 against the Story 3.4 live drill (stop-services vs stop-container, BACKUP arg, decrypt location given the private-key-never-on-host rule, pre-restore backup, scheduler lockout, plaintext cleanup).
  evidence: Medium (verified pre-existing): step 5 tells the operator to stop the container then run the in-container restore tool, and the decrypt-where flow is unstated; the pending operator drill is the right place to prove the exact sequence.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/gitlab-backup/_bmad-output/implementation-artifacts/spec-update-all-docs.md`
  summary: Extend the runbook with NAS set listing/selection, post-config gitlab-ctl reconfigure, healthcheck.sh cross-reference, and a pointer to whatever enforces retention horizons.
  evidence: Low (verified pre-existing enhancement): useful operator guidance beyond the staleness scope; retention enforcement is a SPEC non-goal so no job exists to point at yet.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/gitlab-backup/_bmad-output/implementation-artifacts/spec-update-all-docs.md`
  summary: Confirm whether the demo-shell BACKUP_PATH=$PWD/backups/latest export is stale now that pipeline sets sit alongside the legacy latest symlink.
  evidence: Maybe-false, medium if true: latest still points at legacy seed 1793610538 while set 20261110-024852 sits beside it; parent backup-contract.md plus the demo-runbook would prove which path the upgrade demo consumes.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/gitlab-backup/_bmad-output/implementation-artifacts/spec-update-all-docs.md`
  summary: Gitignore-enforce test-gitlab-server/keys private material so the Ed25519 key cannot be committed accidentally.
  evidence: Medium (verified): keys/ holds id_backup_ed25519 (600) untracked with no ignore rule; docs now state the never-commit policy but nothing enforces it.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/gitlab-backup/_bmad-output/implementation-artifacts/spec-update-all-docs.md`
  summary: Fill test-gitlab-server README quick-start and demo-shell gaps (healthcheck verification, ports/URL/sign-in, sudo note, Docker prereqs, runbook path anchor, COMPOSE_SERVICE vs container_name, SEED_PROJECT_PATH definition).
  evidence: Low (verified pre-existing enhancement): first-boot guidance beyond the version-staleness scope of this change.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/_bmad-output/implementation-artifacts/spec-integrate-backup-script.md`
  summary: Update test-gitlab-server/setup.sh to seed a pipeline `<ts>/` set (or drop the legacy seed block). The printed BACKUP_PATH export was fixed to $PWD/backups on 2026-11-10.
  evidence: Medium (verified): setup.sh still seeds the legacy data/secrets layout the gate ignores; the gate self-heals via produce-once so runs proceed.
