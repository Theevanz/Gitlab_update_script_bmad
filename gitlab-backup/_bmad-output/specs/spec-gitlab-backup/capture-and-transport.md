# Capture and transport — how a set is produced and shipped

- Native capture: `gitlab-backup create STRATEGY=copy`. The copy strategy duplicates live data aside so the archived set is frozen. `gitlab-backup` is the 12.2+ command, verified 12.2+ through 19.x; `gitlab-rake gitlab:backup:create` is the legacy spelling. The live data volume itself is never copied — inconsistent under a running server.
- Bundle + seal: `tar` bundles tarball + config volume + compose file + `.env` into one set archive; `age` (single static binary invoked from bash — same standing as `rsync`/`ssh`/`sha256sum`: bash orchestrates, tools execute) seals it with exactly one invocation. Portable and air-gap friendly by vendoring the binary. The NAS `age` public key is supplied out-of-band before the first run.
- Transport: rsync from the GitLab host to the NAS backup server over SSH with key auth.
- Verification order: presence check first, then hash re-verification; the hash ships beside the blob.
- Environment: two servers (GitLab host + backup/NAS box); backup stays on-prem; GitLab is Docker-hosted. The NAS is a VM to be provisioned; the build machine acts as the GitLab box. Local sets land in `test-gitlab-server/backups/` beside `docker-compose.yml` (testing/POC placement).
