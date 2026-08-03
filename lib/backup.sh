#!/usr/bin/env bash
# =============================================================================
# bg-backup - backup: the run orchestrator
# =============================================================================
# Per job, in this exact order:
#
#   recover a stale quiesce -> locks -> repository -> notify start -> pre-hooks
#   -> quiesce -> restic (per mode) -> un-quiesce -> post-hooks -> state
#   -> metrics -> forget -> notify result
#
# The ordering is load-bearing in three places:
#   * stale-quiesce recovery runs FIRST, so a new backup never starts on top of
#     a host a previous run left frozen
#   * un-quiesce happens before the locks are released, so a waiting job cannot
#     start while services are still down
#   * forget runs only after a successful snapshot; applying retention after a
#     failed run is how a bad night turns into data loss
# =============================================================================

[ -n "${_BGB_BACKUP_SOURCED:-}" ] && return 0
_BGB_BACKUP_SOURCED=1

cmd_backup() {
  local all=0 skip_hooks=0 force_unlock=0
  local -a jobs=() extra_tags=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        all=1
        shift
        ;;
      --skip-hooks)
        skip_hooks=1
        shift
        ;;
      --force-unlock)
        force_unlock=1
        shift
        ;;
      --tag)
        extra_tags+=("$2")
        shift 2
        ;;
      --tag=*)
        extra_tags+=("${1#*=}")
        shift
        ;;
      -*)
        err "Unknown flag for backup: $1"
        usage_backup
        exit "${EX_USAGE}"
        ;;
      *)
        jobs+=("$1")
        shift
        ;;
    esac
  done

  require_root
  config_load

  # --job is the global filter; positional names win over it.
  if [ "${#jobs[@]}" -eq 0 ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ]; then
    jobs=("${BGB_JOB_FILTER[@]}")
  fi
  if [ "${#jobs[@]}" -eq 0 ] || [ "${all}" -eq 1 ]; then
    mapfile -t jobs < <(config_list_jobs)
  fi
  [ "${#jobs[@]}" -gt 0 ] || die "${EX_PRECOND}" "No jobs defined in ${BGB_CONFDIR}/conf.d"

  local worst=0 rc=0 job
  local -a reports=()

  for job in "${jobs[@]}"; do
    [ -n "${job}" ] || continue
    rc=0
    backup_run_job "${job}" "${skip_hooks}" "${force_unlock}" "${extra_tags[@]:-}" || rc=$?
    worst="$(worst_rc "${worst}" "${rc}")"
    reports+=("$(backup_job_report_json "${job}" "${rc}")")
  done

  if [ "${BGB_JSON}" = "1" ]; then
    local body first=1 r
    body='"jobs":['
    for r in "${reports[@]}"; do
      [ "${first}" -eq 0 ] && body+=","
      body+="${r}"
      first=0
    done
    body+="]"
    local verdict="ok"
    case "${worst}" in 0) verdict="ok" ;; 3) verdict="partial" ;; *) verdict="failed" ;; esac
    json_envelope "${verdict}" "${body}"
  fi

  return "${worst}"
}

