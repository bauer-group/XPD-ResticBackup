# Troubleshooting

Start here:

```bash
bg-backup doctor          # most causes are a precondition, not a bug
bg-backup status
bg-backup logs <job>
```

## By exit code

| Code | First move |
|---|---|
| 1 | `bg-backup logs <job>` — there is **no snapshot** from this run |
| 3 | normal on a live job; on a quiesced job, look at which files |
| 4 | `bg-backup doctor` — a precondition is unmet |
| 5 | check for an overlapping schedule; `bg-backup status` shows held locks |
| 6 | credentials, network, or the repository does not exist |
| 7 | **treat as a backup outage** — do not prune |
| 8 | a hook failed; the snapshot may still exist |
| 9 | a safety rail refused. Read the message; forcing is rarely the answer |

## Repository

**`unable to open config file` / exit 6, repository does not exist**

The repository was never initialised, or the URL is wrong. Compare against the
recovery sheet character by character. On a DR host, the prefix must be the
**old** host's FQDN.

**exit 12 / wrong password**

The passphrase does not open this repository. Do not run `init --force`: it will
not overwrite the key file (deliberately), but you are in the wrong place. Check
whether you are pointed at a different host's prefix.

**`restic init` fails with a region error**

MinIO ignores the region but the AWS SDK requires a syntactically valid one. Set
`AWS_DEFAULT_REGION=us-east-1`.

**The repository is locked and stays locked**

```bash
bg-backup unlock
```

It shows who holds the lock first. If it is another host mid-write, removing it
can damage the repository — find out before forcing.

If **every** run leaves a stale lock, the S3 policy is denying `DeleteObject`
outright. restic must be able to delete its own lock objects: allow deletes under
`<prefix>/locks/*`.

**`check` reports errors after a network hiccup**

Run it once more. Some S3-compatible backends produce a false positive after a
retry. A repeated failure is real — and **do not prune**: prune rewrites pack
files and can turn a recoverable inconsistency into an unrecoverable one.

## Backup

**Exit 3 every night on the system job**

Expected. Rotating logs, sockets and files deleted mid-run are unreadable. The
count is in `bg_backup_files_unreadable`; the paths are in the job log.

**Exit 3 on a quiesced job**

Not expected — files were unreadable with services stopped. Look at the paths in
the job log.

**`/var/lib/docker` is missing from the backup**

It is on its own filesystem and `--one-file-system` skipped it. Add it to
`JOB_EXTRA_PATHS`, or use a docker-mode job. `doctor` fails on exactly this.

**The backup grew enormously**

```bash
bg-backup diff <yesterday-snap> <today-snap>
```

Usual causes: a bind mount pulling in a large path (check `discover`), a
pre-compressed dump defeating deduplication (`JOB_DB_DUMP_COMPRESS` must be 0),
or `JOB_DOCKER_EXPORT_IMAGES=all`.

**Snapshot id and counters are empty, but the job says ok**

`jq` is not installed. The data **is** backed up; what is lost is the bookkeeping,
and retention is skipped because the run cannot prove it produced anything.

```bash
apt-get install -y jq
```

**The job never runs**

```bash
systemctl list-timers 'bg-backup*'
bg-backup schedule sync && bg-backup schedule enable
journalctl -u bg-backup@<job>.service -n 50
```

## Quiesce

**Containers are still paused after a failed run**

They should not be — three mechanisms reverse it. If it happened:

```bash
bg-backup internal unquiesce --job <job>
docker ps -a
```

Then find out why the state file survived; that is a bug worth reporting.

**Docker did not come back after `docker-stop`**

```bash
systemctl start docker.socket docker.service
```

The tool reports this at error level and marks the run degraded. Prefer
`docker-pause` or an LVM snapshot: stopping the daemon is a full outage.

**The quiesce window was exceeded**

`JOB_QUIESCE_MAX_SECONDS` aborted the run and restored service. That trade is
deliberate: a missed backup is recoverable tomorrow, an unbounded outage is not.
Either raise the cap or move to a filesystem snapshot.

