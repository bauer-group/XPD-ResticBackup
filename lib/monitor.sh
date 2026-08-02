#!/usr/bin/env bash
# =============================================================================
# bg-backup - monitor: turn a run's outcome into notifications
# =============================================================================
# One dispatcher, several providers under lib/notify/<name>.sh. The dispatcher
# owns three guarantees, and all three exist because of the same failure mode:
#
#   1. A notifier NEVER changes the job's exit code. monitor_notify() returns 0
#      unconditionally. A monitoring system that can take down the backup it
#      monitors is worse than no monitoring at all - and it fails in the worst
#      possible way, by turning a green run into a red one at 3am for a reason
#      that has nothing to do with the data.
#
#   2. A notifier NEVER runs unbounded. Each provider runs in a subshell with a
#      watchdog. A webhook endpoint that accepts the TCP connection and then
#      never answers would otherwise hold the job (and its lock, and possibly a
#      quiesced Docker project) open forever.
#
#   3. A notifier NEVER sees an unredacted string. The payload, the summary line
#      and the log excerpt all pass redact() before they leave this process.
#
# EVENTS
#   start          a run has begun (informational; most providers ignore it)
#   success        snapshot(s) created, nothing unreadable
#   partial        snapshot created, some sources unreadable (restic exit 3)
#   failure        no usable snapshot
#   degraded       the run completed but a target was skipped/unreachable
#   check_ok       / check_failed     repository integrity check
#   verify_ok      / verify_failed    proven-restore test
#
# WHO IS GATED BY BGB_MONITOR_ON
#   BGB_MONITOR_ON gates the providers that INTERRUPT A HUMAN (email, teams,
#   webhook). It deliberately does NOT gate prometheus and uptime-kuma:
#
#     * prometheus records state, not alerts. With BGB_MONITOR_ON=failure the
#       default, gating it would mean bg_backup_last_success_timestamp_seconds
#       is only ever written when the backup FAILS - the metric would be a lie
#       and every stale-backup alert would be permanently firing.
#
#     * uptime-kuma is a dead-man's switch: it alerts when the push does NOT
#       arrive. Pushing only on failure means a healthy daily backup stops
#       pushing, Kuma goes red, and the operator learns to ignore it. The
#       gating that makes sense for e-mail is exactly backwards here.
# =============================================================================

[ -n "${_BGB_MONITOR_SOURCED:-}" ] && return 0
_BGB_MONITOR_SOURCED=1

# Providers that record state rather than interrupt a human. See the header.
: "${BGB_MONITOR_STATEFUL_NOTIFIERS:=prometheus uptime-kuma}"

# How many log lines the failure notifications carry.
: "${BGB_MONITOR_LOG_LINES:=100}"

# Set by monitor_context() before every dispatch and read by the providers.
# They live in the shell rather than being re-parsed out of the payload JSON so
# that a provider never needs jq - `notify` must still work on a rescue system.
_BGB_EV_EVENT=""
_BGB_EV_JOB=""
_BGB_EV_RC="0"
_BGB_EV_HOST=""
_BGB_EV_SEVERITY="info"
_BGB_EV_STATUS=""
_BGB_EV_PHASE=""
_BGB_EV_RUN_ID=""
_BGB_EV_SNAPSHOT=""
_BGB_EV_STARTED=""
_BGB_EV_ENDED=""
_BGB_EV_DURATION="0"
_BGB_EV_DURATION_HUMAN=""
_BGB_EV_QUIESCE="0"
_BGB_EV_BYTES_ADDED="0"
_BGB_EV_BYTES_PROCESSED="0"
_BGB_EV_FILES_NEW="0"
_BGB_EV_FILES_CHANGED="0"
_BGB_EV_FILES_UNMODIFIED="0"
_BGB_EV_FILES_UNREADABLE="0"
_BGB_EV_DB_DUMPS="0"
_BGB_EV_DB_DUMPS_FAILED="0"
_BGB_EV_DEGRADED_REASON=""
_BGB_EV_REPO=""
_BGB_EV_MSG=""
_BGB_EV_PING_MS="0"

