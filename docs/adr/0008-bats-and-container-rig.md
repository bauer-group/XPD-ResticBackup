# ADR-0008: bats-core for units, a container rig for everything else

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

There was no shell testing anywhere in the organisation — no bats, no shellspec,
no shunit2, no `.shellcheckrc`. Shell quality was ShellCheck in CI and, in one
repository, a container smoke harness.

A backup tool needs more than that, because its failure mode is silence.

## Decision

Two layers, and deliberately no more.

**bats-core** for units, with `bats-support` / `bats-assert` / `bats-file` as git
submodules under `tests/helper/`, so CI needs no package installs. Chosen over
shellspec because the team has zero shell-testing history and bats has the lowest
onboarding cost; shellspec's stronger mocking mostly buys the ability to unit-test
things this design deliberately integration-tests instead.

**A container rig** for everything that needs a real restic, modelled on the
existing `Cloud/workloads/proxies/azure/test/` pattern: MinIO with a one-shot
init container, plus `victim` and `phoenix` Ubuntu containers built with a
`UBUNTU_TAG` build arg.

## What is tested where

| Layer | Runs | Proves |
|---|---|---|
| shellcheck + shfmt | every save | syntax and style |
| bats units | every save | pure functions: redaction, config precedence, retention argv, exit-code mapping |
| installer e2e | CI, 3 Ubuntu versions | the installer actually installs |
| DR rehearsal | CI + quarterly on a VM | a backup actually restores |

## The rules that make this worth having

**The unit suite is deliberately not comprehensive.** A test asserting a function
returns what it obviously returns costs maintenance and buys nothing. A test that
pins down a mistake somebody already made buys the rest of the project — hence
`tests/unit/regressions.bats`, one test per bug that shipped.

**The rig mints a least-privilege, prefix-scoped MinIO user using the production
policy.** An over-broad test policy would hide a real permission bug, which is
exactly the class of bug that only appears in production.

**The e2e suite asserts hard things**, because a vacuous pass is the real failure
mode: restic reports the pinned version and matching sha256; a second `init` is
refused; a deliberately unreadable file yields exit 3 and not 1; `forget` with an
everything-deleting policy is refused; a restore reproduces the tree **and its
metadata** — mode, owner, symlink, hardlink; `doctor` output contains no test
secret; `uninstall` does not touch the repository.

**The DR rehearsal seeds databases natively, not via docker-in-docker.** It proves
the same property without a privileged DinD that will be flaky in CI. It includes
the negative assertion — a file created *after* the snapshot must be absent from
the restore — without which a test that accidentally restores from a live mount
still passes.

**22.04 runs first in the matrix.** It has the oldest bash (5.1) and systemd
(249). A pass on 26.04 with a failure on 22.04 means somebody used newer syntax.

## Consequences

**Positive**

- shell code gains real regression protection
- the tests that exist all justify their maintenance cost
- CI is hermetic and fast; everything needing Docker is opt-in

**Accepted trade-off**

- git submodules are an onboarding wrinkle. `make test` initialises them.
- the container harness cannot start systemd, so the units are validated with
  `systemd-analyze verify` rather than started. That is what the harness can
  honestly prove; the quarterly VM rehearsal covers the rest.

## Alternatives considered

**shellspec.** Technically stronger, invents a DSL nobody here has seen. Revisit
if `lib/restic.sh` grows enough branching to need real mocking.

**ShellCheck only.** What the organisation had. It cannot catch a wrong `forget`
scope or a redaction gap.

## Revisit when

The bats suite exceeds roughly 2000 lines, or mocking pressure appears — both
would make shellspec worth reconsidering.
