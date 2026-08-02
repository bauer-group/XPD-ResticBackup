#!/usr/bin/env bash
# =============================================================================
# bg-backup - lock: serialise runs without letting systemd kill anything
# =============================================================================
# Two levels, neither of them systemd:
#
#   job-<name>     stops a job overlapping itself when a run exceeds its interval
#   repo-<id>      stops backup / forget / prune / check / copy overlapping each
#                  other, which is what makes "prune ran while the backup was
#                  writing" and "two jobs both stopped Docker" structurally
#                  impossible on this host
#
# systemd's Conflicts= is deliberately NOT used: it KILLS the other unit. For a
# job holding Docker down that turns a scheduling collision into an outage.
#
# restic's own repository lock still protects against other hosts; `unlock`
# surfaces and clears stale ones.
#
# /run/lock is tmpfs, so locks cannot survive a reboot - the whole class of
# "stale lock after a crash, cleared by hand at 3am" does not exist here. Within
# a boot, staleness is decided by PID liveness plus a stored boot_id, which
# guards against PID reuse.
# =============================================================================

[ -n "${_BGB_LOCK_SOURCED:-}" ] && return 0
_BGB_LOCK_SOURCED=1

: "${BGB_LOCK_ROOT:=/run/lock/bg-backup}"
_BGB_LOCKS_HELD=()
_BGB_LOCK_CLEANUP_REGISTERED=0

_bgb_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id
  else
    # Containers and rescue systems may not expose boot_id. Fall back to the
    # boot timestamp, which serves the same purpose: distinguishing this boot.
    stat -c %Y /proc/1 2>/dev/null || echo "unknown"
  fi
}

# lock_acquire <name> [wait-seconds]
# Returns 0 on success, EX_LOCKED when the lock is held and the wait expired.
lock_acquire() {
  local name="$1" wait_s="${2:-0}"
  # NOTE: `dir` must be a SEPARATE `local`. Bash evaluates every right-hand side
  # in one `local` statement before any of the declarations take effect, so
  # `local name="$1" dir=".../${name}.d"` expands ${name} to the OUTER value (or
  # nothing at all) and every job would silently share the lock ".d".
  local dir="${BGB_LOCK_ROOT}/${name}.d"
  local waited=0 owner_pid owner_boot owner_cmd boot_now

  if [ "${BGB_NO_LOCK:-0}" = "1" ]; then
    warn "Locking disabled (--no-lock) - concurrent runs are your responsibility"
    return 0
  fi

  boot_now="$(_bgb_boot_id)"
  mkdir -p "${BGB_LOCK_ROOT}" 2>/dev/null || true

  if [ "${_BGB_LOCK_CLEANUP_REGISTERED}" -eq 0 ]; then
    on_cleanup lock_release_all
    _BGB_LOCK_CLEANUP_REGISTERED=1
  fi

  while :; do
    # mkdir is atomic on every POSIX filesystem: exactly one caller can create
    # a given directory. flock would need a persistent fd, which does not
    # survive the subshells this codebase uses freely.
    if mkdir "${dir}" 2>/dev/null; then
      printf '%s\n' "$$"          >"${dir}/pid"
      printf '%s\n' "${boot_now}" >"${dir}/boot"
      printf '%s\n' "${BGB_COMMAND:-?} ${BGB_JOB:-}" >"${dir}/cmd"
      printf '%s\n' "$(now_iso)"  >"${dir}/since"
      _BGB_LOCKS_HELD+=("${dir}")
      debug "Acquired lock '${name}'"
      return 0
    fi

    owner_pid="$(cat "${dir}/pid"  2>/dev/null || true)"
    owner_boot="$(cat "${dir}/boot" 2>/dev/null || true)"
    owner_cmd="$(cat "${dir}/cmd"  2>/dev/null || echo '?')"

    if [ -z "${owner_pid}" ] || [ "${owner_boot}" != "${boot_now}" ] \
       || ! kill -0 "${owner_pid}" 2>/dev/null; then
      warn "Reclaiming stale lock '${name}' (pid=${owner_pid:-none}, cmd=${owner_cmd})"
      rm -rf "${dir}"
      continue
    fi

    if [ "${waited}" -ge "${wait_s}" ]; then
      err "Lock '${name}' is held by PID ${owner_pid} (${owner_cmd})"
      [ "${wait_s}" -gt 0 ] && err "Waited ${waited}s without it being released."
      return "${EX_LOCKED}"
    fi

    [ "${waited}" -eq 0 ] && log "Waiting for lock '${name}' held by PID ${owner_pid} (up to ${wait_s}s)"
    sleep 5
    waited=$(( waited + 5 ))
  done
}

lock_release() {
  local name="$1"
  local dir="${BGB_LOCK_ROOT}/${name}.d"
  local -a keep=()
  local d
  for d in "${_BGB_LOCKS_HELD[@]:-}"; do
    [ -z "${d}" ] && continue
    if [ "${d}" = "${dir}" ]; then rm -rf "${d}"; else keep+=("${d}"); fi
  done
  _BGB_LOCKS_HELD=("${keep[@]:-}")
}

lock_release_all() {
  local d
  for d in "${_BGB_LOCKS_HELD[@]:-}"; do
    [ -n "${d}" ] && rm -rf "${d}"
  done
  _BGB_LOCKS_HELD=()
}

# lock_repo_id - a stable, non-secret identifier for the repository, used as the
# repository lock name so two different repositories can be worked on at once.
lock_repo_id() {
  local r="${RESTIC_REPOSITORY:-default}"
  printf '%s' "$(printf '%s' "${r}" | tr -c 'A-Za-z0-9._-' '_' | tail -c 64)"
}

# lock_take_job <job>  /  lock_take_repo - the two callers actually use.
lock_take_job() {
  local job="$1" wait_s="${BGB_LOCK_WAIT:-${BGB_LOCK_WAIT_SECONDS:-0}}"
  lock_acquire "job-${job}" "${wait_s}"
}

lock_take_repo() {
  local wait_s="${BGB_LOCK_WAIT:-${BGB_LOCK_WAIT_SECONDS:-0}}"
  # With BGB_PARALLEL_JOBS=1 the operator has explicitly accepted concurrent
  # repository access from this host; restic's own lock still applies.
  [ "${BGB_PARALLEL_JOBS:-0}" = "1" ] && return 0
  lock_acquire "repo-$(lock_repo_id)" "${wait_s}"
}

# lock_status - what `doctor` and `status` report.
lock_status() {
  local dir
  [ -d "${BGB_LOCK_ROOT}" ] || return 0
  for dir in "${BGB_LOCK_ROOT}"/*.d; do
    [ -d "${dir}" ] || continue
    printf '%s\tpid=%s\tsince=%s\tcmd=%s\n' \
      "$(basename "${dir}" .d)" \
      "$(cat "${dir}/pid" 2>/dev/null || echo '?')" \
      "$(cat "${dir}/since" 2>/dev/null || echo '?')" \
      "$(cat "${dir}/cmd" 2>/dev/null || echo '?')"
  done
}
