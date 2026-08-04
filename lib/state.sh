#!/usr/bin/env bash
# =============================================================================
# bg-backup - state: what happened last time
# =============================================================================
# One JSON document per job under /var/lib/bg-backup/state/<job>.json, written
# atomically, plus an append-only event log at /var/log/bg-backup/events.jsonl.
#
# This is what `status`, `doctor` and the metrics writer read. It exists because
# systemd only remembers the last invocation's result, and because a run's
# useful facts (snapshot id, bytes added, unreadable files, quiesce duration)
# have nowhere else to live.
# =============================================================================

[ -n "${_BGB_STATE_SOURCED:-}" ] && return 0
_BGB_STATE_SOURCED=1

state_file() { printf '%s/%s.json' "${BGB_STATE_DIR}" "$1"; }

state_dir_ensure() {
  install -d -m 0700 "${BGB_STATE_DIR}" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Run identity
# -----------------------------------------------------------------------------
# A run groups the several snapshots one `bg-backup backup` produces (file
# snapshot, one per database dump, the docker manifest). Restoring by "latest"
# per snapshot would happily pair Monday's database dump with Tuesday's volume
# contents; restoring by run cannot.
#
# Sortable, collision-resistant, and readable in a log: UTC timestamp plus
# random suffix. Not a real ULID - no dependency is worth the difference here.
state_new_run_id() {
  local rand
  if [ -r /dev/urandom ]; then
    rand="$(LC_ALL=C tr -dc 'a-hjkmnp-z0-9' </dev/urandom 2>/dev/null | head -c 6 || true)"
  fi
  [ -z "${rand:-}" ] && rand="$(printf '%06x' $((RANDOM * RANDOM % 16777216)))"
  printf '%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "${rand}"
}

# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------
# state_write <job> <status> <rc> <run-id> <start-epoch> <end-epoch> <snapshot-id>
#   status: ok | partial | failed | degraded | skipped
state_write() {
  local job="$1" status="$2" rc="$3" run_id="$4" start="$5" end="$6" snap="$7"
  local f
  f="$(state_file "${job}")"
  state_dir_ensure

  local duration=$((end - start))
  [ "${duration}" -lt 0 ] && duration=0

  {
    printf '{'
    json_kvraw schema "${BGB_JSON_SCHEMA}"
    printf ','
    json_kv job "${job}"
    printf ','
    json_kv host "${BGB_HOSTNAME}"
    printf ','
    json_kv run_id "${run_id}"
    printf ','
    json_kv status "${status}"
    printf ','
    json_kvraw rc "$(json_num "${rc}")"
    printf ','
    json_kv started "$(date -u -d "@${start}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || now_iso)"
    printf ','
    json_kv ended "$(date -u -d "@${end}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || now_iso)"
    printf ','
    json_kvraw started_epoch "$(json_num "${start}")"
    printf ','
    json_kvraw ended_epoch "$(json_num "${end}")"
    printf ','
    json_kvraw duration_seconds "$(json_num "${duration}")"
    printf ','
    json_kv snapshot_id "${snap}"
    printf ','
    json_kvraw files_new "$(json_num "${BGB_RUN_FILES_NEW:-0}")"
    printf ','
    json_kvraw files_changed "$(json_num "${BGB_RUN_FILES_CHANGED:-0}")"
    printf ','
    json_kvraw files_unmodified "$(json_num "${BGB_RUN_FILES_UNMODIFIED:-0}")"
    printf ','
    json_kvraw files_unreadable "$(json_num "${BGB_RUN_FILES_UNREADABLE:-0}")"
    printf ','
    json_kvraw bytes_added "$(json_num "${BGB_RUN_BYTES_ADDED:-0}")"
    printf ','
    json_kvraw bytes_processed "$(json_num "${BGB_RUN_BYTES_PROCESSED:-0}")"
    printf ','
    json_kvraw quiesce_seconds "$(json_num "${BGB_RUN_QUIESCE_SECONDS:-0}")"
    printf ','
    json_kvraw db_dumps "$(json_num "${BGB_RUN_DB_DUMPS:-0}")"
    printf ','
    json_kvraw db_dumps_failed "$(json_num "${BGB_RUN_DB_DUMPS_FAILED:-0}")"
    printf ','
    json_kv degraded_reason "${BGB_RUN_DEGRADED_REASON:-}"
    printf ','
    json_kv repo_prefix "$(repo_prefix)"
    printf ','
    json_kv tool_version "${BGB_VERSION}"
    printf '}\n'
  } | atomic_write "${f}" 0640

  state_event "${job}" "${status}" "${rc}" "${run_id}" "${snap}"
}

