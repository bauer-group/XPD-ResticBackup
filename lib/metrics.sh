#!/usr/bin/env bash
# =============================================================================
# bg-backup - metrics: the Prometheus node_exporter textfile
# =============================================================================
# Writes BGB_METRICS_TEXTFILE, normally
#   /var/lib/node_exporter/textfile_collector/bg-backup.prom
#
# FIVE decisions in this file are load-bearing. All of them are the kind of
# mistake that produces a dashboard which looks fine and is wrong.
#
# 1. ATOMIC WRITE. node_exporter re-reads every *.prom in that directory on
#    EVERY scrape. A half-written file is not a partial result - the collector
#    fails to parse the whole file and reports node_textfile_scrape_error=1,
#    dropping every series in it. atomic_write() renders into a sibling temp
#    file and rename()s it into place, which is atomic on any POSIX filesystem.
#    The temp name deliberately does not end in .prom, so the collector ignores
#    it even in the window before the rename.
#
# 2. UNDERSCORES, NOT DASHES. Prometheus metric names match
#    [a-zA-Z_:][a-zA-Z0-9_:]* - `bg-backup_...` is not a valid name and poisons
#    the entire file. Hence the prefix bg_backup_ for a tool called bg-backup.
#
# 3. EVERYTHING IS A GAUGE. These are per-run values, not monotonic counters.
#    Typing bg_backup_bytes_added as a counter would make rate() and increase()
#    treat every run boundary as a counter reset and invent traffic that never
#    happened. "It only goes up" is not what counter means; "it never goes down
#    except by restarting" is, and a per-run value does neither.
#
# 4. THE WHOLE FILE IS REGENERATED FROM PERSISTED STATE, for every job, on every
#    write. Appending the current job's series would leave a removed job's
#    series in the file forever - a job deleted from conf.d would keep alerting
#    as "stale" until somebody deleted the .prom by hand. Rendering from
#    config_list_jobs() makes removal self-healing.
#
# 5. THE FILE IS WORLD-READABLE (0644) AND CONTAINS NO SECRET. node_exporter
#    runs unprivileged; a 0600 file is silently never scraped, which presents as
#    "the metrics just are not there" with nothing in any log. That is only safe
#    because the `repo` label carries repo_prefix() - the last path component -
#    and never RESTIC_REPOSITORY, which can embed an access key.
# =============================================================================

[ -n "${_BGB_METRICS_SOURCED:-}" ] && return 0
_BGB_METRICS_SOURCED=1

readonly BGB_METRIC_PREFIX="bg_backup_"

# Repository-wide series need a `job` label like everything else. "_repo" is
# reserved: config_list_jobs() derives job names from conf.d file names, which
# cannot start with an underscore after the numeric prefix is stripped.
readonly BGB_METRIC_REPO_JOB="_repo"

# `declare -gA`, not `declare -A`. lib_source() is called from dispatch(), which
# is a function, and `declare` inside a function body creates a FUNCTION-LOCAL
# variable even when the file was merely sourced there. Without -g this array
# would quietly cease to exist the moment dispatch() returned, and the failure
# would look like "metrics are empty on some code paths but not others".
declare -gA _BGB_M=()
_BGB_MJOBS=()
_BGB_MHOST=""
_BGB_MREPO=""
_BGB_MREPO_LABELS=""
_BGB_MRESTIC_VERSION=""

# -----------------------------------------------------------------------------
# Formatting primitives
# -----------------------------------------------------------------------------

metrics_enabled() { [ -n "${BGB_METRICS_TEXTFILE:-}" ]; }

# metrics_escape_label <value> - Prometheus label values escape backslash,
# double quote and newline, and nothing else.
metrics_escape_label() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "${s}"
}

# metrics_escape_help <text> - HELP escapes backslash and newline only.
metrics_escape_help() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

# _metrics_num <value> - echo the value only when it is a usable sample value.
# Returns 1 otherwise, and the caller then emits NOTHING for that series.
#
# Emitting a placeholder 0 would be actively harmful: a repository whose size we
# failed to measure would report 0 bytes, and "backup repository shrank to zero"
# is an alert somebody will act on at 4am.
_metrics_num() {
  local v="${1:-}"
  case "${v}" in
    '' | null | *[!0-9.eE+-]*) return 1 ;;
    *)
      printf '%s' "${v}"
      return 0
      ;;
  esac
}