_BGB_MAINTENANCE_OPEN=0
_BGB_MAINTENANCE_CLEANUP_REGISTERED=0

# -----------------------------------------------------------------------------
# Event classification
# -----------------------------------------------------------------------------

# monitor_event_severity <event> -> ok | warn | error | info
monitor_event_severity() {
  case "${1:-}" in
    success|check_ok|verify_ok) printf 'ok' ;;
    partial)                    printf 'warn' ;;
    start)                      printf 'info' ;;
    *)                          printf 'error' ;;
  esac
}

# monitor_event_status <event> -> the status word recorded in state/payloads.
monitor_event_status() {
  case "${1:-}" in
    success|check_ok|verify_ok) printf 'ok' ;;
    partial)                    printf 'partial' ;;
    degraded)                   printf 'degraded' ;;
    start)                      printf 'running' ;;
    *)                          printf 'failed' ;;
  esac
}

# monitor_should_notify <event>
# The human-facing gate. Returns 0 when a person should be interrupted.
#
# `partial` is routed by JOB_PARTIAL_IS_FAILURE rather than by a fixed rule:
# unreadable files during a live, unquiesced run are normal (rotating logs,
# sockets); the same exit code with services stopped is a real signal.
monitor_should_notify() {
  local event="${1:-}" sev
  sev="$(monitor_event_severity "${event}")"
  case "${BGB_MONITOR_ON:-failure}" in
    never)
      return 1 ;;
    always)
      return 0 ;;
    *)
      case "${sev}" in
        error) return 0 ;;
        warn)
          if [ "${JOB_PARTIAL_IS_FAILURE:-0}" = "1" ]; then return 0; fi
          return 1 ;;
        *) return 1 ;;
      esac ;;
  esac
}

