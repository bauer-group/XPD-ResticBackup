# Configuration

```
/etc/bg-backup/
├── bg-backup.conf              global settings                    0640
├── conf.d/
│   ├── 10-system.conf          one file per job                   0640
│   ├── 20-docker.conf
│   └── 90-config.conf
├── credentials/                                                   0700
│   ├── repo.env                repository URL + backend keys      0400
│   ├── repo.key                the passphrase                     0400
│   └── notify.env              webhook URLs and tokens            0400
├── excludes/*.exclude
└── hooks/<job>/{pre.d,post.d}/*.sh                                0750
```

**Precedence:** built-in defaults → `bg-backup.conf` → `conf.d/<job>.conf` →
environment → command-line flags.

```bash
bg-backup config show --job docker --resolved
```

## Format

Shell-sourced `KEY=VALUE` plus bash arrays. Not YAML — `yq` is not an Ubuntu
package, and a parser dependency in the disaster-recovery path is the wrong
dependency in the wrong place. Arrays map one-to-one onto restic's argv, which is
the only safe way to carry paths containing spaces.

Sourcing a file is executing it as root, so three gates run **before** the file
is sourced:

1. **Ownership and mode.** Root-owned, not more permissive than the maximum.
   A refusal, not a warning — a warning gets ignored.
2. **Key whitelist.** An explicit list, not a prefix pattern. `JOB_KEEP_DIALY`
   is an error. Under a prefix pattern it would be accepted, the real
   `JOB_KEEP_DAILY` would keep its default, and retention would quietly do
   something other than what the file says. Nothing errors, and nobody finds out
   until a snapshot they expected has been forgotten.
3. **No command substitution.** `$(...)` and backticks are rejected outright.

```bash
bg-backup config validate --strict
bg-backup config edit --job docker     # validates before installing
```

Adding a setting to the tool means adding its name to the whitelist in
`lib/config.sh`. That friction is deliberate on a file whose typos are silent.

---

## Global settings

### Identity and repository

| Key | Default | Notes |
|---|---|---|
| `BGB_HOSTNAME` | FQDN | **Keep stable.** Retention and restore filters key off it; changing it orphans every previous snapshot — they stop matching `forget --host`, so they are never pruned and never found by name. |
| `BGB_REPO_ENV` | `…/credentials/repo.env` | |
| `BGB_REPO_ROLE` | `primary` | Only a `primary` host may `prune`. Every other host writing into the same bucket **must** be `secondary`, or two hosts can rewrite pack files concurrently. |
| `BGB_SECONDARY_REPO_ENV` | — | Copy target. It must have been created with `restic init --from-repo <primary> --copy-chunker-params`; without matching chunker parameters the copy re-chunks everything, deduplication collapses, and the second repository can end up several times larger. |

### Engine

| Key | Default | Notes |
|---|---|---|
| `BGB_RESTIC_BIN` | `/usr/local/bin/restic` | |
| `BGB_RESTIC_MIN_VERSION` | `0.17.0` | The floor. Below it, exit codes 10/11/12 collapse into 1 and alerts cannot be triaged. Distribution packages are too old: 22.04 ships 0.12.1, 24.04 ships 0.16.4. |
| `BGB_COMPRESSION` | `auto` | `auto` \| `off` \| `max` |
| `BGB_LIMIT_UPLOAD_KIB` / `_DOWNLOAD_` | `0` | 0 = unlimited |
| `BGB_READ_CONCURRENCY` | — | Lower it on spinning disks |

### Runtime

| Key | Default | Notes |
|---|---|---|
| `BGB_LOCK_WAIT_SECONDS` | `1800` | How long a job waits for the repository lock before exit 5 |
| `BGB_PARALLEL_JOBS` | `0` | Keep 0. Concurrent jobs thrash I/O, and two quiescing jobs fight over the same containers. |
| `BGB_NICE` / `BGB_IONICE_*` | `10` / best-effort 7 | Overridden per job by `JOB_PRIORITY` |
| `BGB_RETRY_ATTEMPTS` | `3` | **Transient network failures only.** A failed dump or hook is never retried: retrying hides the failure it exists to surface. |

### Retention defaults

