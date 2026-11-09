# Runbook: restoring GitLab from a `gitlab-backup` set

A set is one timestamped directory holding exactly two files: the sealed blob
`set.tar.age` and its hash `SHA256SUMS`. Blob and hash live, ship, verify, and
delete as a unit — never handle one without the other. Restore is manual and
deliberately so: it runs rarely, under stress, and every step below deserves a
human pair of eyes.

Demo status: this procedure is authored and reviewed; the live restore
demonstration against the test instance is an operator-executed step and is
still pending. Record the date and set timestamp here once performed.

## Prerequisites

- The set to restore, local or on the NAS.
- The NAS age **private** key, available **only on the NAS** (it must never
  exist on the GitLab host; the host holds only the public key path).
- An `age` binary, `sha256sum`, `tar`, and `docker`/`docker compose` on the
  machine performing the restore.
- The pinned version of GitLab from the set's compose recipe (see step 4).

## Restore procedure

1. Fetch the set as a unit. Copy the whole `<ts>/` directory (blob plus hash);
   never copy one file without the other.
2. Verify integrity before touching anything:
   `cd <ts> && sha256sum -c SHA256SUMS`. Proceed only if it passes.
3. Decrypt on a trusted machine: `age --decrypt -i <nas-private-key> -o
   set.tar set.tar.age`. (`age` refuses tampered ciphertext, so a successful
   decrypt is a second integrity proof on top of the hash.)
4. Unpack: `tar -xf set.tar`. This yields the native tarball
   (`<stamp>_gitlab_backup.tar`), `config/` (the whole `/etc/gitlab` volume),
   the compose file, and `.env`. Note the pinned image tag in the compose
   file — restore that exact GitLab version, never latest.
5. Stop the GitLab container, then restore the data with GitLab's native tool
   (`gitlab-backup restore`), following the version's official docs.
6. Restore `config/` over the config volume (`gitlab.rb`,
   `gitlab-secrets.json`, TLS certs, SSH host keys), and the compose file plus
   `.env` to their documented paths.
7. Start the pinned-version stack (`docker compose up -d`), then verify: sign
   in, open a project, and confirm uploads and CI history are present.

## Operator responsibilities (explicitly out of the script's scope)

- **Key custody.** The NAS private key lives only on the NAS, with a tested
  backup of its own. The GitLab host must never hold it or a copy of it.
- **NAS provisioning.** The NAS VM, its backup user, its SSH key auth, and the
  remote directory tree exist before the first run; the script creates nothing
  remotely except its own staging directory.
- **Scheduler setup.** The script contains no timing logic. Invoke it from the
  external scheduler (or by hand pre-migration); capture stdout/stderr in the
  scheduler's logs — `FAIL:<STAGE>` lines are the alert source.
- **Retention enforcement.** The script keeps the newest 2 local sets only.
  Broader horizons (7 daily, 4 weekly, 3-6 monthly on the NAS, plus encrypted
  off-site weeklies) are enforced by operators and schedulers around it, and
  always delete blob plus hash together.
- **Freshness and fitness.** Whether a set is fresh or fit for a given purpose
  is judged by its consumers (notably the upgrade runner's pre-migration
  check), never by this producer.