# monitor_notifier_is_stateful <name> - true for providers that must run even
# when monitor_should_notify() says no.
monitor_notifier_is_stateful() {
  local name="${1:-}" n
  for n in ${BGB_MONITOR_STATEFUL_NOTIFIERS}; do
    if [ "${n}" = "${name}" ]; then return 0; fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Event context
# -----------------------------------------------------------------------------

# _monitor_state_field <job> <field> - read a field from the persisted state,
# tolerating state.sh not being loaded (the `internal` entry point used by
# systemd OnFailure= runs in a very small module set).
_monitor_state_field() {
  local job="${1:-}" field="${2:-}"
  [ -n "${job}" ] || return 0
  declare -F state_field >/dev/null 2>&1 || return 0
  state_field "${job}" "${field}" 2>/dev/null || true
}

# _monitor_pick <live-value> <job> <state-field> <default>
# Prefers the in-process run counter, falls back to what the last run wrote.
# The fallback is what makes `bg-backup internal notify-failure` - invoked by
# systemd after the main process was already killed - produce a useful message
# instead of a row of zeroes.
_monitor_pick() {
  local live="${1:-}" job="${2:-}" field="${3:-}" fallback="${4:-}" v
  if [ -n "${live}" ] && [ "${live}" != "0" ]; then printf '%s' "${live}"; return 0; fi
  v="$(_monitor_state_field "${job}" "${field}")"
  if [ -n "${v}" ] && [ "${v}" != "null" ]; then printf '%s' "${v}"; return 0; fi
  if [ -n "${live}" ]; then printf '%s' "${live}"; return 0; fi
  printf '%s' "${fallback}"
}

# monitor_context <event> <job> <rc> - populate the _BGB_EV_* block.
monitor_context() {
  local event="${1:-}" job="${2:-}" rc="${3:-0}"
  local now start

  _BGB_EV_EVENT="${event}"
  _BGB_EV_JOB="${job}"
  _BGB_EV_RC="${rc}"
  _BGB_EV_HOST="${BGB_HOSTNAME:-$(fqdn)}"
  _BGB_EV_SEVERITY="$(monitor_event_severity "${event}")"
  _BGB_EV_STATUS="$(monitor_event_status "${event}")"
  _BGB_EV_PHASE="${BGB_PHASE:-${BGB_COMMAND:-}}"
  _BGB_EV_RUN_ID="${BGB_RUN_ID:-$(_monitor_state_field "${job}" run_id)}"
  _BGB_EV_SNAPSHOT="$(_monitor_pick "${BGB_RUN_SNAPSHOT_ID:-}" "${job}" snapshot_id "")"

  # Duration: the live run is still in flight, so compute it from the start
  # stamp rather than reading a field that has not been written yet.
  now="$(now_epoch)"
  start="${BGB_RUN_STARTED_EPOCH:-}"
  if [ -n "${start}" ]; then
    _BGB_EV_DURATION=$(( now - start ))
    if [ "${_BGB_EV_DURATION}" -lt 0 ]; then _BGB_EV_DURATION=0; fi
  else
    _BGB_EV_DURATION="$(_monitor_pick "" "${job}" duration_seconds 0)"
  fi
  case "${_BGB_EV_DURATION}" in ''|*[!0-9]*) _BGB_EV_DURATION=0 ;; esac
  _BGB_EV_DURATION_HUMAN="$(human_duration "${_BGB_EV_DURATION}")"
  _BGB_EV_PING_MS=$(( _BGB_EV_DURATION * 1000 ))

  _BGB_EV_STARTED="$(_monitor_state_field "${job}" started)"
  _BGB_EV_ENDED="$(_monitor_state_field "${job}" ended)"

  _BGB_EV_QUIESCE="$(_monitor_pick "${BGB_RUN_QUIESCE_SECONDS:-}" "${job}" quiesce_seconds 0)"
  _BGB_EV_BYTES_ADDED="$(_monitor_pick "${BGB_RUN_BYTES_ADDED:-}" "${job}" bytes_added 0)"
  _BGB_EV_BYTES_PROCESSED="$(_monitor_pick "${BGB_RUN_BYTES_PROCESSED:-}" "${job}" bytes_processed 0)"
  _BGB_EV_FILES_NEW="$(_monitor_pick "${BGB_RUN_FILES_NEW:-}" "${job}" files_new 0)"
  _BGB_EV_FILES_CHANGED="$(_monitor_pick "${BGB_RUN_FILES_CHANGED:-}" "${job}" files_changed 0)"
  _BGB_EV_FILES_UNMODIFIED="$(_monitor_pick "${BGB_RUN_FILES_UNMODIFIED:-}" "${job}" files_unmodified 0)"
  _BGB_EV_FILES_UNREADABLE="$(_monitor_pick "${BGB_RUN_FILES_UNREADABLE:-}" "${job}" files_unreadable 0)"
  _BGB_EV_DB_DUMPS="$(_monitor_pick "${BGB_RUN_DB_DUMPS:-}" "${job}" db_dumps 0)"
  _BGB_EV_DB_DUMPS_FAILED="$(_monitor_pick "${BGB_RUN_DB_DUMPS_FAILED:-}" "${job}" db_dumps_failed 0)"

  _BGB_EV_DEGRADED_REASON="$(redact "${BGB_RUN_DEGRADED_REASON:-$(_monitor_state_field "${job}" degraded_reason)}")"

  # The repository PREFIX, never the URL: the URL can embed credentials and this
  # value ends up in a Teams card, a metric label and a mail body.
  _BGB_EV_REPO=""
  if declare -F repo_prefix >/dev/null 2>&1; then
    _BGB_EV_REPO="$(repo_prefix)"
  fi
  [ -n "${_BGB_EV_REPO}" ] || _BGB_EV_REPO="$(_monitor_state_field "${job}" repo_prefix)"

  _BGB_EV_MSG="$(monitor_summary_line)"
}