| Key | Default |
|---|---|
| `BGB_DEFAULT_KEEP_LAST` | `3` |
| `BGB_DEFAULT_KEEP_DAILY` | `30` |
| `BGB_DEFAULT_KEEP_WEEKLY` | `8` |
| `BGB_DEFAULT_KEEP_MONTHLY` | `6` |
| `BGB_KEEP_TAG` | `keep-forever` — snapshots with this tag are never removed |

### Safety rails

`forget` is the only irreversible path, and the bucket is shared.

| Key | Default | What it prevents |
|---|---|---|
| `BGB_FORGET_MIN_SNAPSHOTS` | `5` | Refuse if fewer would remain |
| `BGB_FORGET_MAX_DELETE_PERCENT` | `50` | Refuse if more than this share would go; override once with `--yes` |
| `BGB_PRUNE_MAX_UNUSED` | `5%` | |

Two rails are not configurable because they are correctness, not policy: every
`forget` is scoped `--host <fqdn> --tag job=<name> --group-by host,tags`, and a
configuration with no `keep-*` at all is **rejected** rather than read as "keep
nothing".

### Monitoring

| Key | Default | Notes |
|---|---|---|
| `BGB_MONITOR_ON` | `failure` | `always` \| `failure` \| `never` |
| `BGB_NOTIFIERS` | `uptime-kuma prometheus email teams` | Dispatch order |
| `BGB_MONITOR_KUMA_PUSH_URL` | — | The dead-man's switch |
| `BGB_MONITOR_MAIL_TO` | — | **Failures only** — a daily success mail is a filter rule within a week |
| `BGB_MONITOR_TEAMS_WEBHOOK_URL` | — | Treat as a credential |
| `BGB_METRICS_TEXTFILE` | node_exporter path | Written atomically |
| `BGB_NOTIFY_INCLUDE_PATHS` | `0` | Filenames are an information disclosure; counts are the useful part |

### Maintenance schedules

| Key | Default |
|---|---|
| `BGB_CHECK_SCHEDULE` | `Wed *-*-* 05:00:00` |
| `BGB_CHECK_READ_DATA_SUBSET` | `2%` — rotating, full coverage every 30 runs |
| `BGB_PRUNE_SCHEDULE` | `Sun *-*-* 06:00:00` — never inline with a backup |
| `BGB_VERIFY_SCHEDULE` | `*-*-01 07:00:00` |

---

## Job settings

The job name comes from the file name: `10-system.conf` → `system`. The numeric
prefix controls order under `backup --all`.

### Sources

```bash
JOB_PATHS=( / )
JOB_EXTRA_PATHS=( /var/lib/docker )
JOB_ONE_FILE_SYSTEM=1
```

> ⚠️ **The `--one-file-system` trap.** It stops restic wandering into NFS mounts
> and USB media — and it also **skips anything on its own filesystem**. If
> `/var/lib/docker` is a separate mount, a root job silently omits it. Add such
> mounts to `JOB_EXTRA_PATHS`. `bg-backup doctor` checks for exactly this.

### Exclusions

```bash
JOB_EXCLUDE_FILE="/etc/bg-backup/excludes/system.exclude"
JOB_EXCLUDES=()
JOB_EXCLUDE_CACHES=1              # honour CACHEDIR.TAG
JOB_EXCLUDE_LARGER_THAN="2G"
JOB_EXCLUDE_IF_PRESENT=".nobackup"
```

Excludes do **not** apply to a path passed explicitly as a source.

### Consistency

```bash
JOB_QUIESCE="docker-pause"
JOB_QUIESCE_UNITS=( postgresql.service )
JOB_QUIESCE_SCOPE="project"       # project | host
JOB_QUIESCE_MAX_SECONDS=300
JOB_SNAPSHOT_SIZE="10G"           # LVM copy-on-write space
```

| Mode | Downtime | Consistency |
|---|---|---|
| `none` | none | none guaranteed |
| `docker-pause` | seconds | crash-consistent |
| `docker-stop` | minutes | clean |
| `service-stop` | minutes | clean |
| `lvm` / `btrfs` / `zfs` | **none** | crash-consistent |

`JOB_QUIESCE_MAX_SECONDS` is a hard cap: exceeded, the run is aborted and
services are restored. A missed backup is recoverable tomorrow; an unbounded
outage is not.

### Schedule and priority

```bash
JOB_SCHEDULE="*-*-* 02:30:00"     # systemd OnCalendar, validated at load time
JOB_RANDOM_DELAY="1800"
JOB_TIMEOUT="12h"                 # RuntimeMaxSec
JOB_PRIORITY="low"                # low | normal | high
```

