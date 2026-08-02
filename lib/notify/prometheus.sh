#!/usr/bin/env bash
# =============================================================================
# bg-backup - notifier: Prometheus (node_exporter textfile collector)
# =============================================================================
# A thin adapter. All the work is in lib/metrics.sh; this file exists so that
# "prometheus" can appear in BGB_NOTIFIERS alongside the channels that actually
# send something, and so the metrics are rewritten at exactly the same moment
# the other notifiers fire - after state has been persisted, never before.
#
# It is listed in BGB_MONITOR_STATEFUL_NOTIFIERS, so BGB_MONITOR_ON does NOT
# gate it. With the default BGB_MONITOR_ON=failure, gating would mean
# bg_backup_last_success_timestamp_seconds is only ever written on failure -
# a metric that is, by construction, never true.
#
# Nothing is pushed anywhere. There is no Pushgateway, deliberately: a
# Pushgateway keeps serving the last value it received forever, so a host that
# stops backing up (or stops existing) keeps reporting its final healthy sample
# and the stale-backup alert never fires. The textfile collector disappears with
# the host, which is the behaviour an alert on absence needs.
# =============================================================================

[ -n "${_BGB_NOTIFY_PROMETHEUS_SOURCED:-}" ] && return 0
_BGB_NOTIFY_PROMETHEUS_SOURCED=1

# bgb_notify_prometheus <event> <job> <rc> <payload-json> <log-excerpt-file>
bgb_notify_prometheus() {
  local job="${2:-}"

  if ! declare -F metrics_write >/dev/null 2>&1; then
    lib_source metrics.sh
  fi
  metrics_write "${job}"
  return 0
}
