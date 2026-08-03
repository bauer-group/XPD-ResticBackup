#!/usr/bin/env bash
# =============================================================================
# bg-backup - quiesce: freeze just enough, and always thaw again
# =============================================================================
# Quiescing is the only thing this tool does that can leave a host WORSE than
# not running a backup at all: a paused container or a stopped Docker daemon
# that never comes back is an outage caused by the backup.
#
# Three independent mechanisms guarantee reversal, because the obvious one is
# not enough:
#
#   1. the EXIT/INT/TERM trap                 - covers normal errors and Ctrl-C
#   2. a state file under /run/bg-backup/     - replayed at the START of the
#                                               next run, covering SIGKILL, OOM,
#                                               RuntimeMaxSec and a reboot
#   3. ExecStopPost= in the systemd unit      - runs even when the main process
#                                               was killed and no trap ever fired
#
# resticprofile's run-after: provides only the first. A reboot in the middle of
# a backup would leave Docker stopped indefinitely.
#
# ORDERING NOTE: quiesce is always reversed BEFORE locks are released, so a
# waiting job cannot start while services are still down.
# =============================================================================

[ -n "${_BGB_QUIESCE_SOURCED:-}" ] && return 0
_BGB_QUIESCE_SOURCED=1

: "${BGB_RUNTIME_DIR:=/run/bg-backup}"

_BGB_QUIESCE_ACTIVE=0
_BGB_QUIESCE_START=0
_BGB_QUIESCE_REGISTERED=0

quiesce_state_file() {
  printf '%s/quiesce-%s.state' "${BGB_RUNTIME_DIR}" "${1:-${BGB_JOB}}"
}

# -----------------------------------------------------------------------------
# Recovery of an interrupted previous run
# -----------------------------------------------------------------------------
# Called before anything else in a backup. If a previous run died without
# thawing, we undo its work first - starting a new backup on top of a
# half-quiesced host would compound the problem.
quiesce_recover_stale() {
  local job="${1:-${BGB_JOB}}" f
  f="$(quiesce_state_file "${job}")"
  [ -f "${f}" ] || return 0
  warn "A previous run left job '${job}' quiesced - reversing that first"
  quiesce_end "${job}"
}

# -----------------------------------------------------------------------------
# Begin
# -----------------------------------------------------------------------------
# quiesce_begin <job> [container-id...]
#
# The trailing arguments are resolved container IDs, never `docker ps` flags.
# With none, docker-pause freezes every running container.
quiesce_begin() {
  local job="${1:-${BGB_JOB}}"
  shift || true
  local f
  f="$(quiesce_state_file "${job}")"

  [ "${JOB_QUIESCE}" = "none" ] && return 0

  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] would quiesce with mode ${JOB_QUIESCE}"
    return 0
  fi

  install -d -m 0700 "${BGB_RUNTIME_DIR}" 2>/dev/null || true

  if [ "${_BGB_QUIESCE_REGISTERED}" -eq 0 ]; then
    # Registered before the first state change, so an error inside this very
    # function is still reversed.
    on_cleanup quiesce_cleanup_handler
    _BGB_QUIESCE_REGISTERED=1
  fi

  _BGB_QUIESCE_START="$(now_epoch)"
  _BGB_QUIESCE_ACTIVE=1

  case "${JOB_QUIESCE}" in
    docker-pause) _quiesce_docker_pause "${job}" "${f}" "$@" ;;
    docker-stop) _quiesce_docker_stop "${job}" "${f}" ;;
    service-stop) _quiesce_service_stop "${job}" "${f}" ;;
    lvm | btrfs | zfs)
      lib_source snapshot_fs.sh
      snapshot_fs_begin "${job}" "${f}"
      ;;
    *)
      die "${EX_PRECOND}" "Unknown quiesce mode: ${JOB_QUIESCE}"
      ;;
  esac
}

