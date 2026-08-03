#!/usr/bin/env bash
# =============================================================================
# bg-backup - internal: the entry points systemd calls, not humans
# =============================================================================
# Two commands live here, and both share one hard requirement: THEY MUST WORK
# WHEN THE MAIN PROCESS IS ALREADY DEAD.
#
#   internal unquiesce      ExecStopPost=. Runs after ExecStart has ended, for
#                           any reason at all - clean exit, non-zero exit,
#                           SIGKILL from the OOM killer or RuntimeMaxSec, a
#                           shutdown that took the cgroup with it. When the
#                           process is killed outright, no EXIT trap runs, so
#                           containers stay paused or stopped and a service is
#                           down until somebody notices. This replays the
#                           quiesce journal that lib/quiesce.sh left in /run and
#                           puts the host back.
#
#   internal notify-failure OnFailure=. The in-process notifier cannot fire when
#                           the process was killed - and a job the OOM killer
#                           takes every night looks exactly like a job that
#                           never ran. systemd is the only party left holding
#                           the facts, so this reads them back out of systemd
#                           and the journal.
#
# Consequences of "the main process is dead" that shape every line below:
#
#   * NOTHING here may depend on state the dead process held in memory.
#   * unquiesce must not need the repository, the network, or even a valid
#     configuration. A broken bg-backup.conf must never be the reason Docker
#     stays stopped.
#   * notify-failure must never exit non-zero. A failing OnFailure= unit is a
#     failure nobody is watching for.
# =============================================================================

[ -n "${_BGB_INTERNAL_SOURCED:-}" ] && return 0
_BGB_INTERNAL_SOURCED=1

# /run is tmpfs: the quiesce journal cannot survive a reboot, which is correct.
# After a reboot nothing is paused and no container is stopped by us, so there
# is nothing to replay - and a stale journal from before the reboot would try to
# "restore" state that the boot already restored.
: "${BGB_RUN_DIR:=/run/bg-backup}"

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
cmd_internal() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "${sub}" in
    unquiesce) internal_unquiesce "$@" ;;
    notify-failure) internal_notify_failure "$@" ;;
    '' | help | --help | -h)
      internal_usage
      exit "${EX_USAGE}"
      ;;
    *)
      err "Unknown internal subcommand: ${sub}"
      internal_usage
      exit "${EX_USAGE}"
      ;;
  esac
}

internal_usage() {
  cat <<'EOF'
bg-backup internal - entry points for systemd, not for humans

  bg-backup internal unquiesce --job JOB [--if-needed]
      Replay /run/bg-backup/quiesce-JOB.state and undo whatever the job did to
      the host: unpause containers, start containers and units, thaw and unmount
      snapshots, remove the snapshot volume. Used as ExecStopPost=, where it is
      the only thing that still runs after a SIGKILL.

      --if-needed  Exit 0 silently when there is no journal to replay (the
                   normal case: the EXIT trap already did the work).

  bg-backup internal notify-failure --unit UNIT [--force]
      Read the failure out of systemd and the journal, redact it, and dispatch
      it through the notifier chain. UNIT may be a job name ("system"), a
      template instance ("bg-backup@system.service") or a maintenance unit
      ("bg-backup-check"). Used as OnFailure=.

      --force      Notify even when the tool exited through its own exit path
                   and has therefore already notified.
EOF
}

# -----------------------------------------------------------------------------
# Unit / job name handling
# -----------------------------------------------------------------------------
# The failure unit is instantiated two ways:
#   bg-backup@%i.service  -> %i is a JOB NAME            ("system")
#   maintenance %N        -> %N is a UNIT NAME           ("bg-backup-check")
# so this accepts both plus a fully-qualified unit name, and never guesses.
internal_normalise_unit() {
  local u="$1"
  case "${u}" in
    '') printf '' ;;
    *.service | *.timer) printf '%s' "${u}" ;;
    bg-backup@* | bg-backup-*) printf '%s.service' "${u}" ;;
    *) printf 'bg-backup@%s.service' "${u}" ;;
  esac
}

# "bg-backup@system.service" -> "system";  maintenance units have no job.
internal_job_from_unit() {
  local u="$1" rest
  case "${u}" in
    bg-backup@*)
      rest="${u#bg-backup@}"
      printf '%s' "${rest%.service}"
      ;;
    *) printf '' ;;
  esac
}

# "bg-backup@system.service" -> "backup";  "bg-backup-check.service" -> "check".
internal_command_from_unit() {
  local u="$1" rest
  case "${u}" in
    bg-backup@*) printf 'backup' ;;
    bg-backup-*)
      rest="${u#bg-backup-}"
      rest="${rest%.service}"
      printf '%s' "${rest%.timer}"
      ;;
    *) printf 'unknown' ;;
  esac
}