# -----------------------------------------------------------------------------
# One job
# -----------------------------------------------------------------------------
backup_run_job() {
  local job="$1" skip_hooks="$2" force_unlock="$3"
  shift 3
  local -a extra_tags=("$@")
  local rc=0 start end run_id snapshot="" status="failed"

  config_load_job "${job}"

  if [ "${JOB_ENABLED}" != "1" ]; then
    log "Job '${job}' is disabled - skipping"
    return 0
  fi

  state_reset_run_counters
  run_id="$(state_new_run_id)"
  BGB_RUN_ID="${run_id}"
  export BGB_RUN_ID
  start="$(now_epoch)"

  local joblog
  joblog="${BGB_LOG_DIR}/jobs/${job}-$(date -u '+%Y%m%dT%H%M%SZ').log"
  install -d -m 0750 "${BGB_LOG_DIR}/jobs" 2>/dev/null || true
  log_open "${joblog}"
  BGB_JOB_LOG="${joblog}"

  log "=== job '${job}' (${JOB_MODE}) run ${run_id} ==="

  # 1. Locks FIRST. The repository lock serialises against
  #    forget/prune/check/copy; the job lock is what makes step 2 safe.
  lock_take_job "${job}" || return "${EX_LOCKED}"
  lock_take_repo || return "${EX_LOCKED}"

  # 2. Undo anything a PREVIOUS run left frozen.
  #
  # This used to run BEFORE the locks, and the ordering was the bug: a second
  # invocation of the same job would find the journal of the run that is still
  # in progress, unpause its containers underneath it and delete its journal -
  # so the first run then finished with no record of what it had frozen. The job
  # lock is precisely the proof that no other run owns this journal, so the
  # recovery has to happen behind it.
  quiesce_recover_stale "${job}"

  # 3. Repository.
  repo_env_load
  restic_require

  if [ "${force_unlock}" = "1" ]; then
    log "Clearing stale restic locks for this host"
    restic_exec unlock || warn "restic unlock failed (continuing)"
  fi

  # 4. Announce the start (used by dead-man's-switch monitors).
  monitor_notify start "${job}" 0 || true
  monitor_maintenance_begin "${job}" || true

  # 5. Pre-hooks.
  if [ "${skip_hooks}" != "1" ]; then
    if ! backup_run_hooks "${job}" pre; then
      rc="${EX_HOOK}"
      status="failed"
      backup_finish "${job}" "${status}" "${rc}" "${run_id}" "${start}" "" || true
      return "${rc}"
    fi
  fi

  # 6. The work itself, per mode.
  case "${JOB_MODE}" in
    files) backup_mode_files "${job}" "${run_id}" "${extra_tags[@]:-}" || rc=$? ;;
    docker) backup_mode_docker "${job}" "${run_id}" "${extra_tags[@]:-}" || rc=$? ;;
    config) backup_mode_config "${job}" "${run_id}" "${extra_tags[@]:-}" || rc=$? ;;
    stdin) backup_mode_stdin "${job}" "${run_id}" "${extra_tags[@]:-}" || rc=$? ;;
    *)
      err "Unsupported JOB_MODE: ${JOB_MODE}"
      rc="${EX_PRECOND}"
      ;;
  esac

  # 7. Reverse the quiesce explicitly (the trap would too; doing it here means
  #    post-hooks and retention run against a healthy host).
  quiesce_end "${job}" || true
  monitor_maintenance_end "${job}" || true

  snapshot="${BGB_RUN_SNAPSHOT_ID:-}"

  # 8. Post-hooks. A failed post-hook never invalidates the snapshot that was
  #    already written, so it degrades the result rather than replacing it.
  if [ "${skip_hooks}" != "1" ] && [ "${rc}" -ne "${EX_HOOK}" ]; then
    backup_run_hooks "${job}" post || rc="$(worst_rc "${rc}" "${EX_HOOK}")"
  fi

  # 9. Classify.
  status="$(backup_classify "${rc}")"
  if [ -n "${BGB_RUN_DEGRADED_REASON}" ] && [ "${status}" = "ok" ]; then
    status="degraded"
    # A degraded result is treated as a failure on purpose: "the snapshot exists
    # but its consistency is not guaranteed" is precisely the silent state this
    # tool exists to eliminate.
    rc="$(worst_rc "${rc}" "${EX_FAIL}")"
  fi
  if [ "${status}" = "partial" ] && [ "${JOB_PARTIAL_IS_FAILURE}" = "1" ]; then
    warn "Exit 3 during a quiesced job means files were unreadable with services stopped"
    rc="$(worst_rc "${rc}" "${EX_FAIL}")"
    status="failed"
  fi

  backup_finish "${job}" "${status}" "${rc}" "${run_id}" "${start}" "${snapshot}"

  # 10. Retention, only after a snapshot actually exists.
  if [ "${JOB_FORGET_AFTER_BACKUP}" = "1" ] && [ -n "${snapshot}" ]; then
    case "${status}" in
      ok | partial) retention_forget "${job}" 1 || warn "forget failed (backup itself was fine)" ;;
      *) warn "Skipping forget: this run did not complete cleanly" ;;
    esac
  fi

  lock_release "repo-$(lock_repo_id)"
  lock_release "job-${job}"

  end="$(now_epoch)"
  log "=== job '${job}' finished: ${status} (rc=${rc}) in $(human_duration $((end - start))) ==="
  return "${rc}"
}

