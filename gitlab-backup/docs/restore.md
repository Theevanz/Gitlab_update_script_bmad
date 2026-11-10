# Runbook: restoring GitLab from a `gitlab-backup` set

A set is one timestamped directory holding exactly two files: the sealed blob
`set.tar.age` and its hash `SHA256SUMS`. Blob and hash live, ship, verify, and
delete as a unit — never handle one without the other. Restore is manual and
deliberately so: it runs rarely, under stress, and every step below deserves a
human pair of eyes.

Demo status: backup pipeline verified 2026-11-10 (set 20261110-024852
sealed locally and on the NAS, `sha256sum -c` OK both sides); live restore
demonstrated 2026-11-10 from set 20261110-024852 (database + repositories
restored, config verified byte-identical, services restarted, UI check
passed — post-restore data confirmed gone).

## Prerequisites

- The set to restore, local or on the NAS.
- The NAS age **private** key, available **only on the NAS** (it must never
  exist on the GitLab host; the host holds only the public key path).
- An `age` binary, `sha256sum`, `tar`, and `docker`/`docker compose` on the
  machine performing the restore.
- The pinned version of GitLab from the set's compose recipe (see step 4).

## Restore procedure

1. Fetch the set as a unit onto the NAS (it normally already lives there as
   `<ts>/` under the NAS backup root). Never copy one file without the other.
2. Verify integrity on the NAS before touching anything:
   `cd <ts> && sha256sum -c SHA256SUMS` — expect `set.tar.age: OK`.
   Proceed only if it passes.
3. Decrypt on the NAS — the private key never leaves it:
   `age --decrypt -i <nas-private-key> -o set.tar set.tar.age`. (`age`
   refuses tampered ciphertext, so a successful decrypt is a second
   integrity proof on top of the hash.)
4. Copy `set.tar` to the GitLab host over SSH and unpack it there:
   `tar -xf set.tar`. This yields the native tarball
   (`<stamp>_gitlab_backup.tar`), `config/` (the whole `/etc/gitlab` volume),
   the compose file, and `.env`. Note the pinned image tag in the compose
   file — restore that exact GitLab version, never latest.
5. Stop Puma and Sidekiq inside the running container — do not stop the
   container itself, the restore runs via `docker exec`:
   `docker exec -it <container> gitlab-ctl stop puma` and
   `docker exec -it <container> gitlab-ctl stop sidekiq`.
   Copy the native tarball into the data volume's `backups/` dir with
   container-readable ownership, then restore:
   `docker exec -it <container> gitlab-backup restore BACKUP=<stamp>`
   (`<stamp>` is the tarball name minus `_gitlab_backup.tar`; answer `yes`
   twice — `-i` is required so your answers reach the prompt).
6. Restore `config/` over `GITLAB_CONFIG_DIR` (`gitlab.rb`,
   `gitlab-secrets.json`, TLS certs, SSH host keys), and the compose file plus
   `.env` beside `COMPOSE_FILE` (a missing `.env` there fails the next backup
   with `FAIL:BUNDLE`).
7. Start the services back (`docker exec -it <container> gitlab-ctl start
   puma` and `... start sidekiq`), wait ~3 minutes, then verify: sign in,
   open a project, and confirm uploads and CI history are present
   (`test-gitlab-server/healthcheck.sh` also covers container + endpoints +
   admin API).
8. Wipe the plaintexts: delete `set.tar` and the unpacked files on the GitLab
   host, and `set.tar` on the NAS. The sealed set stays as it was.

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

## POC operating notes (test checkout, 2026-11-10)

- Container: `test-gitlab-server` (`gitlab/gitlab-ce:17.5.5-ce.0`, healthy).
- NAS: `192.168.124.115`, user `backup`, remote root `/backups/gitlab`.
- Keys live on the host under `test-gitlab-server/keys/`: Ed25519 SSH private
  (600) for transport, single-`age1`-line public file for encryption.
- Run with `sudo`: volume files are owned by `nobody` with mode `600`,
  and the NAS host key is in root's `known_hosts`.
