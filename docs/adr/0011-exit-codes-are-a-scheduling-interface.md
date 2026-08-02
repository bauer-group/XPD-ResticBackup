# ADR-0011: Exit codes are an interface, and exit 3 stays separate

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

restic distinguishes exit 0 (success), 1 (fatal, no snapshot) and 3 (a snapshot
was created but some source files could not be read). Most wrapper scripts
collapse 3 into either success or failure, because "partial" is awkward to handle.

The drafts' wrapper did the same: it treated only exit 1 as a failure and let 3
pass as success.

## Decision

Exit codes are a documented **interface** with a stable numbering. Adding a code
is allowed; renumbering one is a breaking change.

Exit 3 is preserved and given a meaning that depends on the job:

| Context | Meaning | Default |
|---|---|---|
| live run | rotating logs, sockets, files deleted mid-run | normal, `JOB_PARTIAL_IS_FAILURE=0` |
| quiesced run | files were unreadable **with services stopped** | a real signal, `JOB_PARTIAL_IS_FAILURE=1` |

Severity ordering for `backup --all` is not numeric — 3 is less severe than 1:

```
0 < 3 < 8 < 7 = 9 < 5 < 6 < 4 = 2 < 1 < 130
```

A run that produced a degraded snapshot never reports worse than one that produced
none at all.

`SuccessExitStatus=3` is deliberately **not** set on the systemd unit: exit 3
marks the unit failed, which fires the alert handler, which reports it as a
warning rather than a page. The distinction stays visible in `systemctl` instead
of being hidden behind a success.

## Consequences

**Positive**

- "some files were unreadable" and "no backup exists" are different states, and
  the alerting can treat them differently
- the same exit code can be normal on one job and actionable on another, which
  matches reality
- automation has a stable contract; `bg_backup_run_exit_code` is exported as a
  metric

**Accepted trade-off**

- consumers must handle three success-ish outcomes rather than two. Documented in
  `docs/exit-codes.md` with a worked shell example.
- the `JOB_PARTIAL_IS_FAILURE` flag is one more thing to configure. It is set
  correctly in the shipped job templates, so the default is right.

## Related

This is why `BGB_RESTIC_MIN_VERSION` is 0.17.0
([ADR-0002](0002-pinned-verified-restic-binary.md)): below that restic collapses
10 (no repository), 11 (locked) and 12 (wrong password) into a generic 1, and an
alert saying "exit 1" is untriageable.

The additional codes 4 (precondition), 5 (locked), 7 (verify failed), 8 (hook
failed) and 9 (safety rail) exist for the same reason: each one tells the operator
what to do next without reading the log.

Code 9 in particular is not an error — it is the tool refusing to destroy data,
and the message says which rail fired and why.

## Alternatives considered

**Collapse 3 into 0.** Simplest, and it means a job that cannot read half the
filesystem reports success. This is what the previous wrapper did.

**Collapse 3 into 1.** Every full-filesystem backup fails every night, the alert
becomes noise, and within a month nobody looks at it.

## Revisit when

restic changes its exit-code semantics — the mapping table in `lib/restic.sh` and
`docs/exit-codes.md` would both need updating, and the version floor with them.