# state_mark_success_field <job> <field> <iso-time> - update one timestamp
# without rewriting the whole document (used for check/verify/copy/export).
state_touch() {
  local key="$1" value="${2:-$(now_iso)}"
  local f="${BGB_STATE_DIR}/_repo.json"
  state_dir_ensure
  if have jq && [ -f "${f}" ]; then
    jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${f}" 2>/dev/null | atomic_write "${f}" 0640
  else
    # Flat key=value sidecar rather than losing the fact.
    #
    # NOTE this is not the rare branch it looks like: the condition above also
    # requires _repo.json to already EXIST, and nothing in the codebase ever
    # creates it, so every host takes this path. state_get_repo() tests exactly
    # the same condition and therefore reads the same file, so the two stay
    # consistent - do NOT "fix" that by creating _repo.json here, which would
    # point reads at an empty document and lose the history of every host that
    # already has a populated sidecar.
    #
    # THE `|| true` IS LOAD-BEARING. grep exits 1 when it selects no lines,
    # which is the normal case the first time a key is written (and whenever the
    # sidecar holds only that key). With `set -e` and `pipefail` that killed the
    # whole command AFTER the write had already happened, so `bg-backup check`
    # printed restic's "no errors were found" and then exited 1 - a repository
    # in perfect health reported as a failed check, on a weekly timer.
    local side="${BGB_STATE_DIR}/_repo.env"
    touch "${side}"
    {
      grep -v "^${key}=" "${side}" 2>/dev/null || true
      printf '%s=%s\n' "${key}" "${value}"
    } | atomic_write "${side}" 0640
  fi
}

state_get_repo() {
  local key="$1" f="${BGB_STATE_DIR}/_repo.json"
  if have jq && [ -f "${f}" ]; then
    jq -r --arg k "${key}" '.[$k] // empty' "${f}" 2>/dev/null || true
  else
    awk -F= -v k="${key}" '$1==k{print $2}' "${BGB_STATE_DIR}/_repo.env" 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# Event log
# -----------------------------------------------------------------------------
# One JSON object per line, shippable to Loki or Elastic without a parser.
# Written by the tool rather than relying on systemd's StandardOutput=append:,
# so a manual run is recorded identically to a timer run.
state_event() {
  local job="$1" status="$2" rc="$3" run_id="$4" snap="$5"
  local f="${BGB_LOG_DIR}/events.jsonl"
  install -d -m 0750 "${BGB_LOG_DIR}" 2>/dev/null || return 0
  {
    printf '{'
    json_kv ts "$(now_iso)"
    printf ','
    json_kv host "${BGB_HOSTNAME}"
    printf ','
    json_kv command "${BGB_COMMAND}"
    printf ','
    json_kv job "${job}"
    printf ','
    json_kv run_id "${run_id}"
    printf ','
    json_kv status "${status}"
    printf ','
    json_kvraw rc "$(json_num "${rc}")"
    printf ','
    json_kv snapshot_id "${snap}"
    printf '}\n'
  } >>"${f}" 2>/dev/null || true
  chmod 0640 "${f}" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------
state_read() {
  local job="$1" f
  f="$(state_file "${job}")"
  [ -r "${f}" ] || return 1
  cat "${f}"
}

state_field() {
  local job="$1" field="$2" f
  f="$(state_file "${job}")"
  [ -r "${f}" ] || {
    printf ''
    return 0
  }
  if have jq; then
    jq -r --arg f "${field}" '.[$f] // empty' "${f}" 2>/dev/null || true
  else
    # Deliberately narrow fallback: enough for `status` to work on a rescue
    # system without jq, and not pretending to be a JSON parser.
    sed -n "s/.*\"${field}\":\"\\([^\"]*\\)\".*/\\1/p;s/.*\"${field}\":\\([0-9.]*\\).*/\\1/p" "${f}" \
      | head -n1
  fi
}

# state_age_hours <job> - hours since the job last ENDED SUCCESSFULLY.
# Deliberately based on the last success, not the last attempt: a job failing
# every hour must not look fresh.
state_age_hours() {
  local job="$1" ended status
  status="$(state_field "${job}" status)"
  case "${status}" in
    ok | partial) : ;;
    *) # fall through to the recorded success timestamp, if any
      ended="$(state_field "${job}" last_success_epoch)"
      ;;
  esac
  [ -z "${ended:-}" ] && ended="$(state_field "${job}" ended_epoch)"
  [ -z "${ended}" ] && {
    printf ''
    return 0
  }
  awk -v a="$(now_epoch)" -v b="${ended}" 'BEGIN{printf "%.1f", (a-b)/3600}'
}

state_sla_ok() {
  local job="$1" max="$2" age
  age="$(state_age_hours "${job}")"
  [ -z "${age}" ] && return 1
  awk -v a="${age}" -v m="${max}" 'BEGIN{exit !(a <= m)}'
}

# state_reset_run_counters - called at the start of every job.
state_reset_run_counters() {
  BGB_RUN_FILES_NEW=0
  BGB_RUN_FILES_CHANGED=0
  BGB_RUN_FILES_UNMODIFIED=0
  BGB_RUN_FILES_UNREADABLE=0
  BGB_RUN_BYTES_ADDED=0
  BGB_RUN_BYTES_PROCESSED=0
  BGB_RUN_QUIESCE_SECONDS=0
  BGB_RUN_DB_DUMPS=0
  BGB_RUN_DB_DUMPS_FAILED=0
  BGB_RUN_DEGRADED_REASON=""
}
