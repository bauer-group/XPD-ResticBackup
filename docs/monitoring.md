# Monitoring

## The principle

A backup nobody hears about failing is a backup that fails silently for months.
But the inverse matters just as much: **a notifier never changes a job's exit
code.** Monitoring that can take down the backup it monitors is worse than none.

Each provider runs in a subshell with a timeout; a failure is logged (redacted)
and the run continues.

## Providers

```bash
BGB_NOTIFIERS="uptime-kuma prometheus email teams"
BGB_MONITOR_ON="failure"          # always | failure | never
BGB_MONITOR_TIMEOUT_SECONDS="15"
```

### Uptime Kuma push — the dead-man's switch

```bash
BGB_MONITOR_KUMA_PUSH_URL="https://kuma.example.com/api/push/<token>"
BGB_MONITOR_KUMA_MAINTENANCE="1"
```

This is the important one. Kuma alerts when a push does **not** arrive, which is
the failure a "send mail on error" script can never detect: a job that never runs
sends nothing, and everything looks fine.

Set the monitor's expected interval to the job's schedule plus a tolerance.

**Enable the maintenance window** if the job quiesces anything. Without it, every
consistent backup trips the service monitors, and people learn to ignore Kuma —
which costs you the alert you actually needed.

### E-mail — failures only

```bash
BGB_MONITOR_MAIL_TO="support@support.bauer-group.com"
```

Deliberately never on success. A daily success mail from every host becomes a
filter rule within a week and an ignored channel within a month.

Subject: `[bg-backup] FAILURE <job> on <fqdn> (exit N)`.
Body: redacted summary, the last 100 redacted log lines, and the exact command to
investigate.

### Microsoft Teams

```bash
BGB_MONITOR_TEAMS_WEBHOOK_URL="https://…/workflows/…"
```

Adaptive Card on failure and partial. The webhook URL is a credential — anyone
holding it can post as the bot — so it lives in `notify.env` (0400) and is
redacted from all output.

### Prometheus textfile

```bash
BGB_METRICS_TEXTFILE="/var/lib/node_exporter/textfile_collector/bg-backup.prom"
```

Written atomically (temp + rename). The collector reads the directory on every
scrape, and a half-written file is a parse error for the **whole file**, not just
the truncated line.

## Metrics

Prefix `bg_backup_` with **underscores** — Prometheus metric names may not
contain dashes. Labels on every series: `host`, `job`, and `repo` (the repository
**prefix**, never the URL, which can embed credentials).

| Metric | |
|---|---|
| `bg_backup_build_info{version,restic_version}` | |
| `bg_backup_last_run_timestamp_seconds` | |
| `bg_backup_last_success_timestamp_seconds` | **the one that matters** |
| `bg_backup_run_exit_code` | 0 / 1 / 3 |
| `bg_backup_run_success` | 1 when a snapshot was produced |
| `bg_backup_run_duration_seconds` | |
| `bg_backup_quiesce_duration_seconds` | how long services were down |
| `bg_backup_files_new` / `_changed` / `_unmodified` / `_unreadable` | |
| `bg_backup_bytes_processed` / `_bytes_added` | |
| `bg_backup_snapshot_info{snapshot_id}` | |
| `bg_backup_db_dumps` / `_db_dumps_failed` | |
| `bg_backup_degraded_targets` | consistency not guaranteed |
| `bg_backup_check_last_run_timestamp_seconds` / `_check_success` | |
| `bg_backup_verify_last_success_timestamp_seconds` | last **proven** restore |
| `bg_backup_repo_snapshots_total{tag}` / `_repo_size_bytes` | |
| `bg_backup_repo_fully_verified_age_days` | whole repository byte-verified within N days |
| `bg_backup_recovery_bundle_age_days` | |
| `bg_backup_config_export_stale` | config changed since the last bundle export |

All are **gauges**. These are per-run values reset each run, not monotonic
counters; typing them `counter` would make `rate()` produce nonsense at every run
boundary.

