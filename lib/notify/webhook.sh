#!/usr/bin/env bash
# =============================================================================
# bg-backup - notifier: generic JSON webhook
# =============================================================================
# POSTs the run payload verbatim to BGB_MONITOR_WEBHOOK_URL. This is the escape
# hatch for everything the built-in providers do not cover: ntfy, Gotify, Slack
# via a translating proxy, an internal event bus, a Node-RED flow, an n8n
# workflow, or a two-line receiver somebody writes in an afternoon.
#
# The document is the same one every other provider sees (monitor_payload), with
# a stable `schema` field so a receiver can version-gate. It has already been
# through redact(): a webhook endpoint is by definition outside this host's
# trust boundary, and it is the last place a repository passphrase should turn
# up in a log.
#
# BGB_MONITOR_WEBHOOK_URL is treated as a credential, because URLs of this shape
# usually are (an ntfy topic, a Slack workflow URL, a signed function URL). It
# goes into a 0600 curl config, never into argv.
#
# An optional shared secret can be set as BGB_MONITOR_WEBHOOK_TOKEN. It is sent
# as `Authorization: Bearer <token>`; the receiver should compare it in constant
# time and reject the request otherwise. We do not sign the body: an HMAC that
# nobody verifies is decoration, and the receivers this hatch exists for do not
# verify one.
# =============================================================================

[ -n "${_BGB_NOTIFY_WEBHOOK_SOURCED:-}" ] && return 0
_BGB_NOTIFY_WEBHOOK_SOURCED=1

# bgb_notify_webhook <event> <job> <rc> <payload-json> <log-excerpt-file>
bgb_notify_webhook() {
  local event="${1:-}" job="${2:-}" payload="${4:-}"
  local conf body

  [ -n "${BGB_MONITOR_WEBHOOK_URL:-}" ] || return 0
  [ -n "${payload}" ] || return 0

  # The body goes through a file rather than through `data = "..."` in the curl
  # config. Two reasons: the payload contains double quotes and backslashes that
  # would have to survive two layers of escaping, and a large body in a config
  # file is one more copy of the data to get the permissions wrong on. A single
  # 0600 file in the private temp tree is easier to reason about.
  body="$(tmp_file "webhook.XXXXXX" 2>/dev/null || true)"
  [ -n "${body}" ] || return 1
  chmod 0600 "${body}" 2>/dev/null || true
  printf '%s' "${payload}" >"${body}"

  conf="$(monitor_curl_conf_new)"
  [ -n "${conf}" ] || return 1

  monitor_curl_conf_add "${conf}" url "${BGB_MONITOR_WEBHOOK_URL}"
  printf 'request = "POST"\n' >>"${conf}"
  monitor_curl_conf_add "${conf}" header "Content-Type: application/json; charset=utf-8"

  # Routing headers, so a receiver can filter without parsing the body. They
  # carry no secret: an event name, a job name and a host name.
  monitor_curl_conf_add "${conf}" header "X-BG-Backup-Event: ${event}"
  monitor_curl_conf_add "${conf}" header "X-BG-Backup-Job: ${job}"
  monitor_curl_conf_add "${conf}" header "X-BG-Backup-Host: ${_BGB_EV_HOST}"
  monitor_curl_conf_add "${conf}" header "X-BG-Backup-Severity: ${_BGB_EV_SEVERITY}"

  if [ -n "${BGB_MONITOR_WEBHOOK_TOKEN:-}" ]; then
    monitor_curl_conf_add "${conf}" header "Authorization: Bearer ${BGB_MONITOR_WEBHOOK_TOKEN}"
  fi

  monitor_curl_conf_add "${conf}" data-binary "@${body}"

  monitor_curl_run "${conf}" >/dev/null || return 1
  return 0
}
