#!/usr/bin/env bash
# =============================================================================
# bg-backup - restic: argv construction, execution, exit-code mapping
# =============================================================================
# Everything that shells out to restic goes through here. Two rules are encoded
# in this file because both are easy to get wrong and both fail silently:
#
#   1. $? after a pipeline is the LAST element's status. `restic ... | tee` and
#      then checking $? reports tee's success and hides a failed backup.
#      PIPESTATUS[0] is mandatory.
#
#   2. restic 0.17+ distinguishes 10 (no repository), 11 (already locked) and
#      12 (wrong password) from the generic 1. Older builds collapse all of them
#      into 1, which makes alerts untriageable - hence the minimum version gate.
# =============================================================================

[ -n "${_BGB_RESTIC_SOURCED:-}" ] && return 0
_BGB_RESTIC_SOURCED=1

RESTIC_VERDICT=""

# -----------------------------------------------------------------------------
# Version gate
# -----------------------------------------------------------------------------
restic_version() {
  "${BGB_RESTIC_BIN}" version 2>/dev/null | awk '{print $2; exit}'
}

# version_ge <a> <b> - pure-bash semantic comparison, no sort -V dependency.
version_ge() {
  local a="$1" b="$2"
  local -a A B
  IFS='.' read -r -a A <<<"${a%%-*}"
  IFS='.' read -r -a B <<<"${b%%-*}"
  local i
  for i in 0 1 2; do
    local x="${A[i]:-0}" y="${B[i]:-0}"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    [ -z "${x}" ] && x=0
    [ -z "${y}" ] && y=0
    if [ "${x}" -gt "${y}" ]; then return 0; fi
    if [ "${x}" -lt "${y}" ]; then return 1; fi
  done
  return 0
}

restic_require() {
  [ -x "${BGB_RESTIC_BIN}" ] || die "${EX_PRECOND}" \
    "restic not found at ${BGB_RESTIC_BIN} (re-run the installer, or set BGB_RESTIC_BIN)"
  local v
  v="$(restic_version)"
  [ -n "${v}" ] || die "${EX_PRECOND}" "Could not determine the restic version"
  if ! version_ge "${v}" "${BGB_RESTIC_MIN_VERSION}"; then
    err "restic ${v} is older than the required ${BGB_RESTIC_MIN_VERSION}"
    err "Below ${BGB_RESTIC_MIN_VERSION}, exit codes 10/11/12 collapse into 1 and"
    err "--stdin-from-command may be unavailable, so a failed database dump can"
    err "be stored as a healthy snapshot. Distribution packages are too old:"
    err "  Ubuntu 22.04 ships 0.12.1, 24.04 ships 0.16.4."
    die "${EX_PRECOND}" "Install the upstream binary (the bg-backup installer does this)."
  fi
  debug "restic ${v} at ${BGB_RESTIC_BIN}"
}

# -----------------------------------------------------------------------------
# Exit-code mapping
# -----------------------------------------------------------------------------
restic_map_rc() {
  case "${1:-1}" in
    0)   RESTIC_VERDICT="ok";          return "${EX_OK}" ;;
    3)   RESTIC_VERDICT="partial";     return "${EX_PARTIAL}" ;;
    10)  RESTIC_VERDICT="no-repo";     return "${EX_REPO}" ;;
    11)  RESTIC_VERDICT="repo-locked"; return "${EX_REPO}" ;;
    12)  RESTIC_VERDICT="bad-key";     return "${EX_REPO}" ;;
    130|143) RESTIC_VERDICT="interrupted"; return "${EX_INTERRUPT}" ;;
    *)   RESTIC_VERDICT="failed";      return "${EX_FAIL}" ;;
  esac
}

