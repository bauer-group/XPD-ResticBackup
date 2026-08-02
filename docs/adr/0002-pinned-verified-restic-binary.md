# ADR-0002: Ship a pinned, signature-verified restic binary

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

restic versions in the Ubuntu archives across the three target releases:

| Release | restic |
|---|---|
| 22.04 jammy | 0.12.1 |
| 24.04 noble | 0.16.4 |
| 26.04 resolute | 0.18.1 |
| upstream | 0.19.1 |

0.12.1 has neither repository-format-v2 compression nor `--stdin-from-command`.
0.16.4 lacks the distinct exit codes 10, 11 and 12.

Both are load-bearing here. `--stdin-from-command` is what makes a failed
database dump fail the backup instead of storing a truncated file as healthy, and
the distinct exit codes are what makes an alert triageable rather than a generic
"exit 1".

## Decision

Install the upstream binary at a pinned version, verified before use.

Verification requires a **`VALIDSIG` for the pinned fingerprint**
(`CF8F18F2844575973F79D4E191A6868BD3F7A907`) read from `gpg --status-fd` — not
merely that gpg exited 0. Checking the exit code alone would accept a signature
from any key that happened to be in the keyring; checking only that the pinned key
is present would not tie it to this signature at all.

The release key is vendored in the repository, reviewed once by a human, so
verification never depends on a reachable keyserver.

Without a usable signature, fall back to the digest list vendored in the release —
never to an unsigned `SHA256SUMS` fetched over the same channel as the binary,
since whoever could swap one could swap both.

## Consequences

**Positive**

- identical behaviour on all three Ubuntu releases
- the feature floor is a stated, testable property (`BGB_RESTIC_MIN_VERSION`)
- verification is stronger than any existing precedent in the organisation, which
  had none

**Accepted trade-off**

- security updates become our responsibility rather than the distribution's.
  Mitigated by a scheduled workflow that opens a version-bump PR when restic
  publishes a release.
- the pin must be bumped deliberately. For a fleet that is a feature: no host
  takes a new backup engine unattended.

## Alternatives considered

**The distribution package.** Free security updates, but 22.04 cannot express the
central design rule at all, so the product could not behave the same everywhere.

**`restic self-update`.** Uses the same GPG signature and is well built, but each
host would drift independently — the opposite of what a fleet needs. It remains
available as `bg-backup self-update --restic-only` for emergencies, with a warning
that the host now diverges.

## Revisit when

The oldest supported Ubuntu ships restic ≥ 0.17 — currently that means once 22.04
leaves scope. Even then the pin is probably worth keeping for fleet uniformity.