backup_classify() {
  case "${1}" in
    0) printf 'ok' ;;
    3) printf 'partial' ;;
    *) printf 'failed' ;;
  esac
}

backup_finish() {
  local job="$1" status="$2" rc="$3" run_id="$4" start="$5" snapshot="$6"
  local end
  end="$(now_epoch)"

  state_write "${job}" "${status}" "${rc}" "${run_id}" "${start}" "${end}" "${snapshot}"
  # metrics_write, not metrics_write_job: the latter was never written. Guarded
  # by `|| true`, the resulting "command not found" cost nothing visible and the
  # Prometheus textfile was simply never produced - by any job, ever. The
  # numbers come from the state file that state_write() just updated, so the
  # per-run arguments the old call passed were never needed here.
  metrics_write "${job}" || true

  case "${status}" in
    ok) monitor_notify success "${job}" "${rc}" || true ;;
    partial) monitor_notify partial "${job}" "${rc}" || true ;;
    degraded) monitor_notify degraded "${job}" "${rc}" || true ;;
    *) monitor_notify failure "${job}" "${rc}" || true ;;
  esac
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------
backup_mode_files() {
  local job="$1" run_id="$2"
  shift 2
  local -a extra_tags=("$@") args=()
  local rc=0 jsonl

  quiesce_begin "${job}"

  mapfile -t args < <(restic_build_backup_args "${job}" "${run_id}")
  local t
  for t in "${extra_tags[@]:-}"; do
    [ -n "${t}" ] && args+=(--tag "${t}")
  done
  local -a globals=()
  mapfile -t globals < <(restic_global_args)
  [ "${#globals[@]}" -gt 0 ] && args=("${args[@]:0:1}" "${globals[@]}" "${args[@]:1}")

  jsonl="$(tmp_file "backup.XXXXXX.jsonl")"
  log "Backing up: ${JOB_PATHS[*]:-} ${JOB_EXTRA_PATHS[*]:-}"

  # restic --json emits one object per line; the human log gets the same stream
  # so a manual run and a timer run produce identical evidence.
  set +e
  restic_exec "${args[@]}" | tee -a "${jsonl}" >>"${BGB_JOB_LOG}"
  rc="${PIPESTATUS[0]}"
  set -e

  backup_absorb_summary "${jsonl}" "${rc}"
  restic_map_rc "${rc}" || return $?
  return 0
}

backup_mode_config() {
  local job="$1" run_id="$2"
  shift 2
  local -a args=() paths=()
  local rc=0 jsonl p

  for p in "${JOB_CONFIG_PATHS[@]:-}"; do
    [ -n "${p}" ] && [ -e "${p}" ] && paths+=("${p}")
  done
  [ "${#paths[@]}" -gt 0 ] || {
    warn "Nothing to back up for the config job"
    return 0
  }

  args=(backup --host "${BGB_HOSTNAME}" --json)
  mapfile -t -O "${#args[@]}" args < <(restic_tag_args "${job}" "${run_id}" "${JOB_TAGS[@]:-}" "$@")
  args+=("${paths[@]}")

  jsonl="$(tmp_file "config.XXXXXX.jsonl")"
  log "Backing up configuration: ${paths[*]}"
  set +e
  restic_exec "${args[@]}" | tee -a "${jsonl}" >>"${BGB_JOB_LOG}"
  rc="${PIPESTATUS[0]}"
  set -e

  backup_absorb_summary "${jsonl}" "${rc}"
  restic_map_rc "${rc}" || return $?

  # Record the configuration hash so `doctor` can tell whether the recovery
  # bundle still matches what is deployed. This is the most common way the
  # bootstrap story quietly rots: someone adds a credential and never re-exports.
  state_touch config_hash "$(backup_config_hash)"
  state_touch config_snapshot_at "$(now_iso)"
  return 0
}