restic_explain_rc() {
  case "${1}" in
    0)  printf 'success' ;;
    1)  printf 'fatal error' ;;
    3)  printf 'snapshot created, but some source files could not be read' ;;
    10) printf 'repository does not exist (has it been initialised?)' ;;
    11) printf 'repository is locked by another process (try: bg-backup unlock)' ;;
    12) printf 'wrong password / repository key' ;;
    # restic_map_rc already classified these as EX_INTERRUPT; without the text
    # here a cancelled run reported "unknown restic exit code 130", which reads
    # like a bug in restic. The common cause is not a human pressing Ctrl-C: it
    # is --stdin-from-command's dump process exiting non-zero, so restic cancels
    # the context and the REAL error is the line above this one in the log.
    130) printf 'interrupted (SIGINT, or a --stdin-from-command dump failed - see the error above)' ;;
    143) printf 'terminated (SIGTERM - timeout, RuntimeMaxSec or a stop request)' ;;
    *)  printf 'unknown restic exit code %s' "${1}" ;;
  esac
}

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------

# restic_exec <args...> - run restic, stream to stderr, return restic's status.
# _restic_restore_defaults <array-name> - add --sparse to a `restore` argv.
#
# Without it restic materialises every hole: the rehearsal's 1 GiB sparse file
# came back as 1 GiB of real blocks (apparent 1073741824, actual 1073745920).
# On a recovery host that is not cosmetic - a sparse database or VM image can
# exhaust the disk mid-restore, and the restore that fails is the one you are
# running because everything else already failed.
#
# Applied centrally rather than at each call site: there are eight of them
# across restore.sh and dr.sh, and one forgotten site is exactly how this
# survives. --sparse has existed since restic 0.14, well below the 0.17 floor,
# and is a no-op for files without holes.
_restic_restore_defaults() {
  local -n _bgb_argv="$1"
  [ "${_bgb_argv[0]:-}" = "restore" ] || return 0
  local x
  for x in "${_bgb_argv[@]}"; do
    [ "${x}" = "--sparse" ] && return 0
  done
  _bgb_argv+=(--sparse)
  return 0
}

restic_exec() {
  local rc=0
  local -a argv=("$@")
  _restic_restore_defaults argv
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] restic ${argv[*]}"
    return 0
  fi
  debug "restic ${argv[*]}"
  set +e
  "${BGB_RESTIC_BIN}" "${argv[@]}"
  rc=$?
  set -e
  return "${rc}"
}

# restic_exec_logged <logfile> <args...> - as above, mirrored into a log file.
restic_exec_logged() {
  local logfile="$1"; shift
  local rc=0
  local -a argv=("$@")
  _restic_restore_defaults argv
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] restic ${argv[*]}"
    return 0
  fi
  debug "restic ${argv[*]}"
  set +e
  "${BGB_RESTIC_BIN}" "${argv[@]}" 2>&1 | tee -a "${logfile}"
  rc="${PIPESTATUS[0]}"   # NOT $? - that is tee's status
  set -e
  return "${rc}"
}

# restic_capture <args...> - capture stdout, return restic's status.
restic_capture() {
  local out rc=0 ef line
  # stdout is DATA (usually JSON) and must stay clean, so restic's stderr is
  # kept apart. It used to be discarded outright - which meant "wrong password",
  # "repository does not exist" and "access denied" all arrived at the caller as
  # a bare non-zero status. Under `set -e` an assignment from here then aborted
  # the process with exit 1 and not one line of explanation. Diagnosing that
  # needed `bash -x`; nobody does that at 03:00.
  ef="$(mktemp "${TMPDIR:-/tmp}/bgb-restic-err.XXXXXX" 2>/dev/null)" || ef=""

  set +e
  if [ -n "${ef}" ]; then
    out="$("${BGB_RESTIC_BIN}" "$@" 2>"${ef}")"
  else
    out="$("${BGB_RESTIC_BIN}" "$@" 2>/dev/null)"
  fi
  rc=$?
  set -e

  printf '%s' "${out}"

  # Only on failure: a probe like restic_is_locked() is expected to fail and
  # callers that genuinely want silence already redirect. err() routes through
  # _bgb_emit, so this is redacted like everything else - a repository URL can
  # carry credentials.
  if [ "${rc}" -ne 0 ] && [ -n "${ef}" ] && [ -s "${ef}" ]; then
    while IFS= read -r line; do
      [ -n "${line}" ] && err "restic: ${line}"
    done <"${ef}"
  fi
  [ -n "${ef}" ] && rm -f "${ef}"
  return "${rc}"
}

