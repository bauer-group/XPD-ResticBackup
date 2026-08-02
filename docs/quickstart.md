# Quickstart

One host, from nothing to a snapshot you have proven restores. About 15 minutes,
most of it waiting for the first backup.

## Before you start

You need a repository to write to. Any of these work:

| Backend | URL form |
|---|---|
| S3 / MinIO | `s3:https://<endpoint>/<bucket>/<this-host-fqdn>` |
| SFTP | `sftp:user@host:/path/<this-host-fqdn>` |
| REST server | `rest:https://backup.example.com/<this-host-fqdn>` |
| Local directory | `/var/backups/restic/<this-host-fqdn>` — fine for a first test, **not a backup on its own** |

> **The path must end with this host's FQDN.** The bucket is shared across
> servers, and one repository per host is what keeps `forget --host` from
> deleting another server's snapshots. `bg-backup doctor` fails if the prefix
> does not match.

For S3, scope the credential to that prefix: `GetObject`, `PutObject` and
multipart on `<prefix>/*`, `ListBucket` limited to the prefix, and `DeleteObject`
**only** under `<prefix>/locks/*`. Do not deny deletes outright — restic writes a
lock object on every run and removes it on exit, so a blanket deny leaves a stale
lock behind and by the third run the repository needs an `unlock` that also
cannot succeed. Full policy in [Security](../SECURITY.md).

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
```

The installer fetches a pinned restic binary and verifies it against the upstream
GPG signature, requiring a `VALIDSIG` from the vendored release key. It installs
no timers and configures no repository.

```bash
bg-backup version
```

## 2. Configure the repository

```bash
bg-backup init
```

The wizard asks for the backend, tests reachability, generates a 32-character
passphrase if you do not supply one, seeds job definitions, and offers to create
an independent recovery key.

It ends by printing the **recovery card** and asking you to confirm you have
stored it. Do that properly:

> If the passphrase is lost and exists nowhere else, every backup in the
> repository is permanently unreadable. There is no recovery path.

`bg-backup doctor` keeps warning until you confirm.

## 3. Look at what this host actually has

```bash
bg-backup discover
```

This is worth reading rather than skipping. It reports:

- whether `/var/lib/docker` is on its own filesystem — if it is, `--one-file-system`
  would **silently skip it**
- whether an LVM/btrfs/ZFS snapshot is possible, and whether there is room
- every compose project and which host paths it needs
- which containers are databases and which dump command applies
- **images that exist only on this host** and can therefore not be pulled during
  a restore

Act on the last two before continuing.

## 4. First backup, by hand

```bash
bg-backup backup --all
```

The first run is the slow one — everything is new. Later runs transfer only
changed blocks.

```bash
bg-backup snapshots
bg-backup status
```

## 5. Prove you can get it back

This is the step that turns a hypothesis into a backup.

```bash
bg-backup restore preview file --path /etc/hostname
bg-backup restore file --path /etc/hostname --to /tmp/check
cat /tmp/check/etc/hostname
```

Then the real one:

```bash
bg-backup verify
```

`verify` restores a canary and a sample of real files, hashes them, and loads
each database dump into a throwaway container with no network egress, comparing
row counts against the counts captured at dump time.

## 6. Export the recovery bundle

```bash
bg-backup config export --out /root/bg-backup-recovery.age
```

Produces the bundle three times — age, gpg and openssl — because a rescue system
may only have one of them, and each ciphertext is decrypted again and
byte-compared before it is accepted.

**Copy it off this host now.** A bundle that only exists on the machine it
protects protects nothing.

```bash
bg-backup secrets print-recovery-card --out /root/recovery-sheet.txt
```

Print it. Sign it. Put it where the fire procedure lives.

## 7. Only now, arm the schedule

```bash
bg-backup schedule sync
bg-backup schedule enable
systemctl list-timers 'bg-backup*'
```

> A scheduled backup that fails every night is worse than no schedule: it
> produces alert fatigue and false confidence. That is why nothing is armed until
> you have seen a restore work.

## 8. Make sure a failure reaches a human

Configure at least one notifier in `/etc/bg-backup/bg-backup.conf`
(see [Monitoring](monitoring.md)), then prove it:

```bash
bg-backup notify-test          # or break something on purpose
```

The Uptime Kuma push monitor is the dead-man's switch — it alerts when a push
does **not** arrive, which is the failure a "send mail on error" script can never
detect, because a job that never runs sends nothing.

## Where to go next

- [Configuration](configuration.md) — tune retention, excludes, consistency modes
- [Docker & databases](docker.md) — what each engine can and cannot guarantee
- [Operations](operations.md) — what to do daily, weekly, monthly, quarterly
- [Disaster Recovery](runbooks/disaster-recovery.md) — read it **before** you need it
