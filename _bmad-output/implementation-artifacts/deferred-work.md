- source_spec: none
  summary: Execute demo-runbook live hops (16.11→17.1→17.3→17.5) plus postgres-stop hang injection and capture Story 4.4 evidence.
  evidence: Split from seed-first scope; demo execution waits on test-gitlab-server/ seed env existing (decisions recorded in spec-4-4-demo-runbook.md).
- source_spec: `/home/admin/Desktop/reeve/deliverable-gitlab-update/_bmad-output/implementation-artifacts/spec-4-4-demo-runbook.md`
  summary: Rotate GitLab root password + admin/smoke tokens and decide whether to rewrite pushed history containing them (commit 9311a0d on origin).
  evidence: High (verified): .env with live secrets was committed in 9311a0d which is pushed to origin; worktree is fixed (.env untracked + ignored) but history still exposes the credentials.
