- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/_bmad-output/implementation-artifacts/spec-4-4-demo-runbook.md`
  summary: Rotate GitLab root password + admin/smoke tokens and decide whether to rewrite pushed history containing them (commit 9311a0d on origin).
  evidence: High (verified): .env with live secrets was committed in 9311a0d which is pushed to origin; worktree is fixed (.env untracked + ignored) but history still exposes the credentials.
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/_bmad-output/implementation-artifacts/spec-4-4-rake-finalized-verdict.md`
  summary: Reset test-gitlab-server compose drift (17.5.5 in tree vs documented 16.11 seed pin) or document 17.5.5 as the new seed baseline.
  evidence: setup.sh never pins the image, so a re-run boots 17.5.5 instead of the README-pinned 16.11.10; evidence-summary documents the drift and the revert procedure but the reset was never executed.
