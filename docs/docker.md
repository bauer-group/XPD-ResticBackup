# Docker and databases

## Why not `/var/lib/docker`

The obvious approach — stop Docker, back up `/var/lib/docker`, restore it — fails
the requirement this tool exists for: **restoring onto a freshly installed
machine**.

| Problem | Consequence |
|---|---|
| overlay2 layout is tied to the Docker version and storage driver | a restore onto a newer Docker, or one using a different driver, may not start |
| `systemctl stop docker` SIGKILLs containers after a timeout | PostgreSQL and MySQL come back through **crash recovery**, which is not the same as a consistent backup |
| the image store is duplicated data | the backup is several times larger for content the registry already has |
| compose files live outside `/var/lib/docker` | the thing needed to rebuild the stack is not in the backup at all |

So bg-backup backs up what a restore actually needs:

```
compose files + .env + every resolved env_file
named volume contents
bind-mount sources
image DIGESTS          (not tags)
network SUBNETS
logical database dumps
```

A restore is then: install Docker → restore files → `compose pull && up` → load
dumps. That works on any host. See
[ADR-0004](adr/0004-application-level-docker-backup.md).

### Two details that look minor and are not

**Digests, not tags.** `compose up` re-resolves `:latest`. Without a pinned
digest, a restore silently brings up a different version than the one the data
was written by.

**Network subnets.** If they are not recreated explicitly, Docker assigns new
ones from its address pool, and every firewall rule or ACL that referenced the
old subnet stops matching — silently.

### Images that exist only on this host

An image built locally and never pushed cannot be pulled during a restore.
`bg-backup discover` warns about each one. `JOB_DOCKER_EXPORT_IMAGES=missing`
(the default) exports exactly those into the repository via `docker save`,
streamed through `--stdin-from-command` so a failing save aborts rather than
storing a truncated tar.

With `EXPORT_IMAGES=none` those stacks are **not restorable**, and `doctor` says
so.

---

## Consistency

### The ladder

| Mode | Mechanism | Downtime | Consistency |
|---|---|---|---|
| `none` | live copy | none | none guaranteed |
| `dump` | logical dump — automatic for detected databases | none | **exact** (transactional) |
| `docker-pause` | `docker pause` only the project being read | seconds | crash-consistent |
| `docker-stop` | `compose stop` for that project | minutes | clean |
| `service-stop` | `systemctl stop <units>` | minutes | clean |
| `lvm` / `btrfs` / `zfs` | freeze → block snapshot → thaw → back up the snapshot | **none** | crash-consistent |

Default for the docker job: **dumps for databases, `docker-pause` for the file
part**. The dumps run first, while everything is still running — a logical dump
needs a live server and is transactionally consistent in its own right, so it
does not need the freeze window.

### The filesystem-snapshot path

The only mode that is both consistent and downtime-free:

```
fsfreeze -f <mount>     flush and block writers - held for MILLISECONDS
lvcreate --snapshot
fsfreeze -u <mount>     thaw immediately
mount the snapshot OVER the original path in a PRIVATE mount namespace
restic backup <path>
```

Two things decide whether this works:

`fsfreeze` must never be held for the backup's duration. A frozen filesystem
blocks every writer on the machine, so a 40-minute backup becomes a 40-minute
outage — worse than the `docker-stop` it replaces.

The snapshot is mounted **over the original path**, so the paths restic stores are
the production paths. Backing up `/mnt/snap/var/lib/docker` instead would produce
a snapshot whose contents restore to the wrong place, and nobody notices until a
restore.

`bg-backup discover` reports whether LVM/btrfs/ZFS is available and whether the
volume group has room. An LVM snapshot that runs out of copy-on-write space is
dropped by the kernel mid-backup, and restic then reads I/O errors from a device
that used to work — so the space check happens up front.

### Reversal is guaranteed three ways