# -----------------------------------------------------------------------------
# unquiesce
# -----------------------------------------------------------------------------
# The journal is written by lib/quiesce.sh BEFORE the corresponding action is
# taken, so a process killed between the write and the action still leaves a
# record to replay. Replaying an action that never happened is a no-op here;
# failing to replay one that did is an outage.
#
# Format, one key=value per line, exactly as quiesce.sh writes it:
#
#     mode=docker-pause|service-stop|lvm|btrfs|zfs
#     job=<name>
#     started=<epoch>
#     ids=<container id> ...        (docker-pause)
#     units=<unit> ...              (service-stop)
#     snapshot=<dev>                (lvm/btrfs/zfs)
#     mountpoint=<path>             (lvm/btrfs/zfs)
#
# THIS COMMENT USED TO DESCRIBE A TAB-SEPARATED VERB FORMAT, and so did the
# parser below it - a format quiesce.sh has never written. `internal unquiesce`
# therefore understood no record, reported failure, and left the containers
# paused after the SIGKILL it exists to clean up after. Both the parser and this
# description are now gone: quiesce_reverse_file() in lib/quiesce.sh is the
# single reader, shared with the normal end-of-run path, so the two cannot
# disagree about the file again.
internal_quiesce_state_file() {
  local job="$1"
  if declare -F quiesce_state_file >/dev/null 2>&1; then
    quiesce_state_file "${job}"
    return 0
  fi
  printf '%s/quiesce-%s.state' "${BGB_RUN_DIR}" "${job}"
}

internal_unquiesce() {
  local job="" if_needed=0 f rc=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --job)
        [ $# -ge 2 ] || die "${EX_USAGE}" "--job requires an argument"
        job="$2"
        shift 2
        ;;
      --job=*)
        job="${1#*=}"
        shift
        ;;
      --if-needed)
        if_needed=1
        shift
        ;;
      '') shift ;;
      *) die "${EX_USAGE}" "internal unquiesce: unexpected argument '$1'" ;;
    esac
  done

  [ -n "${job}" ] || die "${EX_USAGE}" "internal unquiesce requires --job <name>"

  # Deliberately NO config_load here. This path must work with a broken or
  # half-written /etc/bg-backup: a configuration typo must never be the reason
  # a production stack stays stopped.
  BGB_JOB="${job}"
  log_open "${BGB_LOG_DIR}/jobs/${job}.log" 2>/dev/null || true

  f="$(internal_quiesce_state_file "${job}")"

  if [ ! -s "${f}" ]; then
    if [ "${if_needed}" = "1" ]; then
      debug "No quiesce journal at ${f} - nothing to undo"
      return 0
    fi
    warn "No quiesce journal at ${f} - nothing to undo"
    return 0
  fi

  log "Replaying quiesce journal ${f} (the job's own cleanup did not run)"

  # THE SAME reverser the normal end-of-run path uses. This used to dispatch to
  # internal_replay_records(), a second parser for a TAB-separated verb/argument
  # format that quiesce.sh has never written - so after a SIGKILL the journal
  # was read, understood by nobody, and the containers stayed paused. A safety
  # net with its own idea of the file format is not a safety net.
  #
  # quiesce.sh is sourced here rather than by the dispatcher because this path
  # must keep working with a broken /etc/bg-backup, and lib_source needs no
  # configuration.
  lib_source quiesce.sh
  quiesce_reverse_file "${f}" || rc=$?

  if [ "${rc}" -eq 0 ]; then
    rm -f "${f}"
    log "Quiesce undone for job '${job}'"
    return 0
  fi

  # The journal is KEPT on failure. It is the only record of what is still
  # wrong, the next run replays it before doing anything else, and an operator
  # can read it. Deleting it here would erase the evidence and the recovery
  # path in one go.
  err "Could not fully undo the quiesce for job '${job}' - journal kept at ${f}"
  err "Check by hand: docker ps -a, systemctl status, mount, lvs"
  return "${EX_FAIL}"
}

# NOTE ON WHAT USED TO BE HERE. internal_replay_records() and its
# _internal_docker_unpause / _internal_docker_start / _internal_systemd_start /
# _internal_fsfreeze_thaw / _internal_umount / _internal_lvremove helpers lived
# at this point and parsed a TAB-separated verb/argument journal. quiesce.sh has
# never written that format - it writes key=value - so the ExecStopPost safety
# net recognised nothing, reported failure, and left containers paused after a
# SIGKILL. They are deleted rather than fixed: a second implementation of a file
# format is how the two drift apart again. `internal unquiesce` now calls
# quiesce_reverse_file(), the same function the normal end-of-run path uses.

