# ADR-0009: Do not use S3 Object Lock with restic

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

S3 Object Lock (governance or compliance mode) is the reflexive answer to
ransomware: make objects immutable for a retention period and a compromised host
cannot delete them.

It is a good instinct and it does not fit restic. This ADR exists so the question
is answered once rather than re-asked every time someone reads about Object Lock.

## Decision

Do not enable S3 Object Lock on a repository restic writes to.

## Why it breaks

**restic is not lock-free** (as of 0.18/0.19). It writes a lock object under
`<prefix>/locks/` on every run and removes it on exit. Object Lock retention is
applied per object at PUT time, or by a bucket default. restic sets no retention
headers, so a bucket default applies to **every** object — including the lock
objects.

Lock objects then become undeletable for the retention period. `restic unlock`
cannot clear them. The repository reports a stale lock on every subsequent run and
becomes unusable within days.

**Even excluding locks, `prune` cannot work.** Prune deletes and rewrites pack
files. Under retention it cannot, so the repository grows without bound until the
shortest retention expires — and prune's own repacking then leaves it permanently
larger than the retention policy implies.

**Object Lock requires versioning**, which multiplies prune's already-poor space
behaviour.

## Consequences

**Positive**

- the repository stays usable
- the team does not spend a week discovering the above by experiment

**Accepted trade-off**

Immutability has to come from somewhere else. See
[ADR-0005](0005-append-only-and-separate-prune-identity.md): a pull-side copy
repository whose credentials no production host holds, plus bucket versioning with
a deny on `DeleteObjectVersion`, plus rest-server `--append-only` where the
infrastructure allows it.

Object Lock, if genuinely wanted, belongs on that **second** repository — the one
nothing ever prunes.

## Alternatives considered

**Object Lock with a very short retention.** Reduces but does not remove the lock
problem, and a retention shorter than the backup interval protects nothing.

**Object Lock plus a lifecycle rule excluding `locks/`.** Lifecycle rules cannot
override an Object Lock retention. Some implementations allow a prefix-scoped
bucket default, which would help — but that is provider-specific and would have to
be re-verified on every backend, for a control that still breaks prune.

## Revisit when

restic becomes lock-free — the maintainers have signalled this, not before 0.20.
At that point Object Lock on the primary repository becomes worth re-evaluating,
though the prune interaction would still need solving.