| `JOB_PRIORITY` | Nice / IO | Use for |
|---|---|---|
| `low` | 10 / best-effort 7 | non-quiescing jobs |
| `normal` | 5 / best-effort 4 | `docker-pause` — do not stretch a freeze window |
| `high` | 0 / best-effort 0 | `docker-stop` — **never throttle a job holding a service down** |

`IOSchedulingClass=idle` is never used: on a busy host the backup can starve
indefinitely and the next timer run collides with the still-running previous one.

### Retention

Empty means inherit the global default.

```bash
JOB_KEEP_LAST="3"  JOB_KEEP_DAILY="14"  JOB_KEEP_WEEKLY="8"  JOB_KEEP_MONTHLY="6"
JOB_FORGET_AFTER_BACKUP=1         # cheap, metadata only
JOB_PRUNE_AFTER_BACKUP=0          # expensive - leave it to the prune timer
```

### Hooks

```bash
JOB_PRE_HOOKS=( /opt/bg-backup/current/share/hooks/collect-system-facts.sh )
JOB_POST_HOOKS=()
JOB_HOOK_FAILURE="abort"          # abort | warn
```

Also every executable in `/etc/bg-backup/hooks/<job>/{pre,post}.d/`, in lexical
order. Hooks get a **scrubbed environment**: `BGB_JOB`, `BGB_PHASE`,
`BGB_HOSTNAME`, `BGB_RUN_ID`, `BGB_JOB_MODE` — and deliberately no backend
credentials. A hook needing repository access sources them itself, visibly.

### Alerting

```bash
JOB_ALERT_MAX_AGE_HOURS=30
JOB_PARTIAL_IS_FAILURE=0
```

Exit 3 means "snapshot written, some files unreadable". During a **live** run
that is normal — rotating logs, sockets. During a **quiesced** run it means files
were unreadable with services stopped, which is a real signal. Same exit code,
different meaning: set `JOB_PARTIAL_IS_FAILURE=1` on quiesced jobs.

### Docker mode

```bash
JOB_MODE="docker"
JOB_DOCKER_INCLUDE_NAMED_VOLUMES=1
JOB_DOCKER_INCLUDE_BIND_MOUNTS=1
JOB_DOCKER_IMAGE_MANIFEST=1
JOB_DOCKER_NETWORK_MANIFEST=1     # subnets - see below
JOB_DOCKER_EXPORT_IMAGES="missing"
JOB_DOCKER_INCLUDE_OVERLAY2=0
JOB_DB_DUMP=1
JOB_DB_ENGINES=( postgres mysql mariadb mongodb redis )
JOB_DB_DUMP_COMPRESS=0
JOB_DB_RECORD_COUNTS=1
```

`JOB_DOCKER_EXPORT_IMAGES=missing` exports only images with no registry digest —
built locally, never pushed, and therefore unrecoverable. `discover` warns when
it finds one.

`JOB_DOCKER_NETWORK_MANIFEST` looks cosmetic and is not: without the recorded
subnets, a restore lets Docker assign new ones from its address pool, and every
firewall rule or ACL that referenced the old subnet silently stops matching.

`JOB_DB_DUMP_COMPRESS=0` is deliberate. restic compresses already, and plain SQL
deduplicates across days at content-defined chunk boundaries; a gzip stream
changes wholesale after the first differing byte.

---

## Container labels

```yaml
labels:
  backup.bauer-group.com/engine: postgres
  backup.bauer-group.com/skip: "true"
  backup.bauer-group.com/tier: critical
```

The label always wins over detection.

## Credentials

`repo.env` is a plain sourceable shell fragment on purpose:

```bash
source /etc/bg-backup/credentials/repo.env && restic snapshots
```

That is a design goal — the tool must never be required to read its own backups.

The **passphrase is not in it**. It lives in `repo.key` (0400) and is reached via
`RESTIC_PASSWORD_FILE`, because `--stdin-from-command` and every hook spawn child
processes that inherit this environment. An inline `RESTIC_PASSWORD` would be
readable by every database dump command the tool runs.

systemd units use `LoadCredential=`, not `EnvironmentFile=`: the latter merges
values into the unit environment, which systemd exposes to any local user via
`systemctl show -p Environment`.