# -----------------------------------------------------------------------------
# notify-failure
# -----------------------------------------------------------------------------
internal_notify_failure() {
  local unit_arg="" force=0 unit job command result main_status main_code
  local invocation ended body subject

  while [ $# -gt 0 ]; do
    case "$1" in
      --unit)
        [ $# -ge 2 ] || die "${EX_USAGE}" "--unit requires an argument"
        unit_arg="$2"
        shift 2
        ;;
      --unit=*)
        unit_arg="${1#*=}"
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      '') shift ;;
      *)
        warn "internal notify-failure: ignoring unexpected argument '$1'"
        shift
        ;;
    esac
  done

  # Every return path below is exit 0. A failing OnFailure= unit is a failure
  # with nobody left to report it, and it also marks a second unit failed in
  # `systemctl --failed`, burying the original.
  if [ -z "${unit_arg}" ]; then
    err "internal notify-failure requires --unit"
    return 0
  fi

  unit="$(internal_normalise_unit "${unit_arg}")"
  job="$(internal_job_from_unit "${unit}")"
  command="$(internal_command_from_unit "${unit}")"
  BGB_JOB="${job}"

  # Load the configuration for BGB_MONITOR_*, but survive a broken one: the
  # backup may well have failed BECAUSE the configuration is broken, and that is
  # the single most important failure to be told about.
  if (config_load) >/dev/null 2>&1; then
    config_load
  else
    warn "Main configuration does not load - notifying with built-in defaults"
    config_defaults
    [ -n "${BGB_HOSTNAME}" ] || BGB_HOSTNAME="$(fqdn)"
  fi

  # REDACTION FIRST, before a single journal line is read.
  #
  # This process never loaded the repository environment, so redact()'s literal
  # layer starts empty - a journal excerpt containing an S3 secret would go out
  # verbatim. redact_register_file() registers the values from a credentials
  # file WITHOUT sourcing it, which is exactly what is needed here: we want the
  # strings masked, not the file executed in a notifier's context.
  redact_register_file "${BGB_REPO_ENV}" 2>/dev/null || true
  if [ -r "${BGB_CONFDIR}/credentials/repo.key" ]; then
    redact_register "$(cat "${BGB_CONFDIR}/credentials/repo.key" 2>/dev/null || true)"
  fi
  if [ -r "${BGB_CONFDIR}/credentials/notify.env" ]; then
    redact_register_file "${BGB_CONFDIR}/credentials/notify.env"
  fi
  redact_register_env

  # --- what systemd knows -----------------------------------------------------
  result=""
  main_status=""
  main_code=""
  invocation=""
  ended=""
  if have systemctl; then
    local k v
    while IFS='=' read -r k v; do
      case "${k}" in
        Result) result="${v}" ;;
        ExecMainStatus) main_status="${v}" ;;
        ExecMainCode) main_code="${v}" ;;
        InvocationID) invocation="${v}" ;;
        InactiveEnterTimestamp) ended="${v}" ;;
      esac
    done < <(systemctl show "${unit}" \
      -p Result -p ExecMainStatus -p ExecMainCode \
      -p InvocationID -p InactiveEnterTimestamp 2>/dev/null || true)
  fi
  [ -n "${result}" ] || result="unknown"
  [ -n "${main_status}" ] || main_status="?"

  # --- duplicate suppression --------------------------------------------------
  if [ "${force}" != "1" ] && _internal_tool_already_notified "${result}" "${main_status}"; then
    log "${unit} exited ${main_status} through its own exit path - the in-process notifier already ran"
    _internal_record_event "${job}" "${command}" "${main_status}" "${unit}"
    return 0
  fi

  # --- build the report -------------------------------------------------------
  subject="bg-backup ${command}${job:+ ${job}} FAILED on ${BGB_HOSTNAME}"
  body="$(tmp_file "failure.XXXXXX")"

  {
    printf 'host            %s\n' "${BGB_HOSTNAME}"
    printf 'unit            %s\n' "${unit}"
    printf 'command         %s\n' "${command}"
    [ -n "${job}" ] && printf 'job             %s\n' "${job}"
    printf 'systemd result  %s\n' "${result}"
    printf 'exit status     %s (%s)\n' "${main_status}" "${main_code:-?}"
    printf 'ended           %s\n' "${ended:-unknown}"
    printf 'detected by     systemd OnFailure= (out of process)\n'
    printf 'tool version    %s\n' "${BGB_VERSION}"
    printf '\n'
    printf '%s\n' "$(_internal_explain_result "${result}" "${main_status}")"
    printf '\n--- last 100 journal lines -------------------------------------------\n'
  } >"${body}"

  if have journalctl; then
    # Prefer the invocation ID: it selects exactly this run's log lines, with no
    # chance of attaching last night's successful output to tonight's failure.
    if [ -n "${invocation}" ]; then
      journalctl "_SYSTEMD_INVOCATION_ID=${invocation}" -n 100 --no-pager -o short-iso 2>/dev/null \
        | redact_stream >>"${body}" || true
    else
      journalctl -u "${unit}" -n 100 --no-pager -o short-iso 2>/dev/null \
        | redact_stream >>"${body}" || true
    fi
  else
    printf '(journalctl unavailable)\n' >>"${body}"
  fi

  err "${subject}"
  _internal_record_event "${job}" "${command}" "${main_status}" "${unit}"
  _internal_dispatch_notification "${job}" "${command}" "${main_status}" "${subject}" "${body}"
  return 0
}