# monitor_summary_line - one redacted line, short enough for a URL query string
# and for a Kuma message field.
monitor_summary_line() {
  local s=""
  case "${_BGB_EV_EVENT}" in
    start)
      s="${_BGB_EV_JOB}: started" ;;
    success)
      s="${_BGB_EV_JOB}: OK - $(human_bytes "${_BGB_EV_BYTES_ADDED}") added, ${_BGB_EV_FILES_NEW} new files"
      if [ -n "${_BGB_EV_SNAPSHOT}" ]; then s="${s}, snapshot ${_BGB_EV_SNAPSHOT}"; fi
      s="${s}, ${_BGB_EV_DURATION_HUMAN}" ;;
    partial)
      s="${_BGB_EV_JOB}: PARTIAL - snapshot created but ${_BGB_EV_FILES_UNREADABLE} file(s) could not be read"
      if [ -n "${_BGB_EV_SNAPSHOT}" ]; then s="${s}, snapshot ${_BGB_EV_SNAPSHOT}"; fi
      s="${s}, ${_BGB_EV_DURATION_HUMAN}" ;;
    degraded)
      s="${_BGB_EV_JOB}: DEGRADED - ${_BGB_EV_DEGRADED_REASON:-a target was skipped}" ;;
    failure)
      s="${_BGB_EV_JOB}: FAILED (exit ${_BGB_EV_RC}) in phase ${_BGB_EV_PHASE:-backup} after ${_BGB_EV_DURATION_HUMAN}"
      if [ -n "${_BGB_EV_DEGRADED_REASON}" ]; then s="${s} - ${_BGB_EV_DEGRADED_REASON}"; fi ;;
    check_ok)
      s="${_BGB_EV_JOB:-repository}: integrity check passed" ;;
    check_failed)
      s="${_BGB_EV_JOB:-repository}: INTEGRITY CHECK FAILED (exit ${_BGB_EV_RC}) - the repository may be damaged" ;;
    verify_ok)
      s="${_BGB_EV_JOB:-repository}: restore test passed" ;;
    verify_failed)
      s="${_BGB_EV_JOB:-repository}: RESTORE TEST FAILED (exit ${_BGB_EV_RC}) - snapshots exist but did not restore" ;;
    *)
      s="${_BGB_EV_JOB}: ${_BGB_EV_EVENT} (exit ${_BGB_EV_RC})" ;;
  esac
  if [ -n "${_BGB_EV_DB_DUMPS_FAILED}" ] && [ "${_BGB_EV_DB_DUMPS_FAILED}" != "0" ]; then
    s="${s} [${_BGB_EV_DB_DUMPS_FAILED} database dump(s) failed]"
  fi
  redact "${s}"
}

# -----------------------------------------------------------------------------
# Payload
# -----------------------------------------------------------------------------

# monitor_payload [extra-json-fragment]
# The extra fragment is a comma-less list of `"key":value` pairs WITHOUT the
# surrounding braces, exactly like json_envelope's body argument.
#
# Built with the json_* helpers rather than jq: a notification must still be
# deliverable from a rescue system where only bash and curl exist.
monitor_payload() {
  local extra="${1:-}" doc
  doc="$(
    printf '{'
    json_kvraw schema "${BGB_JSON_SCHEMA}"; printf ','
    json_kv event "${_BGB_EV_EVENT}"; printf ','
    json_kv severity "${_BGB_EV_SEVERITY}"; printf ','
    json_kv status "${_BGB_EV_STATUS}"; printf ','
    json_kv host "${_BGB_EV_HOST}"; printf ','
    json_kv job "${_BGB_EV_JOB}"; printf ','
    json_kv phase "${_BGB_EV_PHASE}"; printf ','
    json_kv repo "${_BGB_EV_REPO}"; printf ','
    json_kvraw rc "$(json_num "${_BGB_EV_RC}")"; printf ','
    json_kv run_id "${_BGB_EV_RUN_ID}"; printf ','
    json_kv snapshot_id "${_BGB_EV_SNAPSHOT}"; printf ','
    json_kv started "${_BGB_EV_STARTED}"; printf ','
    json_kv ended "${_BGB_EV_ENDED}"; printf ','
    json_kvraw duration_seconds "$(json_num "${_BGB_EV_DURATION}")"; printf ','
    json_kvraw quiesce_seconds "$(json_num "${_BGB_EV_QUIESCE}")"; printf ','
    json_kvraw bytes_added "$(json_num "${_BGB_EV_BYTES_ADDED}")"; printf ','
    json_kvraw bytes_processed "$(json_num "${_BGB_EV_BYTES_PROCESSED}")"; printf ','
    json_kvraw files_new "$(json_num "${_BGB_EV_FILES_NEW}")"; printf ','
    json_kvraw files_changed "$(json_num "${_BGB_EV_FILES_CHANGED}")"; printf ','
    json_kvraw files_unmodified "$(json_num "${_BGB_EV_FILES_UNMODIFIED}")"; printf ','
    json_kvraw files_unreadable "$(json_num "${_BGB_EV_FILES_UNREADABLE}")"; printf ','
    json_kvraw db_dumps "$(json_num "${_BGB_EV_DB_DUMPS}")"; printf ','
    json_kvraw db_dumps_failed "$(json_num "${_BGB_EV_DB_DUMPS_FAILED}")"; printf ','
    json_kv degraded_reason "${_BGB_EV_DEGRADED_REASON}"; printf ','
    json_kv message "${_BGB_EV_MSG}"; printf ','
    json_kv tool_version "${BGB_VERSION:-}"; printf ','
    json_kv generated "$(now_iso)"
    [ -n "${extra}" ] && { printf ','; printf '%s' "${extra}"; }
    printf '}'
  )"

  # Redact the finished document, not each field: a value we did not think to
  # sanitise (a hook's error message pasted into degraded_reason, a path that
  # happens to contain a token) is caught here or nowhere. The replacement text
  # contains no quote or backslash, so this cannot break the JSON.
  redact "${doc}"
}

