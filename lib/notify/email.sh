#!/usr/bin/env bash
# =============================================================================
# bg-backup - notifier: e-mail through the local MTA
# =============================================================================
# FAILURES ONLY, and that is a design decision rather than a default.
#
# A daily "backup succeeded" mail becomes an Outlook rule within a week and an
# unread folder within a month. By the time something breaks, the one message
# that mattered is filed next to three hundred that did not, and nobody opens
# the folder any more. Success belongs in Prometheus and in the Kuma heartbeat,
# where a machine does the reading. Mail is for the exception.
#
# The body has one job: let an operator who has just been woken up decide
# whether to get out of bed, without logging in first. That means the summary,
# the last hundred log lines, and the exact commands to run next - not a link to
# a dashboard behind a VPN.
#
# No MTA configuration lives here. We hand the message to whatever the host
# already has (msmtp on BAUER GROUP servers) and let it deal with relays,
# credentials and TLS. A backup tool with its own SMTP client is a backup tool
# with its own SMTP credentials to leak.
# =============================================================================

[ -n "${_BGB_NOTIFY_EMAIL_SOURCED:-}" ] && return 0
_BGB_NOTIFY_EMAIL_SOURCED=1

# _email_recipients - normalise "a@b c@d" and "a@b, c@d" into a header list.
_email_recipients() {
  local raw="${BGB_MONITOR_MAIL_TO:-}" out="" a
  local -a list=()
  raw="${raw//,/ }"
  read -r -a list <<<"${raw}" || true
  for a in "${list[@]:-}"; do
    [ -n "${a}" ] || continue
    if [ -n "${out}" ]; then out="${out}, ${a}"; else out="${a}"; fi
  done
  printf '%s' "${out}"
}

# _email_explain_rc <code> - bg-backup's exit codes in words.
# Worth the twelve lines: the difference between "exit 5" (a lock, harmless,
# go back to sleep) and "exit 6" (the repository is unreachable, get up) is the
# whole point of the message, and nobody remembers the table at 3am.
_email_explain_rc() {
  case "${1:-}" in
    0) printf 'success' ;;
    1) printf 'generic fatal error' ;;
    2) printf 'usage error' ;;
    3) printf 'partial - a snapshot exists, some sources were unreadable' ;;
    4) printf 'precondition failed - not root, missing dependency or invalid config' ;;
    5) printf 'another bg-backup run holds the lock' ;;
    6) printf 'repository unreachable, uninitialised or wrong key' ;;
    7) printf 'check or verify found damage' ;;
    8) printf 'a pre/post hook failed' ;;
    9) printf 'a safety rail refused a destructive operation' ;;
    130) printf 'interrupted' ;;
    *) printf 'unknown exit code' ;;
  esac
}

# _email_should_send <event>
_email_should_send() {
  case "${1:-}" in
    failure | degraded | check_failed | verify_failed) return 0 ;;
    partial)
      # Only when the job declared that unreadable files are a real signal. On a
      # live filesystem exit 3 is routine, and mailing it is how this channel
      # gets muted.
      [ "${JOB_PARTIAL_IS_FAILURE:-0}" = "1" ]
      ;;
    *) return 1 ;;
  esac
}

# _email_body <excerpt-file> - writes the message body to stdout.
_email_body() {
  local excerpt="${1:-}" job="${_BGB_EV_JOB}" unit

  unit="bg-backup@${job}.service"
  [ -n "${job}" ] || unit="bg-backup.service"

  printf 'bg-backup failure report\n'
  printf '========================\n\n'

  printf '  host          %s\n' "${_BGB_EV_HOST}"
  printf '  job           %s\n' "${job:-<none>}"
  printf '  event         %s\n' "${_BGB_EV_EVENT}"
  printf '  phase         %s\n' "${_BGB_EV_PHASE:-<unknown>}"
  printf '  exit code     %s (%s)\n' "${_BGB_EV_RC}" "$(_email_explain_rc "${_BGB_EV_RC}")"
  printf '  run id        %s\n' "${_BGB_EV_RUN_ID:-<none>}"
  printf '  started       %s\n' "${_BGB_EV_STARTED:-<unknown>}"
  printf '  ended         %s\n' "${_BGB_EV_ENDED:-<unknown>}"
  printf '  duration      %s\n' "${_BGB_EV_DURATION_HUMAN}"
  printf '  snapshot      %s\n' "${_BGB_EV_SNAPSHOT:-<none created>}"
  printf '  repository    %s\n' "${_BGB_EV_REPO:-<unknown>}"
  printf '  quiesce       %ss\n' "${_BGB_EV_QUIESCE:-0}"
  printf '  unreadable    %s file(s)\n' "${_BGB_EV_FILES_UNREADABLE:-0}"
  printf '  db dumps      %s ok, %s failed\n' \
    "${_BGB_EV_DB_DUMPS:-0}" "${_BGB_EV_DB_DUMPS_FAILED:-0}"
  printf '  bg-backup     %s\n' "${BGB_VERSION:-unknown}"
  printf '\n'

  printf 'Summary\n'
  printf -- '-------\n'
  printf '%s\n' "${_BGB_EV_MSG}"
  if [ -n "${_BGB_EV_DEGRADED_REASON}" ]; then
    printf '\n%s\n' "${_BGB_EV_DEGRADED_REASON}"
  fi
  printf '\n'

  printf 'Last %s log lines (redacted)\n' "${BGB_MONITOR_LOG_LINES:-100}"
  printf -- '---------------------------\n'
  if [ -n "${excerpt}" ] && [ -s "${excerpt}" ]; then
    cat "${excerpt}"
  else
    printf '(no log excerpt available)\n'
  fi
  printf '\n'

  printf 'Investigate\n'
  printf -- '-----------\n'
  printf '  ssh root@%s\n\n' "${_BGB_EV_HOST}"
  printf '  bg-backup status --job %s\n' "${job:-<job>}"
  printf '  bg-backup logs --job %s --lines 200\n' "${job:-<job>}"
  printf '  journalctl -u %s -n 200 --no-pager\n' "${unit}"
  printf '  bg-backup doctor\n'
  printf '  bg-backup snapshots --job %s\n' "${job:-<job>}"
  printf '\n'
  printf '  # once the cause is understood, re-run just this job:\n'
  printf '  bg-backup backup %s\n' "${job:-<job>}"
  printf '\n'

  printf -- '--\n'
  printf 'Sent by bg-backup %s on %s. This channel reports failures only;\n' \
    "${BGB_VERSION:-}" "${_BGB_EV_HOST}"
  printf 'successful runs are recorded in Prometheus and in the Uptime Kuma heartbeat.\n'
  printf 'Credentials are masked before the log excerpt is attached.\n'
}

