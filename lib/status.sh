#!/usr/bin/env bash
# =============================================================================
# bg-backup - status: the operator dashboard, and what monitoring scrapes
# =============================================================================
# `status` answers one question: is this host actually protected right now?
#
# It is deliberately based on the LAST SUCCESS, not the last attempt. A job that
# fails every hour has a very recent "last run" and no backup at all; reporting
# freshness from the attempt would make that look healthy.
# =============================================================================

[ -n "${_BGB_STATUS_SOURCED:-}" ] && return 0
_BGB_STATUS_SOURCED=1

cmd_status() {
  local job=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --job)   job="$2"; shift 2 ;;
      --job=*) job="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  [ -z "${job}" ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ] && job="${BGB_JOB_FILTER[0]}"

  config_load

  local -a jobs=()
  if [ -n "${job}" ]; then jobs=("${job}"); else mapfile -t jobs < <(config_list_jobs); fi

  local repo_ok=0 repo_locked=0
  if [ -f "${BGB_REPO_ENV}" ] && ( repo_env_load ) >/dev/null 2>&1; then
    repo_env_load >/dev/null 2>&1 || true
    if [ -x "${BGB_RESTIC_BIN}" ] && restic_repo_reachable; then
      repo_ok=1
      restic_is_locked && repo_locked=1
    fi
  fi

  local worst=0
  [ "${repo_ok}" -eq 0 ] && worst="${EX_REPO}"

  if [ "${BGB_JSON}" = "1" ]; then
    status_json "${repo_ok}" "${repo_locked}" "${jobs[@]:-}"
    status_worst_from_jobs "${jobs[@]:-}" || worst="$(worst_rc "${worst}" "$?")"
    return "${worst}"
  fi

  status_human "${repo_ok}" "${repo_locked}" "${jobs[@]:-}"
  status_worst_from_jobs "${jobs[@]:-}" || worst="$(worst_rc "${worst}" "$?")"
  return "${worst}"
}

status_worst_from_jobs() {
  local job rc=0
  for job in "$@"; do
    [ -n "${job}" ] || continue
    ( config_load_job "${job}" ) >/dev/null 2>&1 || continue
    config_load_job "${job}" >/dev/null 2>&1 || true
    [ "${JOB_ENABLED}" = "1" ] || continue
    state_sla_ok "${job}" "${JOB_ALERT_MAX_AGE_HOURS}" || rc="${EX_PARTIAL}"
  done
  return "${rc}"
}

status_human() {
  local repo_ok="$1" repo_locked="$2"; shift 2
  local job status age sla snap dur bytes next timer

  printf '\n%sbg-backup status%s  %s\n\n' "${C_BOLD}" "${C_RESET}" "$(fqdn)"

  printf '%sRepository%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  url          %s\n' "$(redact "${RESTIC_REPOSITORY:-<not configured>}")"
  printf '  prefix       %s\n' "$(repo_prefix)"
  printf '  role         %s\n' "${BGB_REPO_ROLE}"
  if [ "${repo_ok}" -eq 1 ]; then
    printf '  reachable    %syes%s\n' "${C_GREEN}" "${C_RESET}"
  else
    printf '  reachable    %sNO%s\n' "${C_RED}" "${C_RESET}"
  fi
  [ "${repo_locked}" -eq 1 ] && printf '  lock         %sheld%s\n' "${C_YELLOW}" "${C_RESET}"
  printf '  last check   %s\n' "$(state_get_repo check_at || echo never)"
  printf '  last proven  %s\n' "$(state_get_repo verify_at || echo never)"
  printf '  last copy    %s\n' "$(state_get_repo copy_at || echo never)"

  printf '\n%sJobs%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  %-14s %-9s %8s %8s  %-10s %-8s %s\n' \
    "JOB" "STATUS" "AGE" "SLA" "SNAPSHOT" "TOOK" "NEXT"

  for job in "$@"; do
    [ -n "${job}" ] || continue
    ( config_load_job "${job}" ) >/dev/null 2>&1 || { printf '  %-14s %sINVALID CONFIG%s\n' "${job}" "${C_RED}" "${C_RESET}"; continue; }
    config_load_job "${job}" >/dev/null 2>&1 || true

    if [ "${JOB_ENABLED}" != "1" ]; then
      printf '  %-14s %s%-9s%s\n' "${job}" "${C_DIM}" "disabled" "${C_RESET}"
      continue
    fi

    status="$(state_field "${job}" status)"; status="${status:-never}"
    age="$(state_age_hours "${job}")"
    sla="${JOB_ALERT_MAX_AGE_HOURS}"
    snap="$(state_field "${job}" snapshot_id)"
    dur="$(state_field "${job}" duration_seconds)"
    bytes="$(state_field "${job}" bytes_added)"

    timer="bg-backup@${job}.timer"
    next="-"
    if have systemctl && systemctl is-enabled --quiet "${timer}" 2>/dev/null; then
      next="$(systemctl show -p NextElapseUSecRealtime --value "${timer}" 2>/dev/null || true)"
      [ -z "${next}" ] && next="enabled"
    fi

    local colour="${C_GREEN}"
    case "${status}" in
      ok) colour="${C_GREEN}" ;;
      partial) colour="${C_YELLOW}" ;;
      degraded|failed) colour="${C_RED}" ;;
      never) colour="${C_DIM}" ;;
    esac
    if [ -n "${age}" ] && ! state_sla_ok "${job}" "${sla}"; then colour="${C_RED}"; fi

    printf '  %-14s %s%-9s%s %7sh %7sh  %-10s %-8s %s\n' \
      "${job}" "${colour}" "${status}" "${C_RESET}" \
      "${age:--}" "${sla}" "${snap:--}" \
      "$([ -n "${dur}" ] && human_duration "${dur}" | sed 's/^0h //' || echo '-')" \
      "${next}"

    local reason; reason="$(state_field "${job}" degraded_reason)"
    [ -n "${reason}" ] && printf '                 %s! %s%s\n' "${C_YELLOW}" "${reason}" "${C_RESET}"
    [ -n "${bytes}" ] && [ "${bytes}" != "0" ] && \
      printf '                 %sadded %s%s\n' "${C_DIM}" "$(human_bytes "${bytes}")" "${C_RESET}"
  done

  local locks; locks="$(lock_status 2>/dev/null || true)"
  if [ -n "${locks}" ]; then
    printf '\n%sActive locks%s\n' "${C_BOLD}" "${C_RESET}"
    printf '%s\n' "${locks}" | sed 's/^/  /'
  fi
  printf '\n'
}

