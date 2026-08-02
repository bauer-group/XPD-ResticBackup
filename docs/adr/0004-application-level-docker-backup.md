# ADR-0004: Application-level Docker backup, not /var/lib/docker

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

The previous approach backed up `/var/lib/docker` including overlay2, stopping
the Docker daemon first for "consistency".

Two problems, both of which only surface during a restore:

**`systemctl stop docker` is not database consistency.** It SIGKILLs containers
after a timeout, so PostgreSQL and MySQL come back through crash recovery. That
is a backup of a crashed database, not a consistent backup.

**Restoring overlay2 ties the restore to the machine that made it** — the exact
Docker version and storage driver. The stated requirement is "restorable onto a
freshly installed Linux base system", which is precisely what an image-level
backup cannot promise.

## Decision

Back up what a restore actually needs:

- compose files and every resolved `env_file`
- named volume contents and bind-mount sources
- image **digests**, not tags
- network **subnets**
- logical database dumps

A restore is then: install Docker → restore files → `compose pull && up` → load
dumps.

Container filesystems, overlay2 and the image store are not backed up.

## Consequences

**Positive**

- restores work on any host, independent of Docker version and storage driver
- databases are transactionally consistent rather than crash-consistent
- the backup is substantially smaller
- freeze windows shrink from minutes (daemon stop) to seconds (`docker pause` of
  one project)

**Accepted trade-off**

- a restore needs a registry for the images. Mitigated by
  `JOB_DOCKER_EXPORT_IMAGES=missing`, which exports exactly those images that
  have no registry digest, and by `discover` and `doctor` warning about them
  during normal operation rather than during the restore.
- the compose files must exist, so they are backed up explicitly and their
  absence is an error rather than a surprise
- `JOB_DOCKER_INCLUDE_OVERLAY2=1` remains available, documented as several times
  larger and version-bound

Two details that look minor and are not, so they are recorded here: **digests**,
because `compose up` re-resolves `:latest` and would otherwise start a different
version than the data was written by; and **subnets**, because Docker otherwise
assigns new ones from its address pool and every firewall rule referencing the old
subnet silently stops matching.

## Alternatives considered

**Keep the image-level backup.** Requires no compose knowledge, fails the core
requirement, and does not fix database consistency.

**Both in parallel.** Double the storage and runtime for a fallback path that is
itself unreliable on a fresh host.

## Revisit when

Docker gains a supported, version-independent export of full engine state — or a
workload appears whose data genuinely cannot be captured at application level, in
which case that workload gets a filesystem-snapshot job rather than changing the
default.
