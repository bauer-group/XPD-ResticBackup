# ADR-0001: A bash CLI with systemd timers, not resticprofile

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

The existing manual setup used resticprofile: systemd scheduling, one
consolidated YAML, healthchecks.io pings. It works, and the temptation was to
build on it.

The requirements, however, are: consistent backups of Docker hosts with
databases, restorable onto a freshly installed system; safe restore of everything
or of individual parts; and recovery of the tool's own configuration and keys
after a total loss.

## Decision

Build a bash CLI (`bg-backup`) that calls restic directly and generates systemd
timers itself. Do not build on resticprofile.

Implementation language is Bash 5 + jq. Python was rejected on packaging —
22.04's 3.10 has no `tomllib`, PyYAML is not installed by default, and 26.04 is
PEP-668 externally-managed. Go was rejected on distribution: `curl … | bash` from
the repository is a requirement, and a Go binary means the repository alone is
not runnable.

## Consequences

**Positive**

- one configuration layer instead of two
- one fewer unpinned third-party binary on every host
- full control over the restore and disaster-recovery experience, which is where
  most of the actual work is
- the source can be read and hand-executed on a rescue system — the tool's most
  important execution context

**Accepted trade-off**

- scheduling, locking, retention and hooks are written here rather than
  inherited: roughly 200 lines that would otherwise have been free
- bash demands discipline. Mitigated by shellcheck at warning level in CI, a bats
  suite, a three-distribution matrix, and the rule that restic and docker JSON is
  parsed only with jq, never a regex.

## Alternatives considered

**Build on resticprofile.** It solves scheduling, config consolidation and
monitoring — and none of the four requirements above. Its configuration file also
holds the repository passphrase in plaintext, which is how the credentials in this
project's drafts became a problem in the first place. Two configuration layers
and a second binary, for no coverage of the work that actually needed doing.

**Hybrid: generate a resticprofile configuration from ours.** Maximum
flexibility, double the testing and maintenance surface.

## Revisit when

resticprofile grows database-aware consistency and a restore orchestration story
— or when this bash codebase exceeds roughly 8000 lines, at which point Go with a
release pipeline becomes the cheaper option and the disaster-recovery story can
be covered by shipping a static binary alongside the recovery bundle.
