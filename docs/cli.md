# CLI reference

```
bg-backup [global flags] <command> [subcommand] [flags] [args]
```

Global flags work **before and after** the command word, because operators type
them both ways under pressure.

## Global flags

| Flag | |
|---|---|
| `--config FILE` | alternate configuration file or directory |
| `--job NAME` | restrict to a job |
| `--json` | machine-readable on stdout; every message goes to stderr |
| `--quiet`, `-q` | suppress informational messages |
| `--verbose`, `-v` | debug logging |
| `--dry-run`, `-n` | show what would happen, change nothing |
| `--yes`, `-y` | assume yes — **required when unattended**, a prompt would hang |
| `--no-color` | `NO_COLOR` is honoured automatically |
| `--lock-wait SECONDS` | how long to wait for a held lock |
| `--no-lock` | skip locking — dangerous, never in a timer |
| `--version`, `--help` | |

**The `--json` contract:** stdout carries exactly one JSON document; every human
message goes to stderr. Every document begins with `"schema": 1`. The exit code
still carries the verdict — automation should check both.

---

## Setup

### `init`

Interactive wizard: backend, connectivity test, passphrase (generated if not
given), job seeding, optional independent recovery key.

| Flag | |
|---|---|
| `--repo URL` `--password-file F` `--generate-password` | |
| `--s3-key` `--s3-secret` `--s3-region` | |
| `--profile minimal\|server\|docker` | which jobs are seeded |
| `--non-interactive` | fail instead of prompting |
| `--force` | reconfigure |

Idempotent. **Never re-initialises an existing repository and never overwrites an
existing key file** — that would orphan every snapshot ever taken. Refuses to
finish until the recovery card is acknowledged.

### `discover [--write] [--json]`

Filesystems and whether `/var/lib/docker` is separate; snapshot capability and
free space; compose projects and the host paths they need; database containers
and the applicable dump command; **images with no registry digest**.

`--write` emits proposed `conf.d` files as `*.proposed` — it never overwrites
live configuration.

### `doctor [--fix] [--json]`

~30 checks. `--fix` performs only safe, reversible repairs: create missing
directories, correct modes, `daemon-reload`, re-link `current`.

Exit 0 on pass or warnings, 4 on any failure.

---

## Backup

### `backup [JOB...] [--all]`

| Flag | |
|---|---|
| `--all` | every enabled job, sequentially |
| `--tag TAG` | extra tag for this run |
| `--skip-hooks` | |
| `--force-unlock` | clear a stale restic lock owned by this host first |

Returns the **worst** per-job code. See [exit codes](exit-codes.md).

### `schedule enable|disable|list|sync`

`sync` reconciles units with `conf.d` and **removes orphaned timers** for jobs
whose config file was deleted — otherwise a deleted job keeps firing.

### `status [--json]`

The operator dashboard, and what monitoring scrapes. Freshness is measured from
the last **success**, not the last attempt: a job failing every hour has a very
recent last run and no backup at all.

### `logs [JOB] [-f] [--lines N] [--json]`

`--json` reads `events.jsonl`.

---

## Restore

### `restore <sub>`

```
restore file    --path PATH   [selector] [--to DIR | --in-place]
restore dir     --path PATH   [selector] [--to DIR | --in-place]
restore volume  --name NAME   [selector] [--swap]
restore project --name NAME   [selector] [--config-only|--recreate]
restore db      --db SPEC     [selector] [--into container|scratch|-]
restore system  --profile safe|staged|full
restore preview <any of the above>
restore commit   --token ID
restore rollback --token ID
```

**Selector** — how a point in time is chosen:

| Flag | |
|---|---|
| `--run ID` | a complete run — **the correct selector** |
| `--at TIME` | newest complete run at or before an RFC3339 time |
| `--snapshot ID` | one specific snapshot (surgical) |

Restoring by "latest" per snapshot pairs a database dump from one day with volume
contents from another.

**Safety:** the default target is a staging directory. `--in-place` stages first
and swaps by rename, keeping the previous content as `.bgbk-old-<token>` for
seven days. Paths on the NEVER list (`/boot`, `/etc/fstab`, `/etc/netplan`,
`/etc/machine-id`, the account databases) are refused without `--force-unsafe`.

`restore preview` exits 2 when the selection touches a NEVER path.

### `dump <snapshot> <path> [--to FILE]`

Streams one file out. This is how a database dump is retrieved:

```bash
bg-backup dump latest /db/postgres/pg/app.dump | pg_restore -d app
```

---

## Inspect

| Command | |
|---|---|
| `snapshots [--job] [--tag] [--last N] [--all-hosts]` | |
| `runs list\|show\|diff` | complete runs, not raw snapshots |
| `ls <snap> [path]` | browse without restoring |
| `find <pattern>` | which snapshot still has this file |
| `diff <a> <b>` | why did the backup grow |
| `mount <dir>` | read-only FUSE mount; needs `fuse3` |
| `stats [--mode raw-data\|restore-size]` | |

---

## Maintain

### `check [--read-data] [--read-data-subset PCT]`

`--read-data` downloads the **entire** repository — hours and real egress cost on
a large repo. The default subset rotates through 30 slots with a persisted
bitmap, so a missed day is caught up rather than skipped forever, and the whole
repository is byte-verified within the window.

Failures always alert, regardless of `BGB_MONITOR_ON`.

### `verify [--job] [--sample N] [--full] [--no-databases]`

Restores a canary and sampled real files and hashes them; loads each database
dump into a throwaway container with **no network egress** built from the exact
recorded image, and compares object and row counts against the counts captured at
dump time. Monthly it also tests the **oldest retained** snapshot — the one you
depend on in a ransomware scenario and the one nobody ever tests.

Records the "last proven restore" date shown by `status`.

### `forget [--job] [--apply]`

Dry-run by default. Five safety rails, see [configuration](configuration.md#safety-rails).
Exit 9 means a rail refused — read the message rather than forcing.

### `prune [--max-unused PCT] [--dry-run]`

Refuses unless `BGB_REPO_ROLE=primary`.

### `copy [--job]`

Primary → secondary. The secondary must have been created with
`--copy-chunker-params`.

### `unlock [--remove-all]`

Shows who holds the lock before removing it.

---

## Configuration and keys

| Command | |
|---|---|
| `config show [--job] [--resolved] [--reveal] [--json]` | `--reveal` requires a terminal — it refuses to print secrets into a pipe |
| `config validate [--strict]` | |
| `config edit [--job]` | validates before installing |
| `config export --out FILE` | the recovery bundle |
| `config import --in FILE [--force]` | |
| `secrets show [--reveal]` | |
| `secrets rotate-repo-password` | adds, **verifies**, then removes |
| `secrets add-recovery-key` | |
| `secrets print-recovery-card [--out FILE]` | |

---

## Disaster recovery

| Command | |
|---|---|
| `dr bootstrap [--bundle F\|--bundle-url U] [--repo U --password-file F]` | credentials, then `/etc/bg-backup` from the config snapshot |
| `dr plan [--run ID] [--out FILE]` | **read-only** reconciliation report |
| `dr run --phase system\|docker\|databases\|all` | one phase at a time, confirmed |
| `dr verify` | post-recovery health check |
| `dr bare-metal --target DIR` | refuses outside a rescue system |

See the [runbook](runbooks/disaster-recovery.md).

---

## Tool

| Command | |
|---|---|
| `self-update [--check] [--version V] [--rollback] [--restic-only]` | |
| `uninstall [--purge]` | never touches the remote repository |
| `version [--json]` | |
| `completion bash` | |
