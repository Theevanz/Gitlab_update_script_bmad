---
title: "PRD: gitlab-backup"
status: draft
created: 2026-11-03
updated: 2026-11-03
---

# PRD: gitlab-backup

## Goal

One command that either produces a complete, verifiable backup set of the
Docker-hosted on-prem GitLab instance or fails loudly — the rollback path the
stepwise upgrade runner requires before any migration step. Two guarantees,
and only what delivers them: confidentiality (the whole set sealed with `age`) and integrity
(one SHA-256 over the sealed set). Solo learning artifact: every step must be
explainable, and simplicity wins every tiebreak.

## Users

- **Operator:** runs one command by hand or under an external scheduler; gets a
  trustworthy set or a loud failure.
- **Upgrade runner (consumer):** needs a fresh, complete, verifiable set before
  every migration stop. The checks it runs are its own business (parent
  deliverable).
- **Mentor (grader):** reads audit-grade bash; every step explainable.

## Scope

**In (v1):** native capture (`STRATEGY=copy`); config-volume + compose + env assembly;
bundle-then-encrypt (tar into one archive, exactly one `age` invocation); single SHA-256 over
the blob; rsync-over-SSH shipment; post-trip re-verification; newest-2 local
retention as units; loud all-or-nothing failure.

**Out (v1):** scheduling; live data-volume copies (inconsistent under a running
server — the tarball is the capture); automated restore (stays manual/documented);
retention-horizon enforcement and off-site copies (declared policy, enforced
elsewhere); log backup; inner/per-artifact hashes; parent-deliverable changes
(`backup-contract.md` v2, runner checks); NAS VM provisioning.

## Functional requirements

A set is one timestamped directory holding exactly one encrypted blob plus one
hash file.

**Capture**

- FR-1: The run captures live GitLab data (database, repositories, uploads, CI
  data) via native `gitlab-backup create STRATEGY=copy` into a native tarball.
  The live data volume is never copied — the tarball is the only data capture.
- FR-2: The run copies the whole config volume that is mounted to docker container(host-side bind path supplied via
  config — holds `gitlab.rb`, `gitlab-secrets.json`, TLS certs, SSH host keys)
  for sealing. The volume is the unit; no file pick-list.
- FR-3: The sealed set carries the compose file and `.env` byte-identical to source
  (the pinned-version recipe).

**Bundle + seal**

- FR-4: The run tars tarball(From gitlab for its data) + config volume(gitlab configs) + compose file + `.env` into one set archive and seals
  it with exactly one `age` invocation to the out-of-band NAS public key, then
  wipes the plaintexts.
- FR-5: No plaintext (data or secrets) leaves the GitLab host; the NAS private
  key never exists on the host.

**Integrity**

- FR-6: The run writes one SHA-256 over the sealed blob (`sha256sum -c`
  format) after encryption. No inner hashes — the blob hash transitively covers
  the sealed contents (same blob, same tar, same files), and `age` refuses
  tampered ciphertext.

**Ship + verify**

- FR-7: The run ships blob + hash to the NAS over rsync/SSH key auth as one
  unit; a ship delivering only one of the two files is a failure per FR-10,
  with the partial remote file removed.
- FR-8: The run re-verifies the hash on the NAS before reporting success.

**Retain + fail**

- FR-9: After a verified ship, the newest 2 local sets remain (dirname order);
  losers are deleted whole, never piecemeal; prune never runs unless the
  current set shipped and verified.
- FR-10: Any step failure exits non-zero naming the step and leaves no partial
  set behind, local or remote.
- FR-11: Single invocation, scheduler-agnostic (identical by hand or cron);
  environment-supplied config, validated up front.

## Non-functional requirements

- NFR-1 (explainability): bash-only, no Python; one named function per stage;
  every tool call commented.
- NFR-2 (boundaries): no scheduler logic, no retry logic duplicating tool
  flags, no NAS-side logic, no consumer-specific checks (freshness and fitness
  are judged by consumers).
- NFR-3 (portable): on-prem across two servers; static binaries vendored where
  needed for air-gap vetting.

## Success + counter-metrics

- SM-1: A run yields blob + matching hash locally and on the NAS, or exits
  non-zero naming the failure.
- SM-2: An induced failure at each stage (capture, bundle, encrypt, hash, ship,
  prune, plus config-validation and lock-contention cases) produces a named
  failure with nothing partial left behind.
- SM-3: A restore from a produced set is demonstrated at least once against the
  test instance (manual).
- CM-1 (counter-metric): any design needing per-artifact handling after seal
  (extra hashes, sidecars, per-file logic) is rejected as drift.

## Dependencies

- NAS `age` public key plus NAS/SSH/container/config paths, supplied
  out-of-band before the first run (build inputs, not PRD gaps).
- Parent deliverable: `backup-contract.md` v2 + runner check (existence,
  freshness ≤24h, completeness (both files present, hash re-verified)) — not this build.
- Sealed blob `set.tar.age` + `SHA256SUMS`, both filenames pinned by ARCH
  (the exact-bytes hash pin requires fixed names).

## Open questions

None blocking. Out-of-band values above are build inputs.