## Databases

**A dump fails every night**

```bash
bg-backup discover
docker logs <container>
```

Check that the detection is right — a container called `postgres-backup` running
alpine is not a database. Silence it properly rather than ignoring the alert:

```yaml
labels:
  backup.bauer-group.com/skip: "true"
```

**The run is degraded: "MyISAM tables"**

`--single-transaction` is InnoDB-only, so those tables are not in the transaction
and the dump is internally inconsistent for them. Convert them to InnoDB, or
accept it explicitly.

**The run is degraded: "standalone MongoDB"**

`--oplog` needs a replica set. A single-node replica set is enough.

**Elasticsearch fails: "path.repo is not configured"**

A data-directory copy is not a usable backup — Lucene mmaps its segments. The
snapshot API is the only supported mechanism and it needs a compose change plus a
restart. The error prints the exact change. Until then that container has **no
working backup**.

**`verify` says the dump loaded but the counts differ**

Take this seriously. Either the dump is incomplete, or writes happened between
the count capture and the dump. For PostgreSQL the counts are taken inside the
same exported transaction snapshot, so a mismatch there means a real problem.

## Restore

**`restore preview` exits 2**

The selection touches a NEVER path. Restoring `/boot`, `/etc/fstab`,
`/etc/netplan` or `/etc/machine-id` onto different hardware leaves the host
unbootable or unreachable. Restore to a directory and merge deliberately.

**Restored files have the wrong owner**

The source host's UIDs differ from this one's. `dr run --phase system` produces a
remap table and stops rather than running a recursive `chown` — a wrong one is
not reparable.

```bash
bg-backup dr fix-ownership --apply
```

**A restored volume is empty**

It was restored while a container had it mounted. Stop the consumers and restore
again; `restore volume` offers to do that for you.

**Which snapshot do I actually want?**

```bash
bg-backup runs list
```

Restore by **run**, not by "latest" per snapshot — otherwise you pair a database
dump from one day with volume contents from another.

## Disaster recovery

**`dr plan` says REFUSE**

The target OS is older than the source, a different distribution, or a different
architecture. Dumps are forward-compatible only. Fix the target.

**The host boots into an emergency shell**

`/etc/fstab` has UUIDs that do not exist here. Boot the rescue system, compare
`blkid` against fstab. This is why fstab is staged and never written
automatically.

**The host boots but is unreachable**

Interface names changed (`eth0` → `ens3` → `enp0s3`). Console access,
`ip link`, fix netplan. Apply **only** with `netplan try --timeout 120`, which
reverts itself — never `netplan apply` over SSH.

**sshd will not start after a restore**

An old `sshd_config` referencing options the newer OpenSSH rejects (`ssh-rsa` in
`KexAlgorithms`, `UsePrivilegeSeparation`). Always:

```bash
sshd -t -f <staged config>
```

**Containers start but cannot reach each other**

The networks were recreated with different subnets. Recreate them with the values
from `docker-manifest.json`, then `compose up` again.

**An image cannot be pulled**

It was built locally and never pushed, and `JOB_DOCKER_EXPORT_IMAGES` was `none`.
Rebuild it from source. Then set it to `missing` so this cannot recur.

## Secrets and keys

**The passphrase is lost**

If it exists nowhere else, the data is permanently unreadable. There is no
recovery path, no back door, no support case. Escalate immediately — and treat
the recovery-card acknowledgement as mandatory from then on.

**`doctor` says the bundle does not match the deployed configuration**

Someone changed the configuration and did not re-export. The bundle would restore
a configuration that no longer works.

```bash
bg-backup config export
```

**Rotation left a stray key**

The new key failed verification, so the old one was kept on purpose.

```bash
restic key list
restic key remove <id>          # once you understand why it failed
```

## Getting help

Include: `bg-backup version`, the failing command, the exit code, and
`bg-backup doctor` output.

> **Read output before pasting it, even redacted output.** Redaction protects the
> fields the tool knows about; it cannot protect a secret it has never seen.