# -----------------------------------------------------------------------------
# Log excerpt
# -----------------------------------------------------------------------------

monitor_log_file() {
  local job="${1:-}"
  if [ -n "${BGB_RUN_LOG:-}" ] && [ -r "${BGB_RUN_LOG}" ]; then
    printf '%s' "${BGB_RUN_LOG}"; return 0
  fi
  if [ -n "${_BGB_LOGFILE:-}" ] && [ -r "${_BGB_LOGFILE}" ]; then
    printf '%s' "${_BGB_LOGFILE}"; return 0
  fi
  if [ -n "${job}" ] && [ -r "${BGB_LOG_DIR}/${job}.log" ]; then
    printf '%s' "${BGB_LOG_DIR}/${job}.log"; return 0
  fi
  [ -r "${BGB_LOG_DIR}/bg-backup.log" ] && printf '%s' "${BGB_LOG_DIR}/bg-backup.log"
  return 0
}

# monitor_excerpt_file <job> - a 0600 temp file with the last N REDACTED log
# lines. Providers get a path rather than a string so a large excerpt never has
# to be carried through argv or a shell variable.
monitor_excerpt_file() {
  local job="${1:-}" src out
  out="$(tmp_file "excerpt.XXXXXX" 2>/dev/null || true)"
  [ -n "${out}" ] || { printf ''; return 0; }
  chmod 0600 "${out}" 2>/dev/null || true
  src="$(monitor_log_file "${job}")"
  if [ -n "${src}" ] && [ -r "${src}" ]; then
    tail -n "${BGB_MONITOR_LOG_LINES}" "${src}" 2>/dev/null | redact_stream >"${out}" 2>/dev/null || true
  fi
  printf '%s' "${out}"
}

# -----------------------------------------------------------------------------
# curl helpers (shared by every HTTP provider)
# -----------------------------------------------------------------------------
# EVERY HTTP provider talks to curl through a --config file, never through argv.
#
# That is not stylistic. The Uptime Kuma push URL, the Teams workflow URL and
# the generic webhook URL are all bearer credentials: whoever holds the string
# can post as us, and in Kuma's case can silence the dead-man's switch. argv is
# world-readable through /proc/<pid>/cmdline for the lifetime of the process, so
# a single `ps auxww` from any unprivileged account on the box captures them.
# A 0600 file in our private temp tree does not have that property.

