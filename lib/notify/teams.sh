#!/usr/bin/env bash
# =============================================================================
# bg-backup - notifier: Microsoft Teams (Adaptive Card via Workflows webhook)
# =============================================================================
# Posts an Adaptive Card to a Power Automate / Teams Workflows webhook URL.
#
# NOT the old MessageCard / Office 365 connector format. Microsoft retired
# Office 365 connectors, and the legacy `"@type": "MessageCard"` payload either
# renders as a bare block of text or is rejected outright by a Workflows
# endpoint. The envelope below - a `message` with one
# `application/vnd.microsoft.card.adaptive` attachment - is what the "When a
# Teams webhook request is received" trigger expects.
#
# The card is deliberately dense: a FactSet an on-call engineer can read on a
# phone lock screen and decide whether this needs a laptop. Long-form detail
# (the log excerpt) goes to e-mail, not into a chat message that will be scrolled
# past - and never into a channel that outlives the incident, because a log
# excerpt in a chat history is an information disclosure with a very long tail.
#
# The webhook URL is a credential: anyone holding it can post into the channel
# as this bot. It therefore travels through a 0600 curl config file, not argv.
# =============================================================================

[ -n "${_BGB_NOTIFY_TEAMS_SOURCED:-}" ] && return 0
_BGB_NOTIFY_TEAMS_SOURCED=1

# Adaptive Card colour tokens. "Attention" is red, "Warning" amber, "Good"
# green - the names are the schema's, not ours.
_teams_colour() {
  case "${1:-}" in
    ok)    printf 'Good' ;;
    warn)  printf 'Warning' ;;
    error) printf 'Attention' ;;
    *)     printf 'Default' ;;
  esac
}

_teams_title() {
  case "${_BGB_EV_EVENT}" in
    success)       printf 'Backup succeeded' ;;
    partial)       printf 'Backup PARTIAL' ;;
    degraded)      printf 'Backup DEGRADED' ;;
    failure)       printf 'Backup FAILED' ;;
    check_ok)      printf 'Repository check passed' ;;
    check_failed)  printf 'Repository check FAILED' ;;
    verify_ok)     printf 'Restore test passed' ;;
    verify_failed) printf 'Restore test FAILED' ;;
    *)             printf 'Backup %s' "${_BGB_EV_EVENT}" ;;
  esac
}

# _teams_fact <title> <value> - one FactSet entry, or nothing when the value is
# empty. An empty fact renders as a dangling label and makes the card look
# broken, which is a surprisingly effective way to get a channel muted.
_teams_fact() {
  local title="${1:-}" value="${2:-}"
  [ -n "${value}" ] || return 0
  printf '{%s,%s}' "$(json_kv title "${title}")" "$(json_kv value "${value}")"
}

_teams_facts() {
  local out="" f
  local -a items=()

  items+=("$(_teams_fact 'Host' "${_BGB_EV_HOST}")")
  items+=("$(_teams_fact 'Job' "${_BGB_EV_JOB}")")
  items+=("$(_teams_fact 'Phase' "${_BGB_EV_PHASE}")")
  items+=("$(_teams_fact 'Exit code' "${_BGB_EV_RC}")")
  items+=("$(_teams_fact 'Duration' "${_BGB_EV_DURATION_HUMAN}")")
  items+=("$(_teams_fact 'Snapshot' "${_BGB_EV_SNAPSHOT}")")
  items+=("$(_teams_fact 'Bytes added' "$(human_bytes "${_BGB_EV_BYTES_ADDED:-0}")")")
  items+=("$(_teams_fact 'Repository' "${_BGB_EV_REPO}")")
  if [ "${_BGB_EV_FILES_UNREADABLE:-0}" != "0" ]; then
    items+=("$(_teams_fact 'Unreadable files' "${_BGB_EV_FILES_UNREADABLE}")")
  fi
  if [ "${_BGB_EV_DB_DUMPS_FAILED:-0}" != "0" ]; then
    items+=("$(_teams_fact 'Failed DB dumps' "${_BGB_EV_DB_DUMPS_FAILED}")")
  fi
  if [ "${_BGB_EV_QUIESCE:-0}" != "0" ]; then
    items+=("$(_teams_fact 'Quiesce' "${_BGB_EV_QUIESCE}s")")
  fi
  items+=("$(_teams_fact 'Run id' "${_BGB_EV_RUN_ID}")")
  items+=("$(_teams_fact 'bg-backup' "${BGB_VERSION:-}")")

  for f in "${items[@]:-}"; do
    [ -n "${f}" ] || continue
    if [ -n "${out}" ]; then out="${out},${f}"; else out="${f}"; fi
  done
  printf '%s' "${out}"
}