# _internal_tool_already_notified <result> <exit-status>
#
# bg-backup's own exit codes are 1..9 (see core.sh). Seeing one of them with
# Result=exit-code means the process reached its own exit path, where
# BGB_MONITOR_ON already decided whether to notify - sending a second alert here
# would double every ordinary failure and train people to filter both away.
#
# Everything else means the process did NOT get to decide:
#   Result=signal / timeout / oom-kill / core-dump / start-limit-hit
#   exit 127/126 (binary missing or not executable)
#   exit 130     (killed by SIGINT; the trap unquiesced but never notified)
#   exit 137/143 (SIGKILL/SIGTERM surfaced as an exit status)
_internal_tool_already_notified() {
  local result="$1" status="$2"
  [ "${result}" = "exit-code" ] || return 1
  case "${status}" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9) return 0 ;;
    *) return 1 ;;
  esac
}

_internal_explain_result() {
  local result="$1" status="$2"
  case "${result}" in
    oom-kill)
      printf 'The kernel OOM killer terminated this run. No cleanup code of ours ran;\n'
      printf 'ExecStopPost= has undone the quiesce. Reduce concurrency or add memory.'
      ;;
    timeout)
      printf 'RuntimeMaxSec (JOB_TIMEOUT) expired and systemd killed the run.\n'
      printf 'Either the job genuinely needs longer or it is stuck on the backend.'
      ;;
    signal)
      printf 'The process was killed by a signal (shutdown, manual kill, or the\n'
      printf 'watchdog). No in-process notification could be sent, which is why\n'
      printf 'this message exists.'
      ;;
    core-dump)
      printf 'The process dumped core. Treat this as a tool bug and report it with\n'
      printf 'the journal excerpt below.'
      ;;
    start-limit-hit)
      printf 'systemd refused to start the unit again after repeated failures.'
      ;;
    exit-code)
      case "${status}" in
        126 | 127)
          printf 'The bg-backup binary could not be executed (exit %s). A broken install\n' "${status}"
          printf 'or a half-finished self-update - check /opt/bg-backup/current.'
          ;;
        130)
          printf 'Interrupted (SIGINT). Cleanup ran, but no notification was sent from\n'
          printf 'inside the process.'
          ;;
        *) printf 'The process exited %s without reaching its own reporting path.' "${status}" ;;
      esac
      ;;
    *)
      printf 'systemd reported result "%s" with exit status %s.' "${result}" "${status}"
      ;;
  esac
}

# Append-only, so it can never destroy a better record. The state DOCUMENT is
# deliberately not rewritten here: the dying process may have managed to write
# an accurate one, and overwriting it with this thin outside view would replace
# real numbers (bytes, snapshot id, unreadable files) with nothing.
_internal_record_event() {
  local job="$1" command="$2" status="$3" unit="$4"
  declare -F state_event >/dev/null 2>&1 || return 0
  BGB_COMMAND="${command}"
  state_event "${job:-${unit}}" failed "${status}" "onfailure" "" || true
  return 0
}

# The notifier chain lives in lib/monitor.sh. It is called through a guard
# because this unit has to keep working even if monitor.sh is unavailable or
# changes shape: an alert that reaches the journal and the event log is still
# an alert, and a hard dependency here would mean a broken notifier silences
# the failure it was supposed to report.
_internal_dispatch_notification() {
  local job="$1" command="$2" status="$3" subject="$4" body="$5"

  # Also exported, so a notifier implementation that reads its input from the
  # environment rather than argv sees the same facts.
  export BGB_NOTIFY_SOURCE="systemd-onfailure"
  export BGB_NOTIFY_SUBJECT="${subject}"
  export BGB_NOTIFY_BODY_FILE="${body}"
  export BGB_NOTIFY_STATUS="failed"
  export BGB_NOTIFY_RC="${status}"
  export BGB_NOTIFY_COMMAND="${command}"

  if declare -F monitor_notify >/dev/null 2>&1; then
    monitor_notify failed "${job}" "${status}" "${subject}" "${body}" \
      || warn "The notifier chain reported an error; the failure is recorded in the journal and the event log"
    return 0
  fi

  warn "No notifier available (lib/monitor.sh did not provide monitor_notify)"
  warn "Failure report follows on stderr so the journal keeps a copy:"
  redact_tail "${body}" 60000 >&2 || true
  return 0
}
