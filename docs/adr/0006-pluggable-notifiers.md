# ADR-0006: Pluggable notifiers with a single shell entry point

**Status:** Accepted
**Date:** 2026-08-02
**Deciders:** BAUER GROUP Infrastructure

## Context

Notification requirements differ per site and change over time. The organisation
already runs Uptime Kuma, msmtp and Microsoft Teams; the drafts used
healthchecks.io. Hard-coding any one of them would guarantee a fork.

## Decision

One file per provider in `lib/notify/`, one function:

```bash
bgb_notify_<name> <event> <job> <rc> <payload-json> <log-excerpt-file>
```

The dispatcher iterates `BGB_NOTIFIERS`, runs each in a subshell under `timeout`,
and logs a (redacted) failure.

**A notifier returns 0 in practice and never changes the job's exit code.**
Monitoring that can take down the backup it monitors is worse than no monitoring.

Everything a provider sends passes `redact()` first, and file **paths** are
excluded by default (`BGB_NOTIFY_INCLUDE_PATHS=0`): the count of unreadable files
is the actionable part, the list of filenames on a host is an information
disclosure to an external endpoint.

## Consequences

**Positive**

- adding a channel is one file, no change to the orchestration
- a broken or slow endpoint cannot fail a backup
- healthchecks.io was not chosen for this deployment but remains one file away

**Accepted trade-off**

- a notifier failure is only visible in the log. Acceptable: the alternative is a
  failing notifier failing the backup.
- five providers is five things to keep working. Mitigated by keeping each one
  small and curl-based.

## Notes on specific providers

**Uptime Kuma push is the dead-man's switch.** It alerts when a push does *not*
arrive, which is the failure mode a "send mail on error" script can never
detect — a job that never runs sends nothing, and everything looks fine. It also
opens a maintenance window around the quiesce phase, without which every
consistent backup trips the service monitors and people learn to ignore Kuma.

**E-mail is failure-only by design.** A daily success mail from every host becomes
a filter rule within a week and an ignored channel within a month.

**`OnFailure=` is a separate systemd unit** because the in-process notifier cannot
fire when the process is killed — OOM, `RuntimeMaxSec`, SIGKILL — and those are
precisely the failures you most need to hear about.

## Alternatives considered

**One notifier, configurable URL.** Simplest, but the payload shapes genuinely
differ (Kuma query string, Teams Adaptive Card, RFC 5322).

**Delegate to systemd's `OnFailure=` only.** Covers failure but not success, and
therefore cannot feed a dead-man's switch.

## Revisit when

More than about eight providers accumulate, at which point a small plugin registry
with declared capabilities would beat a flat list.
