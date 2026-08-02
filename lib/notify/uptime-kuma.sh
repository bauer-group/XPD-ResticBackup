#!/usr/bin/env bash
# =============================================================================
# bg-backup - notifier: Uptime Kuma push monitor (the dead-man's switch)
# =============================================================================
# THE point of this provider, and the reason it is enabled by default:
#
#   Every other channel in this tool reports a failure that happened. None of
#   them can report a backup that never started - a disabled timer, a host that
#   was rebuilt without bg-backup, a job renamed so its unit no longer exists, a
#   machine that has been powered off since March. A "mail me on error" script
#   is structurally incapable of noticing any of those, because the code that
#   would send the mail is the code that did not run.
#
#   Uptime Kuma's push monitor inverts the test: Kuma alerts when the push does
#   NOT arrive within the heartbeat interval. Silence becomes the alarm.
#
# Pure curl on purpose. This has to work on a minimal Ubuntu server and on a
# rescue system; a Python client would be one more thing to be missing at the
# exact moment it is needed.
#
# The push URL is a CREDENTIAL: whoever holds it can mark the monitor up, which
# means whoever holds it can silence the dead-man's switch. It therefore never
# appears in argv - see the curl helpers in lib/monitor.sh.
# =============================================================================

[ -n "${_BGB_NOTIFY_KUMA_SOURCED:-}" ] && return 0
_BGB_NOTIFY_KUMA_SOURCED=1

# _kuma_push_status <event> -> up | down | skip
#
# check_ok and verify_ok deliberately map to "skip", not "up".
#
# That is the subtle one. The push URL belongs to a monitor whose heartbeat
# interval is sized for the BACKUP schedule - daily, say. A weekly integrity
# check pushing "up" would refresh that heartbeat, so a host whose backups have
# been silently dead for six days would still look green every Wednesday
# morning. The dead-man's switch would be armed by the wrong event and the
# failure it exists to catch would be the failure it hides.
#
# check_failed and verify_failed DO push "down": a damaged repository must reach
# the operator, and there is no risk of a false green in that direction.
_kuma_push_status() {
  case "${1:-}" in
    success)                 printf 'up' ;;
    partial)
      # A partial run produced a restorable snapshot. Whether that is "up"
      # depends on the same switch that decides whether a human is woken.
      if [ "${JOB_PARTIAL_IS_FAILURE:-0}" = "1" ]; then printf 'down'; else printf 'up'; fi ;;
    failure|degraded|check_failed|verify_failed) printf 'down' ;;
    *)                       printf 'skip' ;;
  esac
}

# bgb_notify_uptime_kuma <event> <job> <rc> <payload-json> <log-excerpt-file>
bgb_notify_uptime_kuma() {
  local event="${1:-}" status conf msg

  [ -n "${BGB_MONITOR_KUMA_PUSH_URL:-}" ] || return 0

  status="$(_kuma_push_status "${event}")"
  if [ "${status}" = "skip" ]; then
    # `start` lands here too, and must: pushing "up" at the beginning of a run
    # would reset the heartbeat before any work happened, so a job that hangs
    # for six hours and is then killed would have already reported healthy.
    return 0
  fi

  conf="$(monitor_curl_conf_new)"
  [ -n "${conf}" ] || return 0

  # Kuma renders msg as plain text in the heartbeat list and in the alert body.
  # It is already redacted (monitor_context builds it through redact()), and
  # trimmed here because it travels in a URL query string.
  msg="${_BGB_EV_MSG}"
  [ "${#msg}" -gt 480 ] && msg="${msg:0:477}..."

  monitor_curl_conf_add "${conf}" url "${BGB_MONITOR_KUMA_PUSH_URL}"
  # `get` is curl's -G: the data below becomes a query string instead of a
  # request body. Kuma's push endpoint only reads query parameters.
  printf 'get\n' >>"${conf}"
  monitor_curl_conf_add "${conf}" data-urlencode "status=${status}"
  monitor_curl_conf_add "${conf}" data-urlencode "msg=${msg}"
  # Kuma graphs `ping` as a response time in milliseconds. The run duration is
  # the honest analogue and turns the monitor's chart into a backup-duration
  # trend, which is where a slowly degrading repository shows up first.
  monitor_curl_conf_add "${conf}" data-urlencode "ping=${_BGB_EV_PING_MS:-0}"

  monitor_curl_run "${conf}" >/dev/null || return 1
  return 0
}

# -----------------------------------------------------------------------------
# Maintenance window
# -----------------------------------------------------------------------------
# bgb_kuma_maintenance <on|off> [job]
#
# Called by monitor_maintenance_begin/end around the quiesce phase. Without it,
# a JOB_QUIESCE=docker-stop job takes the application down for its backup window
# and every HTTP monitor pointed at that application goes red on schedule. The
# operator's own monitoring then trains them to ignore the channel that is
# supposed to wake them up.
#
# Uptime Kuma exposes maintenance control over its authenticated API rather than
# over the push endpoint, so this needs BGB_MONITOR_KUMA_API_URL, a maintenance
# entry created once in the UI (BGB_MONITOR_KUMA_MAINTENANCE_ID) and an API key.
# The semantics are inverted from what the names suggest: a maintenance entry is
# "active" while it is RESUMED, so opening the window resumes it and closing the
# window pauses it again.
#
# Older Kuma releases have no such endpoint. A failure here is logged and
# discarded like any other notifier failure - the backup proceeds either way.
bgb_kuma_maintenance() {
  local action="${1:-off}" job="${2:-}" conf endpoint

  [ -n "${BGB_MONITOR_KUMA_API_URL:-}" ] || return 0
  [ -n "${BGB_MONITOR_KUMA_MAINTENANCE_ID:-}" ] || return 0

  case "${action}" in
    on)  endpoint="resume" ;;
    off) endpoint="pause" ;;
    *)   return 0 ;;
  esac

  conf="$(monitor_curl_conf_new)"
  [ -n "${conf}" ] || return 0

  monitor_curl_conf_add "${conf}" url \
    "${BGB_MONITOR_KUMA_API_URL%/}/maintenance/${BGB_MONITOR_KUMA_MAINTENANCE_ID}/${endpoint}"
  printf 'request = "POST"\n' >>"${conf}"
  monitor_curl_conf_add "${conf}" header "Content-Type: application/json"
  monitor_curl_conf_add "${conf}" data "{}"

  # Kuma authenticates API keys as HTTP basic with an EMPTY username. The key
  # goes into the 0600 config file, never into argv: `curl -u :KEY` would put a
  # credential that can silence every monitor into /proc/<pid>/cmdline, readable
  # by any account on the host for as long as curl runs.
  if [ -n "${BGB_MONITOR_KUMA_API_KEY:-}" ]; then
    monitor_curl_conf_add "${conf}" user ":${BGB_MONITOR_KUMA_API_KEY}"
  fi

  debug "kuma: ${endpoint} maintenance ${BGB_MONITOR_KUMA_MAINTENANCE_ID} for job ${job:-<none>}"
  monitor_curl_run "${conf}" >/dev/null || return 1
  return 0
}
