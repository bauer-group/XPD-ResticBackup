# ADR-0003: systemd LoadCredential=, not EnvironmentFile=

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

The units need three secrets: the repository passphrase, the S3 credentials, and
the notifier tokens. `EnvironmentFile=` is the obvious mechanism and is what most
examples use.

It is also wrong here. `EnvironmentFile=` merges the values into the unit's
environment, and systemd exposes that to **any unprivileged local user**:

```bash
systemctl show -p Environment bg-backup@docker.service
```

The mode on the file is irrelevant — systemd has already read it.

## Decision

Use `LoadCredential=`. It materialises the files under `$CREDENTIALS_DIRECTORY`
in a per-invocation `ramfs` mount that is `0400`, root-only, never swapped, and
torn down when the unit exits.

Available since systemd 247, so present on 22.04 (249), 24.04 (255) and 26.04.

Separately, and for the same class of reason: the repository passphrase reaches
restic through `RESTIC_PASSWORD_FILE`, never as an environment value.
`--stdin-from-command` and every hook spawn child processes that inherit the
environment, so an inline `RESTIC_PASSWORD` would be readable by every database
dump command the tool runs.

And no secret is ever passed in argv: `/proc/<pid>/cmdline` is world-readable
while `/proc/<pid>/environ` is not.

## Consequences

**Positive**

- no secret is readable by a local unprivileged user
- credentials are not written to a swappable location
- the passphrase is not inherited by dump commands or hooks
- a unit test can assert that no built restic argv contains a registered secret

**Accepted trade-off**

- the unit files are slightly more complex
- a manual run outside systemd takes a different code path, reading the files
  directly. Both paths are exercised: the integration suite runs manually, the DR
  rehearsal runs under systemd.

## Alternatives considered

**`EnvironmentFile=` with mode 0400.** Does not help — see above.

**A secrets agent (Vault agent, systemd-creds with a TPM).** Correct at a larger
scale, an unjustifiable dependency for a tool that must work on a rescue system
with nothing installed.

## Revisit when

A fleet-wide secrets manager is introduced, at which point the credential files
on the host become a cache rather than the source of truth.