# monitor_curl_escape <value> - escape for a curl config file's quoted value.
monitor_curl_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# monitor_curl_conf_new - a 0600 curl config seeded with the common options.
# Prints the path, or nothing when a temp file cannot be created.
monitor_curl_conf_new() {
  local f
  f="$(tmp_file "curl.XXXXXX" 2>/dev/null || true)"
  [ -n "${f}" ] || { printf ''; return 0; }
  chmod 0600 "${f}" 2>/dev/null || true
  {
    printf 'silent\n'
    printf 'show-error\n'
    # --fail: an HTTP 4xx/5xx becomes a non-zero exit. Without it curl happily
    # reports success for "410 Gone - this webhook was deleted".
    printf 'fail\n'
    # Deliberately NO `location`: following a redirect would replay the request
    # body, and any credential in it, against a host we never chose.
    printf 'max-time = %s\n' "$(monitor_curl_escape "${BGB_MONITOR_TIMEOUT_SECONDS:-15}")"
    printf 'connect-timeout = 10\n'
    printf 'retry = 2\n'
    printf 'retry-delay = 2\n'
    printf 'user-agent = "bg-backup/%s"\n' "$(monitor_curl_escape "${BGB_VERSION:-0}")"
  } >"${f}" 2>/dev/null || { printf ''; return 0; }
  printf '%s' "${f}"
}

# monitor_curl_conf_add <file> <curl-long-option> <value>
monitor_curl_conf_add() {
  local f="${1:-}" key="${2:-}" val="${3:-}"
  [ -n "${f}" ] || return 0
  printf '%s = "%s"\n' "${key}" "$(monitor_curl_escape "${val}")" >>"${f}"
}

# monitor_curl_run <config-file> - execute, printing curl's own error on stderr
# (which the dispatcher captures and logs redacted).
monitor_curl_run() {
  local conf="${1:-}"; shift || true
  if ! have curl; then
    printf 'curl is not installed - cannot deliver notification\n' >&2
    return 1
  fi
  [ -n "${conf}" ] && [ -r "${conf}" ] || {
    printf 'could not create a curl config file (is %s writable?)\n' "${BGB_TMP_DIR}" >&2
    return 1
  }
  curl --config "${conf}" "$@"
}

# monitor_register_secrets - teach redact() about the credentials that only the
# monitoring layer knows.
#
# redact_register_env() covers the three webhook URLs because they are declared
# in bg-backup.conf. The API tokens below are optional extras, so they are
# registered here instead - and they MUST be registered in this process, not in
# the provider's subshell: the provider's output is captured to a file and then
# written to the log by the PARENT, using the parent's secret list. A secret
# registered inside the watchdog subshell would be masked nowhere that matters.
monitor_register_secrets() {
  # Pull in notify.env first: under systemd it arrives through LoadCredential=
  # (see docs/adr/0003), on a manual run it is read from the credentials
  # directory. Loading it here rather than at config time keeps the notifier
  # tokens out of every process that does not send a notification.
  declare -F notify_env_load >/dev/null 2>&1 && notify_env_load

  declare -F redact_register >/dev/null 2>&1 || return 0
  redact_register \
    "${BGB_MONITOR_KUMA_PUSH_URL:-}" \
    "${BGB_MONITOR_KUMA_API_KEY:-}" \
    "${BGB_MONITOR_TEAMS_WEBHOOK_URL:-}" \
    "${BGB_MONITOR_WEBHOOK_URL:-}" \
    "${BGB_MONITOR_WEBHOOK_TOKEN:-}"
  return 0
}

# -----------------------------------------------------------------------------
# Provider execution
# -----------------------------------------------------------------------------

# monitor_load_notifier <name> - resolve a notifier name to its function.
# Prints the function name on success, nothing when the provider is unknown.
#
# The file name keeps the hyphen (lib/notify/uptime-kuma.sh) because that is
# what the operator writes in BGB_NOTIFIERS; the function name gets underscores
# because a hyphenated function name, while legal in bash, cannot be called
# through most tooling and reads like a typo in a stack trace.
monitor_load_notifier() {
  local name="${1:-}" fn
  fn="bgb_notify_${name//-/_}"
  if ! declare -F "${fn}" >/dev/null 2>&1; then
    if [ -r "${BGB_LIB_DIR}/notify/${name}.sh" ]; then
      lib_source "notify/${name}.sh"
    fi
  fi
  declare -F "${fn}" >/dev/null 2>&1 || return 1
  printf '%s' "${fn}"
}