# _teams_card <target-file> - build the request body.
# Assembled with the json_* helpers, not jq: the notifier must not acquire a
# dependency that a rescue system might be missing.
_teams_card() {
  local target="${1:-}" colour title facts
  colour="$(_teams_colour "${_BGB_EV_SEVERITY}")"
  title="$(_teams_title) - ${_BGB_EV_JOB:-repository} on ${_BGB_EV_HOST}"
  facts="$(_teams_facts)"

  {
    printf '{'
    json_kv type message; printf ','
    printf '"attachments":[{'
    json_kv contentType 'application/vnd.microsoft.card.adaptive'; printf ','
    json_kvraw contentUrl null; printf ','
    printf '"content":{'
    # Single-quoted so the shell does not try to expand $schema.
    json_kv '$schema' 'http://adaptivecards.io/schemas/adaptive-card.json'; printf ','
    json_kv type AdaptiveCard; printf ','
    json_kv version '1.5'; printf ','
    printf '"msteams":{%s},' "$(json_kv width Full)"
    printf '"body":['
    printf '{%s,%s,%s,%s,%s,%s},' \
      "$(json_kv type TextBlock)" \
      "$(json_kv size Large)" \
      "$(json_kv weight Bolder)" \
      "$(json_kv color "${colour}")" \
      "$(json_kvraw wrap true)" \
      "$(json_kv text "${title}")"
    printf '{%s,%s,%s},' \
      "$(json_kv type TextBlock)" \
      "$(json_kvraw wrap true)" \
      "$(json_kv text "${_BGB_EV_MSG}")"
    if [ -n "${_BGB_EV_DEGRADED_REASON}" ]; then
      printf '{%s,%s,%s,%s},' \
        "$(json_kv type TextBlock)" \
        "$(json_kvraw wrap true)" \
        "$(json_kvraw isSubtle true)" \
        "$(json_kv text "${_BGB_EV_DEGRADED_REASON}")"
    fi
    printf '{%s,"facts":[%s]}' "$(json_kv type FactSet)" "${facts}"
    printf ',{%s,%s,%s,%s}' \
      "$(json_kv type TextBlock)" \
      "$(json_kvraw wrap true)" \
      "$(json_kvraw isSubtle true)" \
      "$(json_kv text "Investigate: bg-backup status --job ${_BGB_EV_JOB} | journalctl -u bg-backup@${_BGB_EV_JOB}.service -n 200")"
    printf ']'
    printf '}'
    printf '}]'
    printf '}'
  } >"${target}"
}

# bgb_notify_teams <event> <job> <rc> <payload-json> <log-excerpt-file>
bgb_notify_teams() {
  local event="${1:-}" conf body

  [ -n "${BGB_MONITOR_TEAMS_WEBHOOK_URL:-}" ] || return 0

  # `start` never produces a card. Everything else that reaches this function
  # has already passed monitor_should_notify(), so with the default
  # BGB_MONITOR_ON=failure only failures and signalling partials arrive; with
  # BGB_MONITOR_ON=always the operator has explicitly asked for green cards too.
  [ "${event}" = "start" ] && return 0

  body="$(tmp_file "teams.XXXXXX" 2>/dev/null || true)"
  [ -n "${body}" ] || return 1
  chmod 0600 "${body}" 2>/dev/null || true
  _teams_card "${body}"

  conf="$(monitor_curl_conf_new)"
  [ -n "${conf}" ] || return 1

  monitor_curl_conf_add "${conf}" url "${BGB_MONITOR_TEAMS_WEBHOOK_URL}"
  printf 'request = "POST"\n' >>"${conf}"
  monitor_curl_conf_add "${conf}" header "Content-Type: application/json; charset=utf-8"
  # --data-binary, not --data: --data strips newlines, and while our document
  # has none today, a future field that does would be silently corrupted.
  monitor_curl_conf_add "${conf}" data-binary "@${body}"

  monitor_curl_run "${conf}" >/dev/null || return 1
  return 0
}
