# Operations

What to actually do, and how often.

## The standing question

> When did this host last have a backup that was **proven to restore**?

```bash
bg-backup status
```

Not "did the job run" — a job that fails every hour has a very recent last run
and no backup at all. `status` reports freshness from the last **success**.

---

## Daily — automatic

| | |
|---|---|
| backup jobs | per `JOB_SCHEDULE` |
| `forget` | after each backup (metadata only, cheap) |
| notification on failure | Kuma / mail / Teams |

**Human effort: none.** If you are checking a dashboard daily, the alerting is
not doing its job.

## Weekly — automatic

| | |
|---|---|
| `check` | `BGB_CHECK_SCHEDULE`, default Wednesday 05:00 |
| rotating `--read-data-subset` | 1/30 of the repository per run |
| `prune` | Sunday 06:00, primary role only |
| `copy` to the secondary | if configured |

## Monthly — automatic, but read the result

| | |
|---|---|
| `verify` | restores a canary, samples real files, loads every database dump into a throwaway container and compares row counts |
| oldest-snapshot test | the copy you depend on in a ransomware scenario, and the one nobody ever tests |

```bash
bg-backup status | grep 'last proven'
```

## Quarterly — human

**A disaster-recovery rehearsal.** See
[runbooks/dr-rehearsal.md](runbooks/dr-rehearsal.md).

Restore into a throwaway VM using **only** the printed recovery sheet. Time it.
Record the RTO. Sign and date the sheet.

> If the rehearsal needs information not on the sheet, the sheet is wrong. That
> is a failed rehearsal, not a footnote.

Also quarterly:

- re-export the recovery bundle if anything changed
- confirm the escrow copies are still where they should be
- review which hosts share the bucket and whether their policies are still scoped

---

## Adding a host

[runbooks/onboarding-a-host.md](runbooks/onboarding-a-host.md). In short: a
dedicated MinIO service account scoped to its own prefix, vault entries, install,
`init`, `discover`, first backup by hand, **first restore proven**, then arm the
timers.

Do not bulk-enable. A backup tool that silently misconfigures ten hosts is worse
than one configured by hand.

## Adding a database

Nothing to do — `discover` finds it on the next run. Check what it reports:

```bash
bg-backup discover
```

If it reports **degraded** for that engine, read why. MyISAM tables, a standalone
MongoDB, a ClickHouse without a backup disk: each has a specific fix, and each is
a real gap until it is applied.

## When a job goes red

1. `bg-backup status` — which job, how old, what was the exit code
2. `bg-backup logs <job>` — the run's own log, redacted
3. exit code table in [exit-codes.md](exit-codes.md)
4. `bg-backup doctor` — most causes are a precondition, not a bug

**Do not `prune` while a `check` is failing.** Prune rewrites pack files and can
turn a recoverable inconsistency into an unrecoverable one.

**Exit 9 is the tool refusing to destroy data.** Read the message. Forcing it
with `--yes` is occasionally right and never the first move.

## Capacity

```bash
bg-backup stats --mode raw-data
bg-backup diff <yesterday> <today>      # why did it grow 40 GB
```

Three usual causes of unexpected growth:

- a new large path pulled in by a bind mount — check `discover`
- a pre-compressed dump defeating deduplication — `JOB_DB_DUMP_COMPRESS` must be 0
- image exports — `JOB_DOCKER_EXPORT_IMAGES=missing`, not `all`

`forget` frees nothing on its own; `prune` reclaims the space.

## Changing the schedule

```bash
bg-backup config edit --job docker
bg-backup schedule sync
```

`sync` also **removes orphaned timers** for jobs whose file was deleted.

Check for collisions afterwards — `doctor` fails when two quiescing jobs are
scheduled at the same time, because they will fight over the same containers.

## Upgrading

```bash
bg-backup self-update --check
bg-backup self-update
bg-backup self-update --rollback     # instant, flips the current symlink
```

For a fleet, bump the pinned version in the Ansible role instead. Deliberate
pinning is why no host takes a new backup tool on a routine `ansible-pull`.

## Decommissioning a host

```bash
bg-backup config export --out /secure/place/<host>.age    # before anything else
curl -fsSL .../install.sh | UNINSTALL=1 bash
```

The repository is **not** touched. Decide separately and deliberately how long
the snapshots stay — and remember they still cost money.

---

## The cadence that actually matters

| | |
|---|---|
| every run | a failed dump fails the backup — enforced by `--stdin-from-command` |
| hourly | freshness, checked **externally** — a dead host cannot report it is dead |
| weekly | structural integrity |
| daily, rotating | 1/30 of the bytes actually read back |
| monthly | a dump proven to load, with matching row counts |
| quarterly | a human restores a host from a printed page |

Everything above the last line can pass while the last line fails. That is why it
is on the list.