# monitor_run_guarded <function> [args...]
#
# timeout(1) cannot wrap a shell function: it execs a program, and the provider
# lives in this shell's function table together with log(), redact() and the
# loaded configuration. Exporting the function into a child bash would lose all
# of that. So the watchdog is implemented here with the same semantics timeout
# has - TERM at the deadline, KILL one second later.
monitor_run_guarded() {
  local fn="${1:-}"; shift || true
  local secs="${BGB_MONITOR_TIMEOUT_SECONDS:-15}"
  local out pid rc=0 waited=0 timed_out=0 line

  case "${secs}" in ''|*[!0-9]*) secs=15 ;; esac
  # 0 is not a way to disable the watchdog: a provider that hangs forever holds
  # the whole run open and delays the next scheduled one.
  [ "${secs}" -lt 1 ] && secs=1

  out="$(tmp_file "notify.XXXXXX" 2>/dev/null || true)"
  [ -n "${out}" ] || out="/dev/null"

  (
    # Bash resets trapped signals in a ( ... ) subshell, so the EXIT trap that
    # install_traps() set will not fire here. We clear the registry and the
    # traps anyway, because it costs two lines and the failure mode is
    # catastrophic: a notifier subshell running _bgb_run_cleanup() would release
    # the repository lock, un-quiesce Docker and delete the temp tree WHILE THE
    # BACKUP IT IS REPORTING ON IS STILL RUNNING.
    trap - EXIT INT TERM
    _BGB_CLEANUP_HANDLERS=()
    "${fn}" "$@"
  ) >"${out}" 2>&1 &
  pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${secs}" ]; then
      timed_out=1
      { kill -TERM "${pid}" 2>/dev/null || true; } 2>/dev/null
      sleep 1
      { kill -KILL "${pid}" 2>/dev/null || true; } 2>/dev/null
      break
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done

  # `wait` on a killed child returns 128+signal; suppress bash's own job-status
  # chatter, which would otherwise print "Terminated" onto the operator's stderr.
  { wait "${pid}" || rc=$?; } 2>/dev/null

  if [ "${timed_out}" -eq 1 ]; then
    warn "Notifier ${fn} exceeded ${secs}s and was killed (the run is unaffected)"
    return 124
  fi

  if [ "${rc}" -ne 0 ]; then
    warn "Notifier ${fn} failed (rc=${rc}) - the run's exit code is unaffected"
    if [ "${out}" != "/dev/null" ] && [ -s "${out}" ]; then
      # warn() redacts on the way out, so curl echoing back the URL it just
      # failed to reach cannot put a push token in the log.
      while IFS= read -r line; do
        [ -n "${line}" ] && warn "  ${fn}: ${line}"
      done < <(tail -n 5 "${out}" 2>/dev/null)
    fi
  fi
  return "${rc}"
}

# -----------------------------------------------------------------------------
# The dispatcher
# -----------------------------------------------------------------------------