# restic_retry <args...> - retry only transient repository failures.
# Deliberately does NOT retry exit 12 (wrong password) or 10 (no repository):
# those never become true by trying again, and retrying makes the real error
# scroll off the top of the log.
restic_retry() {
  local n=1 rc=0
  while :; do
    rc=0
    restic_exec "$@" || rc=$?
    case "${rc}" in
      0|3|10|12) return "${rc}" ;;
    esac
    if [ "${n}" -ge "${BGB_RETRY_ATTEMPTS:-3}" ]; then return "${rc}"; fi
    warn "restic failed (rc=${rc}: $(restic_explain_rc "${rc}")), attempt ${n}/${BGB_RETRY_ATTEMPTS}"
    sleep "${BGB_RETRY_DELAY_SECONDS:-60}"
    n=$(( n + 1 ))
  done
}

# -----------------------------------------------------------------------------
# argv construction
# -----------------------------------------------------------------------------

# restic_global_args - options that apply to every restic invocation.
# Emits one argument per line so the caller can mapfile them into an array
# without word-splitting paths that contain spaces.
restic_global_args() {
  if [ -n "${BGB_PACK_SIZE_MIB:-}" ]; then
    printf -- '--pack-size\n%s\n' "${BGB_PACK_SIZE_MIB}"
  fi
  if [ "${BGB_LIMIT_UPLOAD_KIB:-0}" != "0" ]; then
    printf -- '--limit-upload\n%s\n' "${BGB_LIMIT_UPLOAD_KIB}"
  fi
  if [ "${BGB_LIMIT_DOWNLOAD_KIB:-0}" != "0" ]; then
    printf -- '--limit-download\n%s\n' "${BGB_LIMIT_DOWNLOAD_KIB}"
  fi
  if [ -n "${BGB_READ_CONCURRENCY:-}" ]; then
    printf -- '--read-concurrency\n%s\n' "${BGB_READ_CONCURRENCY}"
  fi
  return 0
}

# restic_tag_args <job> <run-id> [extra-tags...]
# Every snapshot carries the same four identity tags. They are what makes
# `forget --host --tag job=` safe in a shared bucket and what lets `runs` group
# the several snapshots a single run produces.
restic_tag_args() {
  local job="$1" run_id="$2"; shift 2
  printf -- '--tag\nbg-backup=1\n'
  printf -- '--tag\njob=%s\n' "${job}"
  [ -n "${run_id}" ] && printf -- '--tag\nrun=%s\n' "${run_id}"
  local t
  for t in "$@"; do
    [ -n "${t}" ] && printf -- '--tag\n%s\n' "${t}"
  done
  return 0
}

# restic_tag_filter_args <term...> - a SELECTOR over tags, with AND semantics.
#
# restic's --tag is an OR over tag LISTS, and a list is one comma-separated
# --tag argument. So `--tag a --tag b` means "a OR b", while `--tag a,b` means
# "a AND b". Measured against restic 0.19.1 rather than remembered, on a
# snapshot tagged job=e2e but NOT kind=files:
#
#   --tag job=e2e --tag kind=files   -> 1 hit   (OR: matched on job= alone)
#   --tag job=e2e,kind=files         -> 0 hits  (AND: correct)
#
# Every selector in this tool means AND - "the files snapshot OF THIS RUN",
# never "anything that is either". Read the OR form as a silent bug: it does not
# fail, it returns the WRONG snapshot, and a restore then writes the wrong data.
#
# Writing tags is the opposite case: `restic backup --tag a --tag b` correctly
# assigns both. That path is restic_tag_args() and must keep repeating --tag.
restic_tag_filter_args() {
  local joined="" t
  for t in "$@"; do
    [ -n "${t}" ] || continue
    if [ -z "${joined}" ]; then joined="${t}"; else joined="${joined},${t}"; fi
  done
  [ -n "${joined}" ] && printf -- '--tag\n%s\n' "${joined}"
  return 0
}

