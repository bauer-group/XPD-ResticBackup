# Repository layout

## One repository per host, inside a shared bucket

```
s3://backup-server/
├── host-a.example.com/     ← a complete, independent restic repository
│   ├── config
│   ├── data/
│   ├── index/
│   ├── keys/
│   ├── locks/
│   └── snapshots/
├── host-b.example.com/
└── host-c.example.com/
```

Each prefix is a separate repository with its own keys, index and deduplication
domain. That contains the blast radius: a compromised host holds a credential
scoped to one prefix, and its `forget` cannot reach another host's snapshots.

The cost is real and worth stating: **no deduplication across hosts.** For a
fleet of near-identical Ubuntu servers that is meaningful storage. It is
recovered on the pull-side copy repository, where a shared repository is safe
precisely because no production host holds its credentials. See
[ADR-0010](adr/0010-one-repository-per-host-in-a-shared-bucket.md).

> The prefix **must** end with the host's FQDN. `bg-backup doctor` fails if it
> does not. A copied-and-pasted prefix is how one host's retention silently
> deletes another host's backups.

## What a backup run writes

One run produces several snapshots:

| Path | Tags | Contents |
|---|---|---|
| the job's source paths | `kind=files` | the file tree |
| `/db/<engine>/<container>/<object>` | `kind=dbdump`, `db=<engine>` | one logical dump |
| `/images/<image>.tar` | `kind=image`, `image=<ref>` | an image that exists nowhere else |

All of them carry:

```
bg-backup=1        this tool wrote it
host=<fqdn>        (restic's own --host field)
job=<name>         which job
run=<id>           which RUN - see below
```

## Runs

`run=<id>` is the tag that matters. Resolving "latest" per snapshot independently
would pair Monday's database dump with Tuesday's volume contents — each is
individually the newest of its kind, and together they are inconsistent.

```bash
bg-backup runs list
bg-backup runs show 20260802T031500Z-a7f3k2
bg-backup restore project --name mystack --run 20260802T031500Z-a7f3k2
```

The id is a UTC timestamp plus a random suffix: sortable, collision-resistant,
and readable in a log.

## Retrieving without bg-backup

```bash
export RESTIC_REPOSITORY='s3:https://…/backup-server/host.example.com'
export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…
export RESTIC_PASSWORD=…

restic snapshots
restic snapshots --tag run=20260802T031500Z-a7f3k2      # one complete run
restic snapshots --tag kind=dbdump

restic restore <snap> --target /mnt/restore
restic dump <snap> /db/postgres/pg/app.dump | pg_restore -d app
restic mount /mnt/browse
```

This is a design requirement, not a side effect: the tool must never be needed to
read its own backups.

## Keys

restic separates the **master key** (which encrypts the data) from **repository
keys** (passphrases that unwrap it). Rotating a passphrase is therefore O(1) and
touches no snapshot.

| Key | Passphrase lives | Purpose |
|---|---|---|
| `host:<fqdn>` | on the host, `0400` | routine backups |
| `ops:recovery` | **never on the host** — bundle, password manager, printed sheet | disaster recovery, and survives a host compromise |
| `ops:prune` | ops vault only | retention, from a management path |

```bash
restic key list
bg-backup secrets rotate-repo-password
```

> `restic key remove` does **not** re-encrypt the master key. Anyone who ever
> obtained the master key material keeps access to every existing snapshot. After
> a host compromise you need a **new repository**, not a rotated key. Rotation
> defends against a stolen password, not a stolen key.

## Locks

restic writes a lock object under `<prefix>/locks/` on every run and removes it
on exit. Consequences worth knowing:

- an S3 policy that denies `DeleteObject` outright breaks restic: every run
  leaves a stale lock, and by the third run the repository needs an `unlock`
  that also cannot succeed. Allow deletes **only** under `<prefix>/locks/*`.
- **S3 Object Lock does not work with restic.** A bucket default retention makes
  lock objects undeletable and the repository unusable within days. See
  [ADR-0009](adr/0009-no-s3-object-lock-with-restic.md).

```bash
bg-backup unlock              # shows who holds it before removing anything
```

## Size and growth

```bash
bg-backup stats --mode raw-data
bg-backup stats --mode restore-size
bg-backup diff <snap-a> <snap-b>        # why did it grow 40 GB last night
```

Growth is dominated by three things:

**Compression and dedup work on plain data.** Pre-compressed dumps defeat both,
which is why `JOB_DB_DUMP_COMPRESS=0`.

**`forget` frees nothing on its own.** It removes snapshot references; `prune`
rewrites pack files and reclaims space. `forget` is cheap and runs after each
backup; `prune` is expensive and runs on its own weekly timer.

**Image exports are large.** `JOB_DOCKER_EXPORT_IMAGES=missing` exports only what
no registry can supply.

## Second repository

```bash
restic init --from-repo <primary> --copy-chunker-params -r <secondary>
bg-backup copy
```

`--copy-chunker-params` is **mandatory**. Without matching chunker parameters
restic re-chunks every blob, deduplication against the primary is lost, and the
copy can end up several times larger.

The recommended shape is a **pull** job on a hardened host copying primary →
secondary, so no production host holds a credential for the secondary. That, not
Object Lock, is the practical ransomware control.
