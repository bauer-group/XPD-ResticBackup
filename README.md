# bg-backup

[![Release](https://img.shields.io/github/v/release/bauer-group/XPD-ResticBackup?sort=semver)](https://github.com/bauer-group/XPD-ResticBackup/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/bauer-group/XPD-ResticBackup/actions/workflows/ci.yml/badge.svg)](https://github.com/bauer-group/XPD-ResticBackup/actions/workflows/ci.yml)
[![Integration](https://github.com/bauer-group/XPD-ResticBackup/actions/workflows/integration.yml/badge.svg)](https://github.com/bauer-group/XPD-ResticBackup/actions/workflows/integration.yml)
[![Security](https://github.com/bauer-group/XPD-ResticBackup/actions/workflows/security.yml/badge.svg)](https://github.com/bauer-group/XPD-ResticBackup/actions/workflows/security.yml)
[![Ubuntu 22.04 | 24.04 | 26.04](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)](#requirements)

> **BAUER GROUP** — Today, Tomorrow, Together

Backup and disaster recovery for Linux servers, built on [restic](https://restic.net).
Client-side encrypted, deduplicated, and designed around one requirement that
most backup setups quietly fail: **restoring onto a freshly installed machine**.

---

## Why this exists

A backup that has never been restored is a hypothesis. Three things decide
whether yours holds, and this tool is organised around them.

**Consistency.** Stopping the Docker daemon is not database consistency — it
SIGKILLs containers after a timeout, so PostgreSQL and MySQL come back through
crash recovery. bg-backup takes logical dumps inside each container and streams
them through `restic backup --stdin-from-command`, which **aborts the backup if
the dump command fails**. Piping into `--stdin` instead would store the partial
stream as a healthy snapshot and report success.

**Restorability.** Backing up `/var/lib/docker` ties the restore to the exact
Docker version and storage driver that produced it. bg-backup backs up the
things a restore actually needs: compose files, `.env`, named volumes, bind
mounts, image digests, network subnets and database dumps. A restore is then
"install Docker, put the files back, `compose up`, load the dumps" — which works
on any host.

**Recoverability of the backup itself.** The repository passphrase cannot live
only inside the repository it opens. `bg-backup config export` produces an
encrypted recovery bundle plus a one-page printable sheet whose most important
section is *how to recover with no bg-backup at all* — raw restic commands, so
this tool is never a single point of failure for reading its own backups.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
```

Then:

```bash
bg-backup init          # repository, credentials, first job definitions
bg-backup discover      # what this host actually has
bg-backup backup --all  # a first run, by hand
bg-backup restore preview file --path /etc/hostname
bg-backup schedule sync && bg-backup schedule enable
```

**No timer is armed until that last line.** A scheduled backup that fails every
night is worse than no schedule: it produces alert fatigue and false confidence.

The installer downloads a pinned restic binary and verifies it against the
upstream GPG signature, requiring a `VALIDSIG` from the vendored release key —
not merely "gpg exited 0". Distribution packages are not used: Ubuntu 22.04
ships restic 0.12.1, which has neither compression nor `--stdin-from-command`.

<details>
<summary>Pinned version, unattended provisioning, air-gapped, uninstall</summary>

```bash
# Pin a release
curl -fsSL .../install.sh | REF=v1.0.0 bash

# Unattended, with a repository configured in one go
curl -fsSL .../install.sh | \
  INIT_REPO=1 ENABLE_TIMERS=1 \
  BGB_REPOSITORY='s3:https://s3.example.com/backup-server/host.example.com' \
  BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY=... BGB_S3_SECRET_KEY=... bash

# Air-gapped
RESTIC_BINARY=/mnt/usb/restic SOURCE_DIR=/mnt/usb/bg-backup OFFLINE=1 bash install.sh

# Remove the tool (never touches the remote repository)
curl -fsSL .../install.sh | UNINSTALL=1 bash
```
</details>

---

## What gets backed up

| Layer | Contents |
|---|---|
| **system** | the root filesystem minus rebuildable data, plus a machine-readable host manifest: package selections, APT sources and keyrings, enabled units, users/groups/subuid, crontabs, netplan and NIC MAC addresses, firewall rules, disk layout and UUIDs, SSH host key fingerprints |
| **docker** | compose files and every resolved `env_file`, named volumes, bind mounts, image **digests**, network **subnets**, and a manifest of the running state |
| **databases** | logical dumps via `docker exec`, streamed straight into the repository |
| **config** | `/etc/bg-backup` itself — this is what makes bootstrapping from nothing possible |

Databases are detected by image, confirmed by environment or exposed port, and
overridable per container with a label:

```yaml
labels:
  backup.bauer-group.com/engine: postgres
  backup.bauer-group.com/tier: critical
  backup.bauer-group.com/skip: "false"
```

Supported engines: PostgreSQL, MySQL/MariaDB/Percona, MongoDB, Redis, SQLite.
Each reports **degraded** rather than green when a dump succeeded but cannot be
called consistent — MyISAM tables under `--single-transaction`, a standalone
MongoDB without an oplog. A snapshot whose consistency is unknown is exactly the
silent state this tool exists to remove.

---

## Consistency modes

| `JOB_QUIESCE` | Mechanism | Downtime | Consistency |
|---|---|---|---|
| `none` | live copy | none | none guaranteed |
| `dump` | logical dump (automatic for databases) | none | **exact** (transactional) |
| `docker-pause` | pause only the project being read | seconds | crash-consistent |
| `docker-stop` | `compose stop` for that project | minutes | clean |
| `service-stop` | `systemctl stop <units>` | minutes | clean |
| `lvm` / `btrfs` / `zfs` | freeze → block snapshot → thaw → back up the snapshot | **none** | crash-consistent |

Reversal is guaranteed three ways: the exit trap, a state file under `/run`
replayed at the start of the next run, and `ExecStopPost=` in the systemd unit —
which still runs when the process is SIGKILLed and no trap ever fires.

---

## Requirements

- Ubuntu 22.04, 24.04 or 26.04 (Debian 13 works; other distributions are untested)
- root
- an S3-compatible, SFTP, REST or local repository
- `jq` for JSON output, discovery and Docker mode

---

## Commands

| | |
|---|---|
| `init` `discover` `doctor` | set up, inspect, ~30 health checks |
| `backup` `schedule` `status` `logs` | run and observe |
| `restore` `dump` `snapshots` `ls` `find` `diff` `mount` `runs` | get data back |
| `check` `verify` `forget` `prune` `copy` `unlock` `stats` | maintain and prove |
| `config` `secrets` | configuration and keys, including the recovery bundle |
| `dr` | `bootstrap` · `plan` · `run` · `verify` · `bare-metal` |

## Exit codes

| | | | |
|---|---|---|---|
| `0` success | `1` fatal | `2` usage | `3` **partial** — snapshot written, some files unreadable |
| `4` precondition | `5` locked | `6` repository | `7` verify failed |
| `8` hook failed | `9` safety rail refused | `130` interrupted | |

Exit `3` during a live phase is normal (rotating logs, sockets). Exit `3` during
a **quiesced** phase means files were unreadable with services stopped, which is
a real signal — set `JOB_PARTIAL_IS_FAILURE=1` on quiesced jobs.

---

## Safety

`forget` is the only irreversible path, and the repository backend is a bucket
shared across hosts. Five independent rails:

1. every invocation is scoped `--host <fqdn> --tag job=<name> --group-by host,tags` — without `--host`, one server's retention deletes another's snapshots, quietly, with exit 0
2. dry-run first, always; `--apply` is required to delete
3. refuse if fewer than `BGB_FORGET_MIN_SNAPSHOTS` would remain
4. refuse if more than `BGB_FORGET_MAX_DELETE_PERCENT` would go
5. a configuration with no `keep-*` at all is rejected, not read as "keep nothing"

`prune` runs only where `BGB_REPO_ROLE=primary`, so two hosts sharing a bucket
cannot prune concurrently.

Restores stage first and swap by rename, keeping the previous content for seven
days. `/boot`, `/etc/fstab`, `/etc/netplan`, `/etc/machine-id` and the account
databases are **never** written automatically — on new hardware, stale disk
UUIDs and old interface names leave a host unbootable or unreachable.

See [SECURITY.md](SECURITY.md) for the threat model, the S3 policy that allows
`DeleteObject` **only** under `<prefix>/locks/*`, and why S3 Object Lock does not
work with restic.

---

## Monitoring

Uptime Kuma push (the dead-man's switch — it alerts when a push does *not*
arrive), e-mail on failure only, Microsoft Teams, and a Prometheus
node_exporter textfile with `bg_backup_*` metrics. A notifier never changes a
job's exit code: monitoring that can take down the backup it monitors is worse
than none.

## Fleet deployment

An Ansible role lives in [`ansible/roles/restic_backup`](ansible/roles/restic_backup)
and is maintained in `bauer-group/IAC-Ansible`. It pins a release deliberately —
no host takes a new backup tool on a routine `ansible-pull`.

## Development

```bash
make            # self-documenting help
make test       # hermetic: shellcheck + bats units
make integration UBUNTU=22.04|24.04|26.04
make dr-rehearse
```

## Documentation

| | |
|---|---|
| [Quickstart](docs/quickstart.md) · [Installation](docs/installation.md) · [Configuration](docs/configuration.md) | getting running |
| [Docker & databases](docs/docker.md) · [Monitoring](docs/monitoring.md) · [Operations](docs/operations.md) | day to day |
| [Disaster recovery](docs/runbooks/disaster-recovery.md) · [Restore](docs/runbooks/restore.md) · [Recovery sheet](docs/recovery-sheet.md) | when it matters |
| [Security](SECURITY.md) · [Secrets & keys](docs/secrets.md) | credentials |
| [Architecture](docs/architecture.md) · [ADRs](docs/adr/) · [Contributing](CONTRIBUTING.md) | why it is built this way |

---

[MIT](LICENSE) © BAUER GROUP
