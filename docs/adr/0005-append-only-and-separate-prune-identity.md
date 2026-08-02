# ADR-0005: Append-only storage and a separate prune identity

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

The honest baseline: the host holds a credential that can write to the
repository. An attacker with root on that host has that credential. Client-side
encryption protects confidentiality against the storage operator; it does nothing
against an attacker on the source.

So the design question is narrower and answerable: **what can that credential
destroy?**

## Decision

Three controls, in decreasing order of strength.

**1. A pull-side copy repository (target state).** A hardened host copies primary
→ secondary. No production host holds a credential for the secondary, so nothing
that compromises a production host can reach it.

```bash
restic init --from-repo <primary> --copy-chunker-params -r <secondary>
```

`--copy-chunker-params` is mandatory: without matching chunker parameters restic
re-chunks every blob, deduplication against the primary is lost, and the copy can
end up several times larger.

**2. A prefix-scoped S3 policy (interim, works with the existing MinIO).**
`ListBucket` limited to the prefix, `GetObject`/`PutObject`/multipart on the
prefix, and `DeleteObject` **only** under `<prefix>/locks/*`.

Deletes cannot be denied outright: restic writes a lock object on every run and
removes it on exit. With deletes fully denied, every run leaves a stale lock and
by the third run the repository needs an `unlock` that also cannot succeed.

**3. `prune` never runs on a backed-up host.** `BGB_REPO_ROLE=primary` gates it,
and `restic_backup_prune_local` defaults to `false` in the Ansible role. The prune
identity lives in the ops vault.

## Consequences

**Positive**

- a compromised host cannot delete backup history
- one host cannot prune another's snapshots — relevant because the bucket is
  shared
- the blast radius of a leaked host credential is one prefix

**Accepted trade-off, stated rather than papered over**

`PutObject` without delete still permits **overwrite**. An attacker can PUT zeroes
over an existing pack. `restic check --read-data` detects it — pack hashes stop
matching the index — but nothing prevents it. Bucket versioning closes the gap, at
the cost that `prune` no longer reclaims space until noncurrent versions expire.

Control 3 is worth nothing on its own: if the prune credential ends up in
`/etc/bg-backup/credentials/` on a backed-up host, the entire scheme is void.
That is why the Ansible documentation explicitly excludes it from the secrets
table.

## Alternatives considered

**S3 Object Lock.** See [ADR-0009](0009-no-s3-object-lock-with-restic.md) — it
does not work with restic.

**rest-server `--append-only`.** The strongest single control and designed for
exactly this: delete and overwrite are refused at the server. Requires standing up
new infrastructure, which is why it is a target state rather than the interim.

## Revisit when

restic becomes lock-free (planned, not before 0.20) — that would make Object Lock
viable and change this analysis materially. Or when the rest-server is deployed.
