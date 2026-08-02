# ADR-0007: The Ansible role lives in IAC-Ansible, not in this repository

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure
**Mirrored as:** IAC-Ansible ADR-0002

## Context

This repository is the product. `bauer-group/IAC-Ansible` is the configuration
management repository. The role has to live in one of them.

## Decision

The role lives in `IAC-Ansible` under `roles/restic_backup/`. This repository
holds the authoritative **source** of the role under `ansible/roles/restic_backup/`
and it is PR'd across; the product and the role version independently.

Two facts from IAC-Ansible decide it, and neither is stylistic:

**ADR-0001 there** establishes that managed hosts have zero Galaxy network
dependency at runtime — they are self-contained on the distribution `ansible`
package. A role hosted in this repository would have to reach the host somehow
(`ansible-galaxy install -r requirements.yml` at pull time, or a second clone in
the `ansible-pull` unit), and every mechanism reintroduces exactly the runtime
dependency that ADR refuses.

**The `ansible-pull` model** means each host clones one repository and runs
`site.yml` against itself. Anything not in that clone does not exist at converge
time.

## Consequences

**Positive**

- no runtime network dependency is added to managed hosts
- the role is tested by the existing molecule matrix
- `ansible-pull` keeps working unchanged

**Accepted trade-off**

- a product release and a role bump are two PRs in two repositories. Mitigated by
  a single variable, `restic_backup_version`, so the bump is a one-line change.
- the role source exists in two places and can drift. Mitigated by treating this
  repository as authoritative and the IAC-Ansible copy as vendored.

## Design points that follow from this

The role is a **driver**, not a reimplementation: it fetches a pinned release
tarball with `get_url` and a `checksum:`, then runs `install.sh --offline`. Not
`curl | bash` — that is right for a human bootstrapping one server, but an
unattended converge wants a checksum assertion and a `changed_when` it can reason
about.

`restic_backup_version` is pinned deliberately. No host takes a new backup tool
version on a routine `ansible-pull`; bumping it is a reviewed change.

`restic_backup_prune_local` defaults to `false`. That is the ransomware control
from [ADR-0005](0005-append-only-and-separate-prune-identity.md), not a
preference, and the prune credential is deliberately absent from the secrets
table so no managed host can resolve it.

## Alternatives considered

**Role in this repository, vendored into IAC-Ansible by CI.** Single source of
truth and automated sync, but it adds a cross-repository automation that has to be
maintained and that fails silently when it breaks.

**Role in this repository, installed via `requirements.yml`.** Directly
contradicts IAC-Ansible ADR-0001.

## Revisit when

IAC-Ansible revisits ADR-0001 — for example if a supply-chain requirement makes
pinned Galaxy collections mandatory, at which case a properly published collection
becomes the better answer for both.