## Alert rules

```yaml
groups:
  - name: bg-backup
    rules:
      # The single most important rule. Fires whether the job failed, never
      # started, or the host disappeared.
      - alert: BackupStale
        expr: time() - bg_backup_last_success_timestamp_seconds > 172800
        for: 1h
        labels: {severity: critical}
        annotations:
          summary: "No successful backup of {{ $labels.job }} on {{ $labels.host }} for 48h"

      - alert: BackupFailing
        expr: bg_backup_run_success == 0
        for: 10m
        labels: {severity: critical}

      - alert: BackupDegraded
        expr: bg_backup_degraded_targets > 0
        for: 30m
        labels: {severity: warning}
        annotations:
          summary: "A snapshot exists but its consistency is not guaranteed"

      - alert: BackupRepoCheckFailed
        expr: bg_backup_check_success == 0
        labels: {severity: critical}
        annotations:
          summary: "Repository integrity check failed - do NOT prune"

      # Exit 3 is normal during a live phase. Persistently 3 is not.
      - alert: BackupPartialPersistent
        expr: bg_backup_run_exit_code == 3
        for: 72h
        labels: {severity: warning}

      - alert: BackupNeverVerified
        expr: time() - bg_backup_verify_last_success_timestamp_seconds > 3888000
        labels: {severity: warning}
        annotations:
          summary: "No restore proven in 45 days - this backup is a hypothesis"

      - alert: BackupRepoNotFullyVerified
        expr: bg_backup_repo_fully_verified_age_days > 45

      - alert: BackupBundleStale
        expr: bg_backup_recovery_bundle_age_days > 90
        annotations:
          summary: "Recovery bundle is stale - a total loss may be unrecoverable"

      - alert: BackupConfigExportStale
        expr: bg_backup_config_export_stale == 1
        annotations:
          summary: "Configuration changed since the last bundle export"

      # Ransomware canary: re-encrypted files change every block.
      - alert: BackupGrowthAnomaly
        expr: |
          bg_backup_bytes_added
            > 3 * avg_over_time(bg_backup_bytes_added[7d])
        for: 10m
        labels: {severity: warning}
```

## What is reported when

| Event | Kuma | Mail | Teams | `.prom` |
|---|---|---|---|---|
| start | maintenance window opens | — | — | — |
| success | `up` + duration | — | weekly digest (optional) | ✅ |
| partial (exit 3) | `up`, message notes partial | live: no · quiesced: yes | ✅ | ✅ |
| degraded | `down` | ✅ | ✅ | ✅ |
| failure | `down` | ✅ | ✅ | ✅ |
| killed / timeout | `down` via `OnFailure=` | ✅ | ✅ | stale — `BackupStale` fires |
| check / verify failed | separate monitor | ✅ | ✅ | ✅ |

`OnFailure=bg-backup-failure@%i.service` is a **separate unit** because the
in-process notifier cannot fire when the process is killed — OOM,
`RuntimeMaxSec`, SIGKILL — and those are precisely the failures you most need to
hear about.

## Two things monitoring cannot do from the host

**A dead host cannot report that it is dead.** Add a pull-side check on the
monitoring host that enumerates every *expected* host and alerts on any whose
newest complete run exceeds its SLA. That is what catches "the host was
decommissioned and nobody noticed the pings stopped" and "someone disabled the
check".

**Log excerpts must be redacted before they leave.** Everything attached to a
notification passes `redact()` and is truncated to 60 KB. Filenames are **not**
sent by default (`BGB_NOTIFY_INCLUDE_PATHS=0`): the count of unreadable files is
the actionable part, the list of filenames on a host is an information disclosure
to an external endpoint.

## Testing it

Do this once, deliberately:

```bash
# revoke the S3 key for five minutes, let the timer fire, and confirm a human
# is actually reached
```

This is the test people skip, and it is the only one that proves the monitoring
works.