# _metrics_epoch <iso-8601-or-epoch> - normalise to epoch seconds.
_metrics_epoch() {
  local t="${1:-}" e
  [ -n "${t}" ] && [ "${t}" != "null" ] || return 1
  case "${t}" in
    *[!0-9]*)
      e="$(date -u -d "${t}" '+%s' 2>/dev/null || true)"
      [ -n "${e}" ] || return 1
      printf '%s' "${e}"
      ;;
    *) printf '%s' "${t}" ;;
  esac
}

# _metrics_age_days <epoch>
_metrics_age_days() {
  local then="${1:-}"
  _metrics_num "${then}" >/dev/null || return 1
  awk -v a="$(now_epoch)" -v b="${then}" 'BEGIN{ d=(a-b)/86400; if (d<0) d=0; printf "%.4f", d }'
}

# _metrics_family <name> <help> <type> <samples-block>
# Emits nothing when the block is empty. A family header with no samples is
# legal but useless, and an empty file is easier to diagnose than a file full of
# lonely HELP lines.
_metrics_family() {
  local name="${1:-}" help="${2:-}" type="${3:-gauge}" block="${4:-}"
  [ -n "${block}" ] || return 0
  printf '# HELP %s %s\n' "${name}" "$(metrics_escape_help "${help}")"
  printf '# TYPE %s %s\n' "${name}" "${type}"
  # Normalise the terminator here rather than trusting every caller. Blocks
  # assembled with $(...) have had their trailing newline eaten by command
  # substitution, and a sample line without a newline glues itself onto the next
  # family's HELP line - which the collector then rejects, taking the whole file
  # with it.
  case "${block}" in
    *$'\n') printf '%s' "${block}" ;;
    *) printf '%s\n' "${block}" ;;
  esac
}

# -----------------------------------------------------------------------------
# State loading
# -----------------------------------------------------------------------------

_m() { printf '%s' "${_BGB_M["${1}|${2}"]:-}"; }

_m_set() { _BGB_M["${1}|${2}"]="${3}"; }

# _metrics_labels <job> - the label set every per-job series carries.
_metrics_labels() {
  local job="${1:-}" repo
  repo="$(_m "${job}" repo_prefix)"
  if [ -z "${repo}" ] || [ "${repo}" = "null" ]; then repo="${_BGB_MREPO}"; fi
  printf 'host="%s",job="%s",repo="%s"' \
    "$(metrics_escape_label "${_BGB_MHOST}")" \
    "$(metrics_escape_label "${job}")" \
    "$(metrics_escape_label "${repo}")"
}