backup_config_hash() {
  find "${BGB_CONFDIR}" -type f -print0 2>/dev/null \
    | sort -z | xargs -0 sha256sum 2>/dev/null \
    | sha256sum | awk '{print $1}'
}

backup_mode_docker() {
  local job="$1" run_id="$2"
  shift 2
  lib_source docker.sh
  lib_source db.sh
  docker_backup_run "${job}" "${run_id}" "$@"
}

backup_mode_stdin() {
  local job="$1" run_id="$2"
  shift 2
  [ -n "${JOB_STDIN_COMMAND:-}" ] \
    || die "${EX_PRECOND}" "${job}: JOB_MODE=stdin requires JOB_STDIN_COMMAND"
  local -a args=(backup --host "${BGB_HOSTNAME}" --json
    --stdin-from-command
    --stdin-filename "${JOB_STDIN_FILENAME:-${job}.dump}")
  mapfile -t -O "${#args[@]}" args < <(restic_tag_args "${job}" "${run_id}" "${JOB_TAGS[@]:-}" "$@")
  args+=(--)
  # Deliberately word-split: the operator wrote a command line, not a path.
  # shellcheck disable=SC2206
  local -a cmd=(${JOB_STDIN_COMMAND})
  args+=("${cmd[@]}")

  local rc=0 jsonl
  jsonl="$(tmp_file "stdin.XXXXXX.jsonl")"
  set +e
  restic_exec "${args[@]}" | tee -a "${jsonl}" >>"${BGB_JOB_LOG}"
  rc="${PIPESTATUS[0]}"
  set -e
  backup_absorb_summary "${jsonl}" "${rc}"
  restic_map_rc "${rc}" || return $?
  return 0
}