# restic_build_backup_args <job> <run-id>
# Emits the complete argv for `restic backup`, one entry per line.
# NOTE: no secret ever appears here. The passphrase reaches restic through
# RESTIC_PASSWORD_FILE, and the S3 secret through the environment - never as an
# argument, because /proc/<pid>/cmdline is world-readable while
# /proc/<pid>/environ is not.
restic_build_backup_args() {
  local job="$1" run_id="$2"
  local p e

  printf 'backup\n'
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--json\n'

  restic_tag_args "${job}" "${run_id}" "${JOB_TAGS[@]:-}"

  # kind=files is what makes this snapshot FINDABLE. restore, `runs diff`, the
  # DR planner and - most importantly - the printed recovery sheet all select on
  # kind=, and the docker path already tags its file snapshot this way. Without
  # it a files-mode snapshot is written correctly and can never be selected
  # again by name, which is the failure mode a backup tool must not have.
  printf -- '--tag\nkind=files\n'

  [ "${JOB_ONE_FILE_SYSTEM:-0}" = "1" ] && printf -- '--one-file-system\n'
  [ "${JOB_EXCLUDE_CACHES:-0}" = "1" ]  && printf -- '--exclude-caches\n'

  if [ -n "${JOB_EXCLUDE_FILE}" ] && [ -r "${JOB_EXCLUDE_FILE}" ]; then
    printf -- '--exclude-file\n%s\n' "${JOB_EXCLUDE_FILE}"
  fi
  for e in "${JOB_EXCLUDES[@]:-}"; do
    [ -n "${e}" ] && printf -- '--exclude\n%s\n' "${e}"
  done
  [ -n "${JOB_EXCLUDE_LARGER_THAN}" ] && printf -- '--exclude-larger-than\n%s\n' "${JOB_EXCLUDE_LARGER_THAN}"
  [ -n "${JOB_EXCLUDE_IF_PRESENT}" ]  && printf -- '--exclude-if-present\n%s\n' "${JOB_EXCLUDE_IF_PRESENT}"

  for p in "${JOB_PATHS[@]:-}" "${JOB_EXTRA_PATHS[@]:-}"; do
    [ -n "${p}" ] && printf '%s\n' "${p}"
  done
  return 0
}

# restic_snapshots_json [extra restic args...]
restic_snapshots_json() {
  require_jq
  restic_capture snapshots --json "$@"
}

# restic_latest_snapshot <job> [tag]
restic_latest_snapshot() {
  local job="$1" tag="${2:-}"
  require_jq
  local -a args=(snapshots --json --host "${BGB_HOSTNAME}")
  mapfile -t -O "${#args[@]}" args < <(restic_tag_filter_args "job=${job}" "${tag}")
  restic_capture "${args[@]}" | jq -r 'sort_by(.time) | last | .short_id // empty'
}

# restic_snapshot_age_hours <snapshot-time-iso>
restic_snapshot_age_hours() {
  # `then` is a shell keyword: using it as a variable name parses today but is
  # fragile and makes the surrounding `local` ambiguous to readers and linters.
  local t="$1" snap_epoch now
  [ -n "${t}" ] || { printf ''; return 0; }
  snap_epoch="$(date -u -d "${t}" '+%s' 2>/dev/null || echo 0)"
  [ "${snap_epoch}" = "0" ] && { printf ''; return 0; }
  now="$(now_epoch)"
  awk -v a="${now}" -v b="${snap_epoch}" 'BEGIN{printf "%.1f", (a-b)/3600}'
}

# -----------------------------------------------------------------------------
# Repository state
# -----------------------------------------------------------------------------

# restic_repo_reachable - true when the repository answers and the key works.
# `cat config` is the cheapest call that proves all three of network, existence
# and decryption.
restic_repo_reachable() {
  restic_exec cat config >/dev/null 2>&1
}

restic_repo_id() {
  require_jq
  restic_capture cat config | jq -r '.id // empty' 2>/dev/null || true
}

restic_is_locked() {
  local out
  out="$(restic_capture list locks 2>/dev/null || true)"
  [ -n "${out}" ]
}

# restic_init_if_needed - never re-initialises an existing repository.
restic_init_if_needed() {
  if restic_repo_reachable; then
    log "Repository already initialised"
    return 0
  fi
  local rc=0
  restic_exec cat config >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    12)
      die "${EX_REPO}" "The repository exists but the key is wrong - refusing to touch it." ;;
  esac
  log "Initialising repository"
  restic_exec init || die "${EX_REPO}" "restic init failed"
  log "Repository initialised"
}
