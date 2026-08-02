# ADR-0010: One repository per host, inside a shared bucket

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

The existing MinIO deployment has one bucket, `backup-server`, with a path per
server. The question is whether to keep that, give each host its own bucket, or
share a single repository across hosts.

## Decision

Keep the shared bucket, one **restic repository per host** under a prefix equal to
the host's FQDN.

```
s3://backup-server/
├── host-a.example.com/     ← a complete, independent repository
├── host-b.example.com/
└── host-c.example.com/
```

Revisit above roughly 20 hosts.

## Consequences

**Positive**

- blast radius is one prefix: a compromised host holds a credential scoped to its
  own repository and cannot reach another's snapshots
- each repository has its own keys, so a key rotation is per host
- matches the existing deployment, so no migration

**Accepted trade-off, and it is a real one**

**No deduplication across hosts.** For a fleet of near-identical Ubuntu servers
that is meaningful storage — the base system is stored once per host. It is
recovered on the pull-side copy repository, where a *shared* repository is safe
precisely because no production host holds its credentials.

**One bucket means the IAM policy is load-bearing.** A credential that is not
prefix-scoped can reach every host's repository, and that is exactly what happened
with the credential leak that prompted this project. The onboarding runbook makes
the scoped policy a checklist item, not an afterthought.

## The control this decision demands

Because several repositories share a bucket, `forget` must be scoped or it becomes
a cross-host deletion:

```
--host <fqdn> --tag job=<name> --group-by host,tags
```

Without `--host`, one server's retention deletes another server's snapshots —
quietly, with exit 0. This is the single most likely catastrophic bug in a tool of
this shape, so the scoping is not configurable and a unit test asserts it is
present in every built `forget` argv.

`bg-backup doctor` additionally **fails** when the repository prefix does not end
with this host's FQDN, which is how a copied-and-pasted configuration is caught
before it does damage.

`prune` is restricted to `BGB_REPO_ROLE=primary` so two hosts cannot rewrite pack
files concurrently.

## Alternatives considered

**One bucket per host.** Cleaner IAM and lifecycle boundaries, considerably more
administrative overhead, and a change to existing infrastructure for a property
the prefix-scoped policy already provides.

**One shared repository for all hosts.** Excellent deduplication and the reason it
is tempting. Rejected: every host would hold a credential to a repository
containing every other host's data, and one host's `forget` misconfiguration could
delete the fleet's history.

## Revisit when

The host count passes roughly 20 — at which point per-host buckets become worth
the administrative cost — or when storage growth from lost cross-host
deduplication becomes material and the pull-side copy repository is not yet
absorbing it.