# monitor_notify <event> <job> <rc> [extra-json]
# ALWAYS returns 0. See guarantee (1) in the file header.
monitor_notify() {
  local event="${1:-}" job="${2:-${BGB_JOB:-}}" rc="${3:-0}" extra="${4:-}"
  local -a notifiers=()
  local n fn payload excerpt

  [ -n "${event}" ] || return 0

  if [ "${BGB_MONITOR_ON:-failure}" = "never" ] \
     && [ -z "${BGB_MONITOR_STATEFUL_NOTIFIERS}" ]; then
    debug "monitor: BGB_MONITOR_ON=never, nothing to dispatch"
    return 0
  fi

  # Materialise the private temp tree HERE, in the parent. tmp_root() registers
  # its own cleanup handler; letting a provider create it inside the watchdog
  # subshell would register that handler in a process that never runs cleanup,
  # leaving a 0700 directory behind on every single run.
  tmp_root >/dev/null 2>&1 || true
  monitor_register_secrets

  monitor_context "${event}" "${job}" "${rc}"
  payload="$(monitor_payload "${extra}")"
  excerpt="$(monitor_excerpt_file "${job}")"

  log "${_BGB_EV_MSG}"

  # Deliberate word splitting: BGB_NOTIFIERS is a space-separated list.
  read -r -a notifiers <<<"${BGB_NOTIFIERS:-}" || true

  for n in "${notifiers[@]:-}"; do
    [ -n "${n}" ] || continue

    if ! monitor_notifier_is_stateful "${n}" && ! monitor_should_notify "${event}"; then
      debug "monitor: ${n} skipped (BGB_MONITOR_ON=${BGB_MONITOR_ON:-failure}, event=${event})"
      continue
    fi

    if ! fn="$(monitor_load_notifier "${n}")"; then
      warn "Unknown notifier '${n}' - no ${BGB_LIB_DIR}/notify/${n}.sh (check BGB_NOTIFIERS)"
      continue
    fi

    if [ "${BGB_DRY_RUN:-0}" = "1" ]; then
      log "[dry-run] would notify via ${n}: ${_BGB_EV_MSG}"
      continue
    fi

    debug "monitor: dispatching ${event} to ${n}"
    monitor_run_guarded "${fn}" "${event}" "${job}" "${rc}" "${payload}" "${excerpt}" || true
  done

  return 0
}

# -----------------------------------------------------------------------------
# Maintenance window
# -----------------------------------------------------------------------------
# Wrapped around the quiesce phase. Without it, every consistent backup that
# pauses or stops containers trips the service monitors watching those same
# containers, the on-call channel fills with three minutes of red every night,
# and within a fortnight nobody reads Uptime Kuma at all. The alerting you
# switched off by habit is worse than the alerting you never installed.

monitor_maintenance_begin() {
  local job="${1:-${BGB_JOB:-}}" fn
  [ "${BGB_MONITOR_KUMA_MAINTENANCE:-0}" = "1" ] || return 0
  [ "${BGB_DRY_RUN:-0}" = "1" ] && { log "[dry-run] would open the Kuma maintenance window"; return 0; }

  if ! fn="$(monitor_load_notifier uptime-kuma)"; then
    warn "BGB_MONITOR_KUMA_MAINTENANCE=1 but the uptime-kuma provider is missing"
    return 0
  fi

  # Register the closer BEFORE opening the window. If the process dies between
  # the two, the cleanup registry still closes it. A maintenance window left
  # open silences the monitors indefinitely - it is the one failure in this file
  # that degrades security rather than just losing a message.
  if [ "${_BGB_MAINTENANCE_CLEANUP_REGISTERED}" -eq 0 ]; then
    on_cleanup monitor_maintenance_cleanup
    _BGB_MAINTENANCE_CLEANUP_REGISTERED=1
  fi
  _BGB_MAINTENANCE_OPEN=1

  tmp_root >/dev/null 2>&1 || true
  monitor_register_secrets
  log "Opening the Uptime Kuma maintenance window for ${job}"
  monitor_run_guarded bgb_kuma_maintenance on "${job}" || true
  return 0
}

monitor_maintenance_end() {
  local job="${1:-${BGB_JOB:-}}"
  [ "${_BGB_MAINTENANCE_OPEN}" = "1" ] || return 0
  _BGB_MAINTENANCE_OPEN=0
  [ "${BGB_DRY_RUN:-0}" = "1" ] && return 0

  declare -F bgb_kuma_maintenance >/dev/null 2>&1 || return 0
  log "Closing the Uptime Kuma maintenance window for ${job}"
  monitor_run_guarded bgb_kuma_maintenance off "${job}" || true
  return 0
}

monitor_maintenance_cleanup() {
  [ "${_BGB_MAINTENANCE_OPEN}" = "1" ] || return 0
  warn "Closing a maintenance window left open by an interrupted run"
  monitor_maintenance_end "${BGB_JOB:-}"
  return 0
}
