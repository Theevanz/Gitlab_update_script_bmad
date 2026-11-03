# Retention policy — declared horizons (enforcement explicitly out of scope)

This file declares policy only. The script enforces nothing here except the local 2 sets (CAP-6); everything else is owned by operators and schedulers around it.

- GitLab host: latest 2 sets (ship buffer + fast local restore).
- Backup server: 7 daily, 4 weekly, 3–6 monthly. Disk need ≈ one-set size × sets kept — measure a real tarball first.
- One set, one timestamp: blob and hash file are deleted together, never piecemeal.
- Rationale for depth: mistakes surface late (e.g. a project deleted last week).
- Off-site (3-2-1): ship only weekly/monthly sets, encrypted.