_metrics_job_list() {
  local job f
  _BGB_MJOBS=()

  # config_list_jobs() is authoritative: it reflects what is configured NOW.
  if declare -F config_list_jobs >/dev/null 2>&1; then
    while IFS= read -r job; do
      if [ -n "${job}" ]; then _BGB_MJOBS+=("${job}"); fi
    done < <(config_list_jobs 2>/dev/null || true)
  fi

  # Fallback for contexts without config.sh (the systemd `internal` entry
  # point). Leading-underscore files are repository-wide state, not jobs.
  if [ "${#_BGB_MJOBS[@]}" -eq 0 ]; then
    for f in "${BGB_STATE_DIR}"/*.json; do
      [ -e "${f}" ] || continue
      job="$(basename "${f}" .json)"
      case "${job}" in _*) continue ;; esac
      _BGB_MJOBS+=("${job}")
    done
  fi
  return 0
}

# _metrics_load_job <job> - pull the whole state document into _BGB_M.
# One jq invocation per job rather than one per field: with a dozen fields and a
# handful of jobs that is the difference between 3 forks and 40.
_metrics_load_job() {
  local job="${1:-}" f k v
  f="$(state_file "${job}")"
  [ -r "${f}" ] || return 0

  if have jq; then
    # gsub() flattens embedded newlines and tabs: degraded_reason can carry a
    # hook's multi-line error message, and a raw newline here would be read back
    # as a new key=value pair by the loop below.
    while IFS=$'\t' read -r k v; do
      [ -n "${k}" ] || continue
      _m_set "${job}" "${k}" "${v}"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value|tostring|gsub("[\n\r\t]";" "))"' "${f}" 2>/dev/null || true)
  else
    for k in status rc run_id snapshot_id started_epoch ended_epoch \
      duration_seconds files_new files_changed files_unmodified \
      files_unreadable bytes_added bytes_processed quiesce_seconds \
      db_dumps db_dumps_failed degraded_reason repo_prefix; do
      _m_set "${job}" "${k}" "$(state_field "${job}" "${k}")"
    done
  fi
  return 0
}

# _metrics_derive_job <job> - the values that are computed rather than stored.
_metrics_derive_job() {
  local job="${1:-}" status ls side dt reason

  status="$(_m "${job}" status)"

  # run_success: `partial` counts as a success on purpose. A snapshot exists and
  # is restorable; the unreadable files are reported separately by
  # bg_backup_files_unreadable and by bg_backup_run_exit_code, which is where an
  # alert on persistent partials belongs. Folding partial into 0 here would make
  # every server with an open socket in a backed-up path look like it has no
  # backup at all.
  case "${status}" in
    ok | partial) _m_set "${job}" _success 1 ;;
    '') : ;;
    *) _m_set "${job}" _success 0 ;;
  esac

  # last_success: preferred from the state document (if the state module ever
  # records it), then from our own sidecar, then from this run when it succeeded.
  # The sidecar exists because the state document is overwritten by every run:
  # without it, one failure would erase the timestamp that BackupStale needs,
  # and the alert would flip from "stale" to "absent" exactly when it matters.
  side="${BGB_STATE_DIR}/${job}.lastsuccess"
  ls="$(_m "${job}" last_success_epoch)"
  if [ -z "${ls}" ] || [ "${ls}" = "null" ]; then
    case "${status}" in
      ok | partial) ls="$(_m "${job}" ended_epoch)" ;;
      *) ls="" ;;
    esac
  fi
  if _metrics_num "${ls}" >/dev/null; then
    printf '%s\n' "${ls}" >"${side}" 2>/dev/null || true
    chmod 0640 "${side}" 2>/dev/null || true
  else
    ls="$(cat "${side}" 2>/dev/null || true)"
  fi
  _m_set "${job}" _last_success "${ls}"

  # degraded_targets: an explicit count if a module recorded one, otherwise
  # derived from the reason string so the series still means something.
  dt="$(_m "${job}" degraded_targets)"
  if ! _metrics_num "${dt}" >/dev/null; then
    reason="$(_m "${job}" degraded_reason)"
    if [ -n "${reason}" ] && [ "${reason}" != "null" ]; then dt=1; else dt=0; fi
  fi
  _m_set "${job}" _degraded_targets "${dt}"

  _m_set "${job}" _labels "$(_metrics_labels "${job}")"
  return 0
}

_metrics_load() {
  local job
  # unset + re-declare rather than `_BGB_M=()`: clearing an associative array by
  # assigning an empty compound has been subtly version-dependent, and -g here
  # keeps it global even though _metrics_load runs inside a function.
  unset _BGB_M
  declare -gA _BGB_M=()
  _BGB_MHOST="${BGB_HOSTNAME:-$(fqdn)}"

  _BGB_MREPO=""
  if declare -F repo_prefix >/dev/null 2>&1; then
    _BGB_MREPO="$(repo_prefix)"
  fi

  _BGB_MRESTIC_VERSION=""
  if declare -F restic_version >/dev/null 2>&1 && [ -x "${BGB_RESTIC_BIN:-}" ]; then
    _BGB_MRESTIC_VERSION="$(restic_version 2>/dev/null || true)"
  fi

  _metrics_job_list
  for job in "${_BGB_MJOBS[@]:-}"; do
    [ -n "${job}" ] || continue
    _metrics_load_job "${job}"
    _metrics_derive_job "${job}"
  done

  _BGB_MREPO_LABELS="$(printf 'host="%s",job="%s",repo="%s"' \
    "$(metrics_escape_label "${_BGB_MHOST}")" \
    "$(metrics_escape_label "${BGB_METRIC_REPO_JOB}")" \
    "$(metrics_escape_label "${_BGB_MREPO}")")"
  return 0
}

# -----------------------------------------------------------------------------
# Repository-wide facts
# -----------------------------------------------------------------------------
# These come from _repo.json, written by check/verify/prune/copy through
# state_touch(). metrics_record() is the setter those modules call.

# metrics_record <key> <value>
metrics_record() {
  declare -F state_touch >/dev/null 2>&1 || return 0
  state_touch "${1}" "${2}"
}

_metrics_repo_get() {
  declare -F state_get_repo >/dev/null 2>&1 || return 0
  state_get_repo "${1}" 2>/dev/null || true
}

# _metrics_bundle_epoch - when the recovery bundle was last produced.
# The file's mtime beats any recorded timestamp: the bundle either exists on
# disk or it does not, and a state entry saying otherwise is exactly the lie
# this metric is meant to catch.
_metrics_bundle_epoch() {
  local f="${BGB_ESCROW_LOCAL:-}" e
  if [ -n "${f}" ] && [ -f "${f}" ]; then
    e="$(stat -c %Y "${f}" 2>/dev/null || true)"
    if _metrics_num "${e}" >/dev/null; then
      printf '%s' "${e}"
      return 0
    fi
  fi
  _metrics_epoch "$(_metrics_repo_get config_export_last)"
}

# _metrics_export_stale - 1 when the recovery bundle no longer matches the host.
#
# Age alone is the weaker signal. The failure that actually strands an operator
# is an exported bundle that predates a configuration change: the repository URL
# or the key in the bundle is not the one this host now uses, so the bundle
# restores the wrong repository - or nothing.
_metrics_export_stale() {
  local f="${BGB_ESCROW_LOCAL:-}" newer age max
  [ -n "${f}" ] || return 1
  if [ ! -f "${f}" ]; then
    printf '1'
    return 0
  fi

  if [ -d "${BGB_CONFDIR:-}" ]; then
    newer="$(find "${BGB_CONFDIR}" -type f -newer "${f}" -print -quit 2>/dev/null || true)"
    if [ -n "${newer}" ]; then
      printf '1'
      return 0
    fi
  fi

  age="$(_metrics_age_days "$(_metrics_bundle_epoch || true)" 2>/dev/null || true)"
  max="${BGB_ESCROW_MAX_AGE_DAYS:-90}"
  if [ -n "${age}" ] && awk -v a="${age}" -v m="${max}" 'BEGIN{exit !(a > m)}'; then
    printf '1'
    return 0
  fi
  printf '0'
}

# -----------------------------------------------------------------------------
# Rendering
# -----------------------------------------------------------------------------

# _metrics_job_gauge <suffix> <help> <state-field>
# One family, one sample per job that has a usable value.
_metrics_job_gauge() {
  local suffix="${1:-}" help="${2:-}" field="${3:-}"
  local name="${BGB_METRIC_PREFIX}${suffix}"
  local job v block=""
  for job in "${_BGB_MJOBS[@]:-}"; do
    [ -n "${job}" ] || continue
    v="$(_m "${job}" "${field}")"
    _metrics_num "${v}" >/dev/null || continue
    block="${block}${name}{$(_m "${job}" _labels)} ${v}"$'\n'
  done
  _metrics_family "${name}" "${help}" gauge "${block}"
}

# _metrics_repo_gauge <suffix> <help> <value>
_metrics_repo_gauge() {
  local suffix="${1:-}" help="${2:-}" value="${3:-}"
  local name="${BGB_METRIC_PREFIX}${suffix}"
  _metrics_num "${value}" >/dev/null || return 0
  _metrics_family "${name}" "${help}" gauge "${name}{${_BGB_MREPO_LABELS}} ${value}"$'\n'
}

_metrics_render() {
  local job block v

  # --- identity ---------------------------------------------------------------
  _metrics_family "${BGB_METRIC_PREFIX}build_info" \
    'Build information for bg-backup and the restic binary it drives. Always 1; read the labels.' \
    gauge \
    "$(printf '%sbuild_info{%s,version="%s",restic_version="%s"} 1\n' \
      "${BGB_METRIC_PREFIX}" "${_BGB_MREPO_LABELS}" \
      "$(metrics_escape_label "${BGB_VERSION:-unknown}")" \
      "$(metrics_escape_label "${_BGB_MRESTIC_VERSION:-unknown}")")"

  # --- run outcome ------------------------------------------------------------
  _metrics_job_gauge last_run_timestamp_seconds \
    'Unix timestamp at which the last run of this job ended, successful or not.' ended_epoch

  _metrics_job_gauge last_success_timestamp_seconds \
    'Unix timestamp of the last run that produced a usable snapshot. This is the series a stale-backup alert must use.' \
    _last_success

  _metrics_job_gauge run_exit_code \
    'Exit code of the last run. 0 ok, 3 partial (snapshot created, some files unreadable), see docs/monitoring.md for the full table.' \
    rc

  _metrics_job_gauge run_success \
    'Whether the last run produced a usable snapshot: 1 for ok and partial, 0 for failed and degraded.' \
    _success

  _metrics_job_gauge run_duration_seconds \
    'Wall-clock duration of the last run in seconds.' duration_seconds

  _metrics_job_gauge quiesce_duration_seconds \
    'Seconds the last run held services paused or stopped. This is the number an application owner cares about.' \
    quiesce_seconds

  # --- what the run moved -----------------------------------------------------
  _metrics_job_gauge files_new 'Files new in the last snapshot.' files_new
  _metrics_job_gauge files_changed 'Files changed since the previous snapshot.' files_changed
  _metrics_job_gauge files_unmodified 'Files unchanged since the previous snapshot.' files_unmodified
  _metrics_job_gauge files_unreadable 'Files that could not be read during the last run (restic exit 3).' files_unreadable
  _metrics_job_gauge bytes_processed 'Bytes read from the source during the last run.' bytes_processed
  _metrics_job_gauge bytes_added 'Bytes actually written to the repository after deduplication and compression.' bytes_added

  # --- snapshot identity ------------------------------------------------------
  block=""
  for job in "${_BGB_MJOBS[@]:-}"; do
    [ -n "${job}" ] || continue
    v="$(_m "${job}" snapshot_id)"
    [ -n "${v}" ] && [ "${v}" != "null" ] || continue
    block="${block}$(printf '%ssnapshot_info{%s,snapshot_id="%s"} 1\n' \
      "${BGB_METRIC_PREFIX}" "$(_m "${job}" _labels)" "$(metrics_escape_label "${v}")")"$'\n'
  done
  _metrics_family "${BGB_METRIC_PREFIX}snapshot_info" \
    'The snapshot produced by the last run. Always 1; the snapshot id is a label so an alert can quote it.' \
    gauge "${block}"

  # --- databases --------------------------------------------------------------
  _metrics_job_gauge db_dumps \
    'Database dumps streamed into the repository by the last run.' db_dumps
  _metrics_job_gauge db_dumps_failed \
    'Database dumps that failed during the last run. Any value above 0 means a database is not in the snapshot.' \
    db_dumps_failed

  _metrics_job_gauge degraded_targets \
    'Targets (containers, volumes, paths) the last run skipped or could not reach.' _degraded_targets

  # --- repository health ------------------------------------------------------
  _metrics_repo_gauge check_last_run_timestamp_seconds \
    'Unix timestamp of the last repository integrity check.' \
    "$(_metrics_epoch "$(_metrics_repo_get check_last_run)" 2>/dev/null || true)"

  v="$(_metrics_repo_get check_status)"
  case "${v}" in
    ok) v=1 ;;
    failed) v=0 ;;
    *) v="" ;;
  esac
  _metrics_repo_gauge check_success \
    'Whether the last repository integrity check passed.' "${v}"

  _metrics_repo_gauge verify_last_success_timestamp_seconds \
    'Unix timestamp of the last successful proven-restore test.' \
    "$(_metrics_epoch "$(_metrics_repo_get verify_last_success)" 2>/dev/null || true)"

  _metrics_repo_gauge repo_size_bytes \
    'Size of the repository as last measured by restic stats --mode raw-data.' \
    "$(_metrics_repo_get repo_size_bytes)"

  _metrics_repo_gauge repo_fully_verified_age_days \
    'Days since the repository was last verified end to end (check --read-data over 100 percent). A repository nobody has ever fully read is a repository nobody has ever tested.' \
    "$(_metrics_age_days "$(_metrics_epoch "$(_metrics_repo_get full_verified_last)" 2>/dev/null || true)" 2>/dev/null || true)"

  # --- snapshot inventory -----------------------------------------------------
  # Recorded by `check`/`status`, which already hold the snapshot list. This file
  # never calls restic itself: metrics are written at the end of every run and a
  # network round trip there would charge every backup for a dashboard.
  block=""
  v="$(_metrics_repo_get snapshots_total)"
  if _metrics_num "${v}" >/dev/null; then
    block="${block}$(printf '%srepo_snapshots_total{%s,tag="all"} %s\n' \
      "${BGB_METRIC_PREFIX}" "${_BGB_MREPO_LABELS}" "${v}")"$'\n'
  fi
  for job in "${_BGB_MJOBS[@]:-}"; do
    [ -n "${job}" ] || continue
    v="$(_metrics_repo_get "snapshots_job_${job}")"
    _metrics_num "${v}" >/dev/null || continue
    block="${block}$(printf '%srepo_snapshots_total{%s,tag="job=%s"} %s\n' \
      "${BGB_METRIC_PREFIX}" "$(_m "${job}" _labels)" "$(metrics_escape_label "${job}")" "${v}")"$'\n'
  done
  _metrics_family "${BGB_METRIC_PREFIX}repo_snapshots_total" \
    'Snapshots in the repository, by tag. tag="all" is every snapshot this host can see, including other hosts sharing the bucket.' \
    gauge "${block}"

  # --- recovery bundle --------------------------------------------------------
  _metrics_repo_gauge recovery_bundle_age_days \
    'Days since the encrypted recovery bundle (config export) was last written. Without it the repository is unreadable no matter how healthy it is.' \
    "$(_metrics_age_days "$(_metrics_bundle_epoch || true)" 2>/dev/null || true)"

  _metrics_repo_gauge config_export_stale \
    'Whether the recovery bundle is out of date: 1 when a configuration file is newer than the bundle, or the bundle is older than BGB_ESCROW_MAX_AGE_DAYS.' \
    "$(_metrics_export_stale 2>/dev/null || true)"

  return 0
}

# -----------------------------------------------------------------------------
# Entry points
# -----------------------------------------------------------------------------

# metrics_write [job] - regenerate the textfile. The argument is accepted for
# call-site readability and used only for logging: the file always covers every
# job, see decision (4) in the header.
metrics_write() {
  local job="${1:-}" dir

  metrics_enabled || return 0

  if [ "${BGB_DRY_RUN:-0}" = "1" ]; then
    debug "metrics: [dry-run] would rewrite ${BGB_METRICS_TEXTFILE}"
    return 0
  fi

  dir="$(dirname "${BGB_METRICS_TEXTFILE}")"
  if [ ! -d "${dir}" ]; then
    # Do not create it. The directory belongs to node_exporter's packaging; if
    # it is missing, node_exporter is not configured for textfile collection and
    # creating it would produce a file nothing ever reads.
    warn "metrics: ${dir} does not exist - is node_exporter's textfile collector enabled?"
    return 0
  fi
  if [ ! -w "${dir}" ]; then
    warn "metrics: ${dir} is not writable - metrics not updated"
    return 0
  fi

  if ! declare -F state_file >/dev/null 2>&1; then
    lib_source state.sh
  fi

  _metrics_load
  if ! _metrics_render | atomic_write "${BGB_METRICS_TEXTFILE}" 0644; then
    warn "metrics: could not write ${BGB_METRICS_TEXTFILE}"
    return 0
  fi
  debug "metrics: wrote ${BGB_METRICS_TEXTFILE}${job:+ (triggered by job ${job})}"
  return 0
}

# metrics_render_stdout - the same document on stdout, for `doctor` and for
# eyeballing what the collector will see without touching the live file.
metrics_render_stdout() {
  if ! declare -F state_file >/dev/null 2>&1; then
    lib_source state.sh
  fi
  _metrics_load
  _metrics_render
}