See [Architecture](architecture.md#quiesce-reversal). The short version: the exit
trap, a state file in `/run` replayed on the next start, and `ExecStopPost=` in
the systemd unit — which runs even when the process was SIGKILLed.

---

## Databases

### The rule

```bash
restic backup --stdin-from-command --stdin-filename /db/<engine>/<container>/<obj> -- <dump>
```

`--stdin-from-command` **fails the whole backup when the dump command exits
non-zero**. The alternative,

```bash
docker exec ... pg_dumpall | restic backup --stdin      # NEVER
```

stores whatever bytes arrived before the failure as a valid snapshot and reports
success.

Dumps are never pre-compressed: restic compresses already, and plain SQL
deduplicates across days at content-defined chunk boundaries while a gzip stream
changes wholesale after the first differing byte.

No credential ever reaches bg-backup. Each engine reads the password inside the
container from the container's own environment, so it is not in bg-backup's
config, not in argv, and not in `/proc/<pid>/cmdline`.

### Detection

Image name first, then confirmation by environment variable or exposed port.
Never the container **name** — a container called `postgres-backup` running alpine
is not a database, and treating it as one produces a failing dump every night that
somebody eventually silences.

Override per container:

```yaml
labels:
  backup.bauer-group.com/engine: postgres
  backup.bauer-group.com/skip: "true"
  backup.bauer-group.com/tier: critical
```

### What each engine can and cannot guarantee

| Engine | Mechanism | Reports **degraded** when |
|---|---|---|
| PostgreSQL | `pg_dumpall --globals-only`, then `pg_dump -Fc` per database | the database list cannot be read |
| MySQL / MariaDB | `--single-transaction --quick --routines --triggers --events --hex-blob` | **MyISAM or Aria tables exist** |
| MongoDB | `mongodump --archive --oplog` | **standalone** deployment |
| Redis | `BGSAVE`, wait, then `dump.rdb` | — (skipped when it is a pure cache) |
| SQLite | `.backup` / `VACUUM INTO` | a file cannot be read |
| InfluxDB | 1.x `influxd backup -portable`, 2.x `influx backup` | — (**3.x refused**) |
| ClickHouse | `BACKUP DATABASE … TO Disk` | **no backup disk** configured |
| Elasticsearch | snapshot API into a registered `fs` repository | snapshot state `PARTIAL` |
| MSSQL | `BACKUP DATABASE … WITH CHECKSUM, COMPRESSION` | — |

**`degraded` is treated as a failure.** "A snapshot exists but its consistency is
not guaranteed" is exactly the silent state this tool exists to remove.

### The caveats worth knowing before you need them

**MySQL `--single-transaction` is InnoDB-only.** MyISAM and Aria tables are not
in the transaction, so the dump is internally inconsistent for them. The engine
detects those tables and reports degraded rather than pretending.

**MongoDB `--oplog` needs a replica set.** On a standalone deployment the dump is
taken without one, so writes during the dump may be partially captured.

**PostgreSQL globals come first.** A dump without roles and grants restores a
database nobody can log into. They are a separate object, restored before any
per-database dump — otherwise the restore GRANTs to roles that do not exist yet,
and PostgreSQL reports that as warnings rather than an error, so it looks like it
worked.

**Exact row counts, for PostgreSQL.** The counts used by `verify` are taken inside
the *same* exported transaction snapshot the dump used:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT pg_export_snapshot();     -- passed to pg_dump --snapshot=
```

That makes the post-restore comparison a hard equality rather than a tolerance.
Other engines capture counts immediately after the dump, with a documented
tolerance.

**Elasticsearch needs a compose change first.** A data-directory copy is not a
usable backup — Lucene mmaps its segments. The snapshot API is the only supported
mechanism and it requires `path.repo`, which means editing the compose file and
restarting the service **before** any correct backup is possible. The engine fails
with the exact change needed rather than falling back to something that cannot
restore.

**InfluxDB 3.x is refused.** It has no logical dump; the correct backup is a
snapshot of its object store. Pretending would be worse than an honest error.

### One dump or one datadir, never both

If a database's data directory is restored *and* its dump is loaded, the official
entrypoint sees a non-empty data directory, skips initialisation, and the dump is
applied on top of live data. The tool refuses the combination.

---

## Restoring

```bash
bg-backup runs list                                  # pick a complete run
bg-backup restore project --name mystack --run <id>  # compose files + volumes
bg-backup restore volume  --name pg_data --run <id>
bg-backup restore db --db postgres/pg/app.dump --into pg
bg-backup dump <snap> /db/postgres/pg/app.dump | pg_restore -d app
```

Restore **by run**, not by "latest" per snapshot — see
[Architecture](architecture.md#runs-not-snapshots).

`restore volume` refuses while a container is using the volume, offers to stop
and restart the consumers, and swaps `…/volumes/<name>/_data` by rename rather
than renaming the volume object (Docker cannot rename volumes; this keeps the
driver, options and labels intact).
