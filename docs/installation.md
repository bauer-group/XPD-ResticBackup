# Installation

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
```

Configuration is by **environment variable**, never argv — the script is piped
into bash and has no usable command line.

## What it does, in order

1. root check, `mkdir`-based lock with stale reclaim, `trap cleanup EXIT`
2. OS detection — never hard-fails on an unrecognised Ubuntu release
3. architecture detection
4. dependencies: `ca-certificates curl tar bzip2`, plus `jq`, `gnupg`, `logrotate`
5. **restic download and verification** (below)
6. payload into `/opt/bg-backup/releases/<version>`, `current` symlink flipped atomically
7. directories, configuration seeded (never overwriting), systemd units installed
8. marker file, `doctor`, next steps

**Nothing is enabled.** No repository is created, no timer is armed, no
credential is written unless you passed one.

### restic verification

restic publishes `SHA256SUMS` and `SHA256SUMS.asc`, signed by the release key
`0x91A6868BD3F7A907`. That key is **vendored in this repository** — reviewed once
by a human, fingerprint pinned in `share/restic/restic-release-key.fpr` — so
verification never depends on a reachable keyserver.

The check requires a `VALIDSIG` for the **pinned fingerprint**, not merely that
gpg exited 0. Checking only the exit code would accept a signature from any key
that happened to be in the keyring; checking only that the pinned key is present
would not tie it to this signature at all.

Without a usable signature, the installer falls back to the digest list vendored
in the release — never to an unsigned `SHA256SUMS` fetched over the same channel
as the binary, since whoever could swap one could swap both.

**Distribution packages are not used.** Ubuntu 22.04 ships restic 0.12.1, which
has neither repository-format-v2 compression nor `--stdin-from-command`; 24.04
ships 0.16.4, which lacks the distinct exit codes 10/11/12. A uniform product
across three Ubuntu versions is only possible with the upstream binary.

## Environment variables

### Source

| Variable | Default | |
|---|---|---|
| `REF` | `main` | `main`, `v1.2.3`, or a commit sha |
| `INSTALL_METHOD` | `tarball` | `tarball` \| `git` \| `local` |
| `SOURCE_DIR` | — | local checkout; implies `local` |
| `REPO_SLUG` | `bauer-group/XPD-ResticBackup` | |

### Paths

| Variable | Default |
|---|---|
| `PREFIX` | `/opt/bg-backup` |
| `BINDIR` | `/usr/local/sbin` |
| `CONFDIR` | `/etc/bg-backup` |
| `LOGDIR` | `/var/log/bg-backup` |
| `STATEDIR` | `/var/lib/bg-backup` |

### restic

| Variable | Default | |
|---|---|---|
| `RESTIC_INSTALL` | `1` | `0` = assume it is already on PATH |
| `RESTIC_VERSION` | `0.19.1` | pinned |
| `RESTIC_BINARY` | — | pre-downloaded binary (air-gapped) |
| `RESTIC_VERIFY` | `gpg` | `gpg` \| `sha` \| `none` |
| `ALLOW_UNVERIFIED` | `0` | required for `RESTIC_VERIFY=none` |

### Behaviour

| Variable | Default | |
|---|---|---|
| `PROFILE` | `server` | `minimal` \| `server` \| `docker` — which jobs are seeded |
| `INIT_REPO` | `0` | configure a repository non-interactively |
| `ENABLE_TIMERS` | `0` | only honoured when `INIT_REPO=1` succeeded |
| `RUN_DISCOVER` | `0` | |
| `OFFLINE` | `0` | skip every network operation |
| `FORCE` | `0` | redo everything, including the restic download |
| `KEEP_RELEASES` | `3` | how many releases stay available for rollback |
| `UNINSTALL` / `PURGE` | `0` | |

### Non-interactive repository setup

```bash
curl -fsSL .../install.sh | \
  INIT_REPO=1 ENABLE_TIMERS=1 \
  BGB_REPOSITORY='s3:https://s3.example.com/backup-server/host.example.com' \
  BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY=... BGB_S3_SECRET_KEY=... BGB_S3_REGION=us-east-1 bash
```

`BGB_PASSWORD` reaches `init` through the environment, never as an argument:
`/proc/<pid>/cmdline` is world-readable, `/proc/<pid>/environ` is not.

Timers are enabled **only** if the repository was configured successfully. A
scheduled backup that fails every night produces alert fatigue and false
confidence.

## Air-gapped

```bash
RESTIC_BINARY=/mnt/usb/restic \
SOURCE_DIR=/mnt/usb/XPD-ResticBackup \
OFFLINE=1 INSTALL_JQ=0 \
bash /mnt/usb/XPD-ResticBackup/install.sh
```

## Upgrading

Re-running the one-liner is the upgrade. It detects the marker file, installs the
new payload beside the old one, flips `current`, reconciles the timers and runs
`doctor`. **Configuration is never modified** — a changed default lands as
`<file>.new` with a hint to diff it.

```bash
bg-backup self-update --check
bg-backup self-update
bg-backup self-update --rollback     # flips current back, instantly
```

## Uninstalling

```bash
curl -fsSL .../install.sh | UNINSTALL=1 bash          # keeps config, state, logs
curl -fsSL .../install.sh | UNINSTALL=1 PURGE=1 bash  # removes them too
```

> `PURGE=1` deletes `/etc/bg-backup`, **including the repository passphrase**. If
> it exists nowhere else, every backup becomes permanently unreadable. Export the
> recovery bundle first.

Neither form touches the remote repository. Your backups still exist, are still
readable with a plain restic binary, and still cost money.

## Layout on the host

```
/opt/bg-backup/releases/<version>/   immutable payload
/opt/bg-backup/current -> releases/<version>
/usr/local/sbin/bg-backup -> current/bin/bg-backup.sh
/usr/local/bin/restic                pinned, verified
/etc/bg-backup/                      configuration + credentials
/var/lib/bg-backup/                  cache, state, facts, restore staging
/var/log/bg-backup/                  bgb.log, events.jsonl, jobs/<job>-<ts>.log
/run/lock/bg-backup/                 locks (tmpfs)
/run/bg-backup/                      quiesce state
```

Releases are side by side and `current` is a symlink, which makes both the
upgrade and the rollback atomic — relevant because the thing being upgraded is
the thing that runs unattended at 03:00.

## Verifying an installation

```bash
bg-backup doctor
```

~30 checks. Fails (rather than warns) on: restic too old, configuration
world-readable, repository unreachable, **repository prefix not matching this
host's FQDN**, `/var/lib/docker` on its own mount while `--one-file-system` would
skip it, two jobs quiescing Docker at the same time, no working notification
channel, and a failing redaction self-test.