status_json() {
  local repo_ok="$1" repo_locked="$2"; shift 2
  local job first=1 body verdict="ok"

  body='"repository":{'
  body+="$(json_kv url "$(redact "${RESTIC_REPOSITORY:-}")"),"
  body+="$(json_kv prefix "$(repo_prefix)"),"
  body+="$(json_kv role "${BGB_REPO_ROLE}"),"
  body+="$(json_kvraw reachable "$(json_bool "${repo_ok}")"),"
  body+="$(json_kvraw locked "$(json_bool "${repo_locked}")"),"
  body+="$(json_kv last_check "$(state_get_repo check_at)"),"
  body+="$(json_kv last_verify "$(state_get_repo verify_at)"),"
  body+="$(json_kv last_copy "$(state_get_repo copy_at)")"
  body+='},"jobs":['

  for job in "$@"; do
    [ -n "${job}" ] || continue
    ( config_load_job "${job}" ) >/dev/null 2>&1 || continue
    config_load_job "${job}" >/dev/null 2>&1 || true
    [ "${first}" -eq 0 ] && body+=","
    first=0

    local st age
    st="$(state_field "${job}" status)"
    age="$(state_age_hours "${job}")"
    local sla_ok=1
    state_sla_ok "${job}" "${JOB_ALERT_MAX_AGE_HOURS}" || sla_ok=0
    [ "${JOB_ENABLED}" = "1" ] && [ "${sla_ok}" -eq 0 ] && verdict="stale"
    case "${st}" in failed|degraded) verdict="failed" ;; esac

    body+="{"
    body+="$(json_kv name "${job}"),"
    body+="$(json_kvraw enabled "$(json_bool "${JOB_ENABLED}")"),"
    body+="$(json_kv mode "${JOB_MODE}"),"
    body+="$(json_kv status "${st:-never}"),"
    body+="$(json_kvraw rc "$(json_num "$(state_field "${job}" rc)")"),"
    body+="$(json_kv snapshot_id "$(state_field "${job}" snapshot_id)"),"
    body+="$(json_kv run_id "$(state_field "${job}" run_id)"),"
    body+="$(json_kv last_start "$(state_field "${job}" started)"),"
    body+="$(json_kv last_end "$(state_field "${job}" ended)"),"
    body+="$(json_kvraw duration_seconds "$(json_num "$(state_field "${job}" duration_seconds)")"),"
    body+="$(json_kvraw bytes_added "$(json_num "$(state_field "${job}" bytes_added)")"),"
    body+="$(json_kvraw files_unreadable "$(json_num "$(state_field "${job}" files_unreadable)")"),"
    body+="$(json_kvraw age_hours "$(json_num "${age}")"),"
    body+="$(json_kvraw sla_hours "$(json_num "${JOB_ALERT_MAX_AGE_HOURS}")"),"
    body+="$(json_kvraw sla_ok "$(json_bool "${sla_ok}")"),"
    body+="$(json_kv degraded_reason "$(state_field "${job}" degraded_reason)")"
    body+="}"
  done
  body+=']'

  [ "${repo_ok}" -eq 0 ] && verdict="unreachable"
  json_envelope "${verdict}" "${body}"
}

# -----------------------------------------------------------------------------
# logs
# -----------------------------------------------------------------------------
cmd_logs() {
  local job="" follow=0 lines=200
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      --lines) lines="$2"; shift 2 ;;
      --lines=*) lines="${1#*=}"; shift ;;
      -*) err "Unknown flag for logs: $1"; exit "${EX_USAGE}" ;;
      *) job="$1"; shift ;;
    esac
  done
  config_load

  if [ "${BGB_JSON}" = "1" ]; then
    local ev="${BGB_LOG_DIR}/events.jsonl"
    [ -r "${ev}" ] || die "${EX_PRECOND}" "No event log at ${ev}"
    if [ -n "${job}" ] && have jq; then
      jq -c --arg j "${job}" 'select(.job==$j)' "${ev}" | tail -n "${lines}"
    else
      tail -n "${lines}" "${ev}"
    fi
    return 0
  fi

  local target
  if [ -n "${job}" ]; then
    target="$(find "${BGB_LOG_DIR}/jobs" -name "${job}-*.log" -type f 2>/dev/null | sort | tail -n1)"
    [ -n "${target}" ] || die "${EX_PRECOND}" "No log found for job '${job}'"
  else
    target="${BGB_LOG_DIR}/bg-backup.log"
    [ -r "${target}" ] || die "${EX_PRECOND}" "No log at ${target}"
  fi

  # Logs on disk are already redacted at write time; redacting again here is
  # cheap insurance for anything that reached the file another way.
  if [ "${follow}" -eq 1 ]; then
    tail -n "${lines}" -f "${target}"
  else
    tail -n "${lines}" "${target}" | redact_stream
  fi
}