# bgb_notify_email <event> <job> <rc> <payload-json> <log-excerpt-file>
bgb_notify_email() {
  local event="${1:-}" job="${2:-}" rc="${3:-0}" excerpt="${5:-}"
  local to subject body sendmail_bin

  [ -n "${BGB_MONITOR_MAIL_TO:-}" ] || return 0
  _email_should_send "${event}" || return 0

  to="$(_email_recipients)"
  [ -n "${to}" ] || return 0

  subject="[bg-backup] FAILURE ${job:-repository} on ${_BGB_EV_HOST} (exit ${rc})"

  body="$(tmp_file "mail.XXXXXX" 2>/dev/null || true)"
  [ -n "${body}" ] || return 1
  chmod 0600 "${body}" 2>/dev/null || true

  # sendmail(8) first, because -t reads the recipients from the headers we
  # write. That gives exact control over From:, Content-Type and the custom
  # X- headers a mail rule can filter on, none of which mailx exposes portably.
  # On a host running msmtp, /usr/sbin/sendmail is msmtp's own compatibility
  # link, so this branch is the msmtp branch too.
  sendmail_bin=""
  if [ -x /usr/sbin/sendmail ]; then
    sendmail_bin=/usr/sbin/sendmail
  elif have sendmail; then
    sendmail_bin="$(command -v sendmail)"
  fi

  if [ -n "${sendmail_bin}" ]; then
    {
      printf 'To: %s\n' "${to}"
      [ -n "${BGB_MONITOR_MAIL_FROM:-}" ] && printf 'From: %s\n' "${BGB_MONITOR_MAIL_FROM}"
      printf 'Subject: %s\n' "${subject}"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf 'X-BG-Backup-Host: %s\n' "${_BGB_EV_HOST}"
      printf 'X-BG-Backup-Job: %s\n' "${job}"
      printf 'X-BG-Backup-Event: %s\n' "${event}"
      # Auto-Submitted keeps a well-behaved recipient from bouncing or
      # auto-replying to us, which would otherwise loop straight back into the
      # MTA of a host that is already having a bad night.
      printf 'Auto-Submitted: auto-generated\n'
      printf '\n'
      _email_body "${excerpt}"
    } >"${body}"
    "${sendmail_bin}" -t <"${body}" || return 1
    return 0
  fi

  if have msmtp; then
    {
      printf 'To: %s\n' "${to}"
      [ -n "${BGB_MONITOR_MAIL_FROM:-}" ] && printf 'From: %s\n' "${BGB_MONITOR_MAIL_FROM}"
      printf 'Subject: %s\n' "${subject}"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf 'Auto-Submitted: auto-generated\n'
      printf '\n'
      _email_body "${excerpt}"
    } >"${body}"
    msmtp --read-recipients <"${body}" || return 1
    return 0
  fi

  if have mail; then
    _email_body "${excerpt}" >"${body}"
    if [ -n "${BGB_MONITOR_MAIL_FROM:-}" ]; then
      # -r is bsd-mailx; GNU mailutils wants -a "From: ...". Try the first and
      # fall back rather than probing, because the two are indistinguishable by
      # name and both are called /usr/bin/mail.
      mail -s "${subject}" -r "${BGB_MONITOR_MAIL_FROM}" "${to}" <"${body}" && return 0
      mail -s "${subject}" -a "From: ${BGB_MONITOR_MAIL_FROM}" "${to}" <"${body}" && return 0
      return 1
    fi
    mail -s "${subject}" "${to}" <"${body}" || return 1
    return 0
  fi

  printf 'no MTA found (looked for sendmail, msmtp, mail) - install msmtp-mta\n' >&2
  return 1
}
