# Database engine modules

One file per engine. Adding support for a new database is a new file here plus
one word in `BGB_DB_ENGINES_KNOWN` in [`lib/db.sh`](../../lib/db.sh) — never an
edit to the orchestration.

## The rule every module must follow

```bash
restic backup --stdin-from-command --stdin-filename <path> -- <dump command>
```

`--stdin-from-command` makes restic **fail the whole backup when the dump command
exits non-zero**. The obvious alternative,

```bash
docker exec ... pg_dumpall | restic backup --stdin      # NEVER DO THIS
```

stores whatever bytes arrived before the failure as a perfectly valid snapshot
and reports success. A backup system that can silently record a truncated
database dump as healthy is worse than none, because it also removes the
pressure to have one.

Two more rules:

- **Never pre-compress a dump.** restic compresses already (repository format
  v2), and a plain SQL stream deduplicates across days at content-defined chunk
  boundaries. A gzip stream changes wholesale after the first differing byte,
  which multiplies repository growth.
- **Never put a credential in argv.** `/proc/<pid>/cmdline` is world-readable.
  Read the password inside the container from the container's own environment;
  that way bg-backup never stores a database credential at all.

## Interface

| Function | Contract |
|---|---|
| `db_<e>_aliases` | newline-separated alternative names this module also serves |
| `db_<e>_detect <container>` | exit 0 if this container runs the engine |
| `db_<e>_dump <container> <job> <run>` | stream the dump into restic |
| `db_<e>_counts <container>` | JSON object of per-object row counts, or empty |
| `db_<e>_restore <container>` | read a dump on stdin and load it |
| `db_<e>_verify_cmd <container>` | cheap readiness probe, exit 0 when ready |
| `db_<e>_notes` | one paragraph of operator notes, shown by `discover` |

### Detection

Match the **image** first, exclude the look-alikes (exporters, clients, admin
UIs), then confirm with an environment variable or an exposed port. Never guess
from the container **name**: a container called `postgres-backup` running alpine
is not a database, and treating it as one produces a failing dump every night
that somebody eventually silences.

### Result protocol

Set these before returning; the dispatcher reads them and they outrank the exit
code, because an exit code cannot express "dumped, but not consistently".

```bash
BGB_DB_RESULT="ok" | "degraded" | "failed" | "skipped"
BGB_DB_RESULT_REASON="free text shown to the operator"
BGB_DB_LAST_LOG="path to this attempt's log"
BGB_DB_LAST_SNAPSHOT="restic snapshot id"
```

`degraded` is the important one. Use it whenever the dump succeeded but cannot
be called consistent — and say why. A snapshot whose consistency is unknown is
exactly the silent state this tool exists to remove.

### Storage layout

```
/db/<engine>/<container>/<object>
```

The engine and container are derivable from the path, which is why the tag set
stays small (`kind=dbdump`, `db=<engine>`) and why `verify`, `dr` and `restore`
need no change when a new engine appears.

## Shipped engines

| Engine | Mechanism | Reports `degraded` when |
|---|---|---|
| `postgres` | `pg_dumpall --globals-only`, then `pg_dump -Fc` per database. Counts are taken inside the same exported transaction snapshot the dump used, so `verify` can assert exact equality. | the database list cannot be read |
| `mysql` | `mariadb-dump`/`mysqldump --single-transaction --quick --routines --triggers --events --hex-blob` | **MyISAM/Aria tables exist** — `--single-transaction` is InnoDB-only, so those tables are not in the transaction |
| `mongodb` | `mongodump --archive --oplog` | standalone deployment — `--oplog` needs a replica set |
| `redis` | `BGSAVE`, wait for `rdb_bgsave_in_progress` to clear and `rdb_last_save_time` to change, then store `dump.rdb` | — (skipped entirely when the instance is a pure cache) |
| `sqlite` | `.backup` / `VACUUM INTO` — never a file copy, WAL mode makes that inconsistent | a database file cannot be read |
| `influxdb` | 1.x `influxd backup -portable`, 2.x `influx backup`, both tarred to stdout | — (**3.x is refused**: no logical dump exists) |
| `clickhouse` | `BACKUP DATABASE ... TO Disk` when a backup disk is configured | **no backup disk** — the per-table fallback is not consistent across tables |
| `elasticsearch` | snapshot API into a registered `fs` repository, then that directory is tarred in | snapshot state `PARTIAL` |
| `mssql` | `BACKUP DATABASE ... TO DISK WITH CHECKSUM, COMPRESSION`, streamed and removed | — |

`elasticsearch` **fails** rather than degrades when `path.repo` is unset: a data
directory copy is not a usable backup (Lucene mmaps its segments), so there is
nothing honest to fall back to. It prints the exact compose change needed.

## Operator overrides

```yaml
labels:
  backup.bauer-group.com/engine: postgres   # force the engine
  backup.bauer-group.com/skip: "true"       # never dump this container
  backup.bauer-group.com/tier: critical     # louder reporting on failure
```

The label always wins over detection.

## Adding an engine

1. Copy the closest existing module.
2. Implement the seven functions.
3. Add the engine name to `BGB_DB_ENGINES_KNOWN` in `lib/db.sh` — order matters,
   more specific engines first.
4. If it shares a file with another engine, extend `db_engine_module`.
5. Add a row to the table above, and state plainly what it cannot guarantee.