# _quiesce_docker_pause <job> <state-file> [container-id...]
#
# CONTAINER IDS, not `docker ps` filter flags. The caller used to hand its
# filters straight through to `docker ps -q "$@"`, and that was wrong twice:
#
#   * Docker ANDs label filters (MatchKVList), so one
#     `--filter label=com.docker.compose.project=<p>` per project matched ZERO
#     containers as soon as there were two projects - no container carries two
#     values for one label key. Measured against Docker 29.6.2: each filter
#     alone matches its container, both together match nothing.
#   * An empty filter array expanded to one EMPTY argument, and `docker ps` is
#     cli.NoArgs, so it exited 125 with "accepts no arguments" - swallowed by
#     `2>/dev/null || true`. That is the JOB_QUIESCE_SCOPE=host path.
#
# Both produced an empty id list, which took the branch below and silently ran
# the whole file backup against LIVE containers while the job reported ok.
# Resolving ids in the caller, one `docker ps` per project, cannot fail that way.
#
# No ids at all means "every running container" - the whole-host quiesce that
# backup.sh asks for.
_quiesce_docker_pause() {
  local job="$1" f="$2"
  shift 2
  local -a ids=("$@")

  if [ "${#ids[@]}" -eq 0 ]; then
    mapfile -t ids < <(docker ps -q 2>/dev/null || true)
  fi

  if [ "${#ids[@]}" -eq 0 ]; then
    # warn, not debug. "Nothing was paused" is the difference between a
    # crash-consistent backup and a live one, and at debug level nobody ever
    # sees it - which is exactly how the two bugs above stayed invisible.
    warn "docker-pause: no running container matched - the file backup is NOT crash-consistent"
    _BGB_QUIESCE_ACTIVE=0
    return 0
  fi

  # Write the state file BEFORE pausing. If the process dies between the write
  # and the pause we perform a harmless unpause of a running container; if it
  # died between pause and write, the containers would stay paused forever.
  {
    printf 'mode=docker-pause\n'
    printf 'job=%s\n' "${job}"
    printf 'started=%s\n' "$(now_epoch)"
    printf 'ids=%s\n' "${ids[*]}"
  } >"${f}"
  chmod 0600 "${f}"

  log "Pausing ${#ids[@]} container(s) for a consistent read"
  docker pause "${ids[@]}" >/dev/null 2>&1 || {
    warn "docker pause failed - continuing without a quiesce window"
    _BGB_QUIESCE_ACTIVE=0
    rm -f "${f}"
    return 0
  }
}

_quiesce_docker_stop() {
  local job="$1" f="$2"
  {
    printf 'mode=service-stop\n'
    printf 'job=%s\n' "${job}"
    printf 'started=%s\n' "$(now_epoch)"
    printf 'units=docker.socket docker.service\n'
  } >"${f}"
  chmod 0600 "${f}"

  warn "Stopping the Docker daemon for the whole run (JOB_QUIESCE=docker-stop)"
  warn "Consider docker-pause or an LVM snapshot instead: this is a full outage"
  # docker.socket first, otherwise socket activation restarts the daemon the
  # moment anything touches /var/run/docker.sock - including our own inspect.
  systemctl stop docker.socket docker.service
}

_quiesce_service_stop() {
  local job="$1" f="$2"
  local -a stopped=()
  local u
  for u in "${JOB_QUIESCE_UNITS[@]:-}"; do
    [ -z "${u}" ] && continue
    if systemctl is-active --quiet "${u}" 2>/dev/null; then
      stopped+=("${u}")
    else
      debug "Unit not active, will not be restarted afterwards: ${u}"
    fi
  done

  if [ "${#stopped[@]}" -eq 0 ]; then
    debug "No configured unit was running"
    _BGB_QUIESCE_ACTIVE=0
    return 0
  fi

  {
    printf 'mode=service-stop\n'
    printf 'job=%s\n' "${job}"
    printf 'started=%s\n' "$(now_epoch)"
    printf 'units=%s\n' "${stopped[*]}"
  } >"${f}"
  chmod 0600 "${f}"

  log "Stopping unit(s): ${stopped[*]}"
  systemctl stop "${stopped[@]}"
}

