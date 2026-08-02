# bg-backup documentation

Backup and disaster recovery for Ubuntu servers, built on restic.

## Start here

| | |
|---|---|
| [Quickstart](quickstart.md) | one host, from nothing to a verified first snapshot |
| [Installation](installation.md) | every installer option, upgrades, air-gapped, uninstall |
| [Configuration](configuration.md) | every setting, with what it costs to get wrong |

## Reference

| | |
|---|---|
| [CLI](cli.md) | every command and flag |
| [Exit codes](exit-codes.md) | the scheduling interface |
| [Architecture](architecture.md) | how the pieces fit, and why |
| [Repository layout](repository-layout.md) | what is stored, under which tags |
| [Docker & databases](docker.md) | consistency modes, engines, what each cannot guarantee |
| [Secrets & keys](secrets.md) | the recovery bundle, key rotation, the three-key model |
| [Monitoring](monitoring.md) | notifiers, metrics, alert rules |
| [Ansible](ansible.md) | fleet deployment |
| [Operations](operations.md) | daily, weekly, monthly, quarterly |
| [Troubleshooting](troubleshooting.md) | symptom → cause → fix |
| [Development](development.md) | tests, adding an engine, adding a notifier |

## Runbooks

Executed under pressure, therefore German and step-by-step.

| | |
|---|---|
| [Disaster Recovery](runbooks/disaster-recovery.md) | Host verloren |
| [Restore](runbooks/restore.md) | Einzelne Daten zurückholen |
| [Backup: Docker-Host](runbooks/backup-docker.md) | Täglicher Betrieb |
| [Backup: Vollserver](runbooks/backup-full-server.md) | Wöchentlicher Betrieb |
| [DR-Übung](runbooks/dr-rehearsal.md) | Quartalsweise |
| [Schlüsselrotation](runbooks/key-rotation.md) | Passphrase und S3-Keys |
| [Vorfall: Ransomware](runbooks/incident-ransomware.md) | Host kompromittiert |
| [Vorfall: Credential-Leak](runbooks/incident-credential-leak.md) | Zugangsdaten öffentlich |
| [Migration von resticprofile](runbooks/migration-from-resticprofile.md) | Umstellung |
| [Host aufnehmen](runbooks/onboarding-a-host.md) | Neuer Server |
| [Recovery Sheet](recovery-sheet.md) | Die eine gedruckte Seite |

## Decisions

[ADRs](adr/) record why things are the way they are, and — in the "Revisit when"
section — what would change the answer.

## The three ideas

If you read nothing else:

**A failed dump must fail the backup.** Every database dump streams through
`restic backup --stdin-from-command`, which aborts when the dump command exits
non-zero. Piping into `--stdin` stores the truncated stream as a healthy
snapshot and reports success.

**A restore must not need the machine that made it.** Docker backups are
application-level — compose files, volumes, image digests, network subnets,
database dumps — so a restore works on any freshly installed host. Restoring
`/var/lib/docker` would tie it to one Docker version and storage driver.

**The tool must not be required to read its own backups.** The recovery sheet's
most important section is the raw restic commands. Everything bg-backup stores
is retrievable with a plain restic binary and the passphrase.