# -----------------------------------------------------------------------------
# Summary absorption
# -----------------------------------------------------------------------------
# The BGB_RUN_* counters are read by state.sh and metrics.sh, both sourced
# dynamically by the dispatcher.
# shellcheck disable=SC2034
backup_absorb_summary() {
  local jsonl="$1" rc="$2"

  if ! have jq; then
    # The backup itself is fine - restic wrote a snapshot. What is lost is every
    # fact ABOUT it: the snapshot id, the byte counts, the unreadable-file count.
    #
    # That degrades the tool in ways that are not obvious later: `status` shows a
    # successful job with no snapshot id, `verify` has nothing to sample, and
    # retention is skipped because this run cannot prove it produced anything.
    # So this warns on every run rather than whispering into the debug log.
    #
    # It is still not a hard failure: on a rescue system, taking the backup and
    # losing the bookkeeping beats refusing to take the backup.
    warn "jq is not installed - snapshot id and counters cannot be recorded"
    warn "  the data IS backed up, but 'status', 'verify' and retention are degraded"
    warn "  fix with: apt-get install -y jq"
    BGB_RUN_DEGRADED_REASON="jq missing: run metadata not recorded"
    return 0
  fi

  restic_parse_summary "${jsonl}"
  BGB_RUN_SNAPSHOT_ID="${RESTIC_SNAPSHOT_ID}"
  BGB_RUN_FILES_NEW="${RESTIC_FILES_NEW}"
  BGB_RUN_FILES_CHANGED="${RESTIC_FILES_CHANGED}"
  BGB_RUN_FILES_UNMODIFIED="${RESTIC_FILES_UNMODIFIED}"
  BGB_RUN_BYTES_ADDED="${RESTIC_DATA_ADDED}"
  BGB_RUN_BYTES_PROCESSED="${RESTIC_TOTAL_BYTES}"
  BGB_RUN_FILES_UNREADABLE="$(restic_count_errors "${jsonl}")"

  if [ -n "${BGB_RUN_SNAPSHOT_ID}" ]; then
    log "Snapshot ${BGB_RUN_SNAPSHOT_ID}: +$(human_bytes "${BGB_RUN_BYTES_ADDED}") (${BGB_RUN_FILES_NEW} new, ${BGB_RUN_FILES_CHANGED} changed)"
  fi

  if [ "${rc}" = "3" ] && [ "${BGB_RUN_FILES_UNREADABLE}" != "0" ]; then
    warn "${BGB_RUN_FILES_UNREADABLE} file(s) could not be read"
    # Paths go to the local log only. Sending filenames to a SaaS endpoint is an
    # information disclosure about the host; the count is the useful part.
    restic_error_paths "${jsonl}" 20 | while IFS= read -r p; do
      debug "unreadable: ${p}"
    done
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Hooks
# -----------------------------------------------------------------------------
# Hooks receive a SCRUBBED environment: job identity yes, backend credentials no.
# A hook that needs repository access can source the credentials file itself,
# deliberately and visibly.
backup_run_hooks() {
  local job="$1" phase="$2"
  local -a hooks=()
  local h rc=0

  case "${phase}" in
    pre) hooks=("${JOB_PRE_HOOKS[@]:-}") ;;
    post) hooks=("${JOB_POST_HOOKS[@]:-}") ;;
  esac

  local dropin="${BGB_CONFDIR}/hooks/${job}/${phase}.d"
  if [ -d "${dropin}" ]; then
    while IFS= read -r h; do
      [ -n "${h}" ] && hooks+=("${h}")
    done < <(find "${dropin}" -maxdepth 1 -type f -perm -u+x 2>/dev/null | sort)
  fi

  for h in "${hooks[@]:-}"; do
    [ -n "${h}" ] || continue
    if [ ! -x "${h}" ]; then
      warn "Hook is not executable, skipping: ${h}"
      continue
    fi
    log "Running ${phase}-hook: ${h}"
    rc=0
    env -i \
      PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      HOME="/root" \
      BGB_JOB="${job}" \
      BGB_PHASE="${phase}" \
      BGB_HOSTNAME="${BGB_HOSTNAME}" \
      BGB_RUN_ID="${BGB_RUN_ID:-}" \
      BGB_JOB_MODE="${JOB_MODE}" \
      "${h}" >>"${BGB_JOB_LOG}" 2>&1 || rc=$?

    if [ "${rc}" -ne 0 ]; then
      if [ "${JOB_HOOK_FAILURE}" = "abort" ]; then
        err "${phase}-hook failed (rc=${rc}): ${h}"
        err "JOB_HOOK_FAILURE=abort - not proceeding"
        return 1
      fi
      warn "${phase}-hook failed (rc=${rc}) but JOB_HOOK_FAILURE=warn: ${h}"
    fi
  done
  return 0
}

# -----------------------------------------------------------------------------
# Reporting
# -----------------------------------------------------------------------------
backup_job_report_json() {
  local job="$1" rc="$2"
  printf '{'
  json_kv name "${job}"
  printf ','
  json_kv status "$(backup_classify "${rc}")"
  printf ','
  json_kvraw rc "$(json_num "${rc}")"
  printf ','
  json_kv snapshot_id "$(state_field "${job}" snapshot_id)"
  printf ','
  json_kvraw duration_seconds "$(json_num "$(state_field "${job}" duration_seconds)")"
  printf ','
  json_kvraw bytes_added "$(json_num "$(state_field "${job}" bytes_added)")"
  printf '}'
}