# -----------------------------------------------------------------------------
# End
# -----------------------------------------------------------------------------
# quiesce_end [job] - idempotent, never fails the caller, safe to call twice.
# quiesce_reverse_file <state-file> - undo whatever the journal describes.
#
# THE ONE READER, and that is the point. `internal unquiesce` - the
# ExecStopPost safety net that runs after SIGKILL, OOM or RuntimeMaxSec - used
# to carry its OWN parser for a TAB-separated verb/argument format that nothing
# in this codebase has ever written. It therefore recognised no record, reported
# failure, and left the containers paused or the units stopped: the third and
# last reversal mechanism was dead in exactly the situation it exists for.
#
# Two parsers for one file is the defect. There is now one, and both callers -
# the normal end-of-run path and the post-mortem one - go through it.
quiesce_reverse_file() {
  local f="$1"
  [ -f "${f}" ] || return 0

  # Deliberately parsed rather than sourced: this file is read by a recovery
  # path that may run with a different (or no) configuration loaded, and it must
  # never be able to execute anything.
  # Prefixed names, so these strings never collide with the ARRAYS of the same
  # concept used in the _quiesce_* helpers above. Reusing `ids` for both a bash
  # array and a space-separated string in one file is exactly the kind of thing
  # that reads fine and then expands to only the first element.
  local st_mode="" st_ids="" st_units="" st_started="" st_snapshot="" st_mountpoint=""
  local line key value
  while IFS= read -r line || [ -n "${line}" ]; do
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      mode) st_mode="${value}" ;;
      ids) st_ids="${value}" ;;
      units) st_units="${value}" ;;
      started) st_started="${value}" ;;
      snapshot) st_snapshot="${value}" ;;
      mountpoint) st_mountpoint="${value}" ;;
    esac
  done <"${f}"

  case "${st_mode}" in
    docker-pause)
      if [ -n "${st_ids}" ]; then
        log "Unpausing containers"
        # A deliberate space-separated list read back from the state file.
        # shellcheck disable=SC2086
        docker unpause ${st_ids} >/dev/null 2>&1 \
          || warn "docker unpause failed for: ${st_ids} - check with 'docker ps -a'"
      fi
      ;;
    service-stop)
      if [ -n "${st_units}" ]; then
        log "Starting unit(s): ${st_units}"
        # shellcheck disable=SC2086
        if ! systemctl start ${st_units}; then
          # This is the worst outcome the tool can produce, so it is reported at
          # error level and repeated in the notification, not just logged.
          err "FAILED TO RESTART: ${st_units}"
          err "MANUAL ACTION REQUIRED: systemctl start ${st_units}"
          BGB_RUN_DEGRADED_REASON="failed to restart ${st_units}"
        fi
      fi
      ;;
    lvm | btrfs | zfs)
      lib_source snapshot_fs.sh 2>/dev/null || true
      if declare -F snapshot_fs_end >/dev/null 2>&1; then
        snapshot_fs_end "${st_snapshot}" "${st_mountpoint}" \
          || warn "Failed to clean up the filesystem snapshot: ${st_snapshot}"
      fi
      ;;
    '')
      debug "Quiesce state file had no mode - nothing to reverse"
      ;;
  esac

  if [ -n "${st_started}" ]; then
    local dur=$(($(now_epoch) - st_started))
    [ "${dur}" -ge 0 ] && BGB_RUN_QUIESCE_SECONDS="${dur}"
    log "Quiesce window: ${dur}s"
  fi
  return 0
}

quiesce_end() {
  local job="${1:-${BGB_JOB}}" f
  f="$(quiesce_state_file "${job}")"
  [ -f "${f}" ] || {
    _BGB_QUIESCE_ACTIVE=0
    return 0
  }

  quiesce_reverse_file "${f}"
  rm -f "${f}"
  _BGB_QUIESCE_ACTIVE=0
  return 0
}

quiesce_cleanup_handler() {
  [ "${_BGB_QUIESCE_ACTIVE}" -eq 1 ] || return 0
  quiesce_end "${BGB_JOB}" || true
}

# -----------------------------------------------------------------------------
# Watchdog
# -----------------------------------------------------------------------------
# quiesce_check_deadline - abort the run when the freeze has lasted longer than
# JOB_QUIESCE_MAX_SECONDS. Called between units of work in the backup loop.
#
# The trade-off is stated plainly: we give up the backup to give back the
# service. A missed backup is recoverable tomorrow; an unbounded outage is not.
quiesce_check_deadline() {
  [ "${_BGB_QUIESCE_ACTIVE}" -eq 1 ] || return 0
  [ "${JOB_QUIESCE_MAX_SECONDS:-0}" -gt 0 ] || return 0
  local elapsed=$(($(now_epoch) - _BGB_QUIESCE_START))
  if [ "${elapsed}" -ge "${JOB_QUIESCE_MAX_SECONDS}" ]; then
    err "Quiesce window exceeded ${JOB_QUIESCE_MAX_SECONDS}s (${elapsed}s elapsed)"
    err "Aborting the backup and restoring service - a missed backup beats an outage"
    return 1
  fi
  return 0
}

# quiesce_is_active - used by `internal unquiesce --if-needed`.
quiesce_is_active() {
  local job="${1:-${BGB_JOB}}"
  [ -f "$(quiesce_state_file "${job}")" ]
}
