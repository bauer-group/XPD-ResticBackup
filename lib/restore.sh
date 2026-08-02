#!/usr/bin/env bash
# =============================================================================
# bg-backup - restore: staged by default, swapped atomically, reversible
# =============================================================================
# Every restore stages first and swaps second:
#
#   1. restore into /var/lib/bg-backup/restore/<token>/
#   2. verify what was written
#   3. mv <dest> <dest>.bgbk-old-<ts>  ;  mv <staged> <dest>
#
# Within one filesystem the swap is a rename: atomic, instant, and reversible
# with `restore rollback` until the old copy is dropped. Across filesystems it
# degrades to a copy, needs double the space and is not atomic - so we say so
# rather than pretending otherwise.
#
# Named volumes are swapped at .../volumes/<name>/_data rather than by renaming
# the Docker volume, which is not supported: the volume object, its driver and
# its labels stay untouched and only the contents change.
# =============================================================================

[ -n "${_BGB_RESTORE_SOURCED:-}" ] && return 0
_BGB_RESTORE_SOURCED=1

: "${BGB_RESTORE_ROOT:=/var/lib/bg-backup/restore}"

# -----------------------------------------------------------------------------
# Safety classification
# -----------------------------------------------------------------------------
restore_unsafe_list() { printf '%s/dr/unsafe-restore.list' "${BGB_SHARE_DIR}"; }

# restore_classify <path> -> AUTO | STAGED | NEVER
restore_classify() {
  local path="$1" f class glob
  f="$(restore_unsafe_list)"
  [ -r "${f}" ] || { printf 'AUTO'; return 0; }

  # NEVER wins over STAGED regardless of file order.
  local result="AUTO"
  while read -r class glob; do
    case "${class}" in ''|\#*) continue ;; esac
    [ -n "${glob}" ] || continue
    # Unquoted on purpose: the right-hand side is a glob and matching it as a
    # pattern is the entire function.
    # shellcheck disable=SC2053
    if [[ "${path}" == ${glob} ]]; then
      case "${class}" in
        NEVER)  printf 'NEVER'; return 0 ;;
        STAGED) result="STAGED" ;;
      esac
    fi
  done <"${f}"
  printf '%s' "${result}"
}

# restore_is_dpkg_conffile_modified <path>
# The self-maintaining half of the classification: a config file the newly
# installed package ships differently must not be silently overwritten with the
# old host's version, or the package's own upgrade path is defeated.
restore_is_dpkg_conffile_modified() {
  local path="$1" line want got
  have dpkg-query || return 1
  grep -qFx -- "${path}" /var/lib/dpkg/info/*.conffiles 2>/dev/null || return 1
  want="$(grep -h " ${path#/}\$" /var/lib/dpkg/info/*.md5sums 2>/dev/null | awk '{print $1}' | head -n1)"
  [ -n "${want}" ] || return 1
  [ -r "${path}" ] || return 1
  got="$(md5sum "${path}" 2>/dev/null | awk '{print $1}')"
  [ "${want}" != "${got}" ]
}

# -----------------------------------------------------------------------------
# Snapshot selection
# -----------------------------------------------------------------------------
# restore_resolve <selector-kind> <value> <job> <kind>
# _restore_snapshots_json <host|""> <job> <run> <kind> [path]
_restore_snapshots_json() {
  local host="$1" job="$2" run="$3" kind="$4" path="${5:-}"
  # AND, not OR. Repeated --tag flags would match a snapshot carrying ANY of
  # these, so `restore dir --job web` could resolve to the database dump of an
  # unrelated job and restore its bytes over a directory. See
  # restic_tag_filter_args() for the measurement behind this.
  local -a args=(snapshots --json)
  [ -n "${host}" ] && args+=(--host "${host}")
  # Every database dump is its OWN single-file snapshot, all of them tagged
  # kind=dbdump. Selecting on the tag alone therefore returns whichever engine
  # happened to be dumped LAST, and `restic dump` then fails with
  #     path "/db/postgres" not found in snapshot
  # `restore db --db postgres/<c>/app.dump` could only ever work for the final
  # dump of the run. The requested path has to be part of the selector.
  [ -n "${path}" ] && args+=(--path "${path}")
  mapfile -t -O "${#args[@]}" args < <(restic_tag_filter_args \
    "${job:+job=${job}}" "${run:+run=${run}}" "${kind:+kind=${kind}}")
  restic_capture "${args[@]}"
}

# restore_resolve_snapshot <run> <at> <snapshot> <job> [kind] [source-host] [path]
restore_resolve_snapshot() {
  local run="$1" at="$2" snapshot="$3" job="$4" kind="${5:-files}" host="${6:-}" path="${7:-}"

  if [ -n "${snapshot}" ]; then printf '%s' "${snapshot}"; return 0; fi
  require_jq

  local json
  json="$(_restore_snapshots_json "${host:-${BGB_HOSTNAME}}" "${job}" "${run}" "${kind}" "${path}")" || return 1

  # DISASTER RECOVERY RUNS ON A REPLACEMENT MACHINE, and a replacement machine
  # does not have the old machine's hostname - it has whatever the installer
  # gave it. Scoping every lookup to the LOCAL hostname therefore guaranteed
  # "No snapshot matches the given selector" on precisely the host that restore
  # exists for. Measured: snapshot host ace6892e7dcc, recovered host
  # 343069ab6b60, same repository, same run ID, zero matches.
  #
  # So: when the local host owns no matching snapshot and the caller named no
  # --source-host, let the repository answer - but only when its answer is
  # unambiguous. One other host is an obvious recovery; several is a shared
  # repository where guessing could restore another machine's data.
  if [ -z "${host}" ] && [ "$(printf '%s' "${json}" | jq 'length')" -eq 0 ]; then
    local all n
    all="$(_restore_snapshots_json "" "${job}" "${run}" "${kind}" "${path}")" || return 1
    n="$(printf '%s' "${all}" | jq '[.[].hostname] | unique | length')"
    if [ "${n}" = "1" ]; then
      warn "No snapshot for this host (${BGB_HOSTNAME}). Using the only host in this repository: $(printf '%s' "${all}" | jq -r '.[0].hostname')"
      json="${all}"
    elif [ "${n}" != "0" ]; then
      err "No snapshot for this host (${BGB_HOSTNAME}), and this repository holds several:"
      printf '%s' "${all}" | jq -r '[.[].hostname] | unique | .[]' \
        | while read -r h; do [ -n "${h}" ] && err "    ${h}"; done
      err "Name the one you mean with:  --source-host <hostname>"
      return 1
    fi
  fi

  local filter='sort_by(.time) | last | .short_id // empty'
  if [ -n "${at}" ]; then
    filter="[.[] | select(.time <= \"${at}\")] | sort_by(.time) | last | .short_id // empty"
  fi
  printf '%s' "${json}" | jq -r "${filter}"
}

restore_new_token() {
  printf '%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$"
}

# -----------------------------------------------------------------------------
# Command
# -----------------------------------------------------------------------------
cmd_restore() {
  local sub="${1:-}"; shift || true
  case "${sub}" in
    file|dir)   restore_path_cmd "${sub}" "$@" ;;
    volume)     restore_volume_cmd "$@" ;;
    project)    restore_project_cmd "$@" ;;
    db)         restore_db_cmd "$@" ;;
    system)     restore_system_cmd "$@" ;;
    preview)    BGB_RESTORE_PREVIEW=1 cmd_restore "$@" ;;
    commit)     restore_commit_cmd "$@" ;;
    rollback)   restore_rollback_cmd "$@" ;;
    ''|--help|-h) usage_restore ;;
    *)          err "Unknown subcommand: restore ${sub}"; usage_restore; exit "${EX_USAGE}" ;;
  esac
}

restore_parse_common() {
  R_RUN=""; R_AT=""; R_SNAPSHOT=""; R_JOB=""; R_TARGET=""; R_INPLACE=0
  R_OVERWRITE="if-newer"; R_VERIFY=0; R_SCRIPT=""; R_FORCE_UNSAFE=0
  R_PATH=""; R_NAME=""; R_DB=""; R_INTO="scratch"; R_SWAP=0; R_SOURCE_HOST=""
  R_PROFILE="safe"; R_CONFIG_ONLY=0; R_RECREATE=0; R_DELETE_EXTRANEOUS=0
  _RESTORE_REST=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --run)        R_RUN="$2"; shift 2 ;;
      --run=*)      R_RUN="${1#*=}"; shift ;;
      --at)         R_AT="$2"; shift 2 ;;
      --at=*)       R_AT="${1#*=}"; shift ;;
      --snapshot)   R_SNAPSHOT="$2"; shift 2 ;;
      --snapshot=*) R_SNAPSHOT="${1#*=}"; shift ;;
      --job)        R_JOB="$2"; shift 2 ;;
      --job=*)      R_JOB="${1#*=}"; shift ;;
      # The hostname RECORDED IN THE SNAPSHOTS, which on a rebuilt machine is
      # not this machine's hostname. Needed only when one repository holds
      # several hosts; otherwise it is inferred and reported.
      --source-host)   R_SOURCE_HOST="$2"; shift 2 ;;
      --source-host=*) R_SOURCE_HOST="${1#*=}"; shift ;;
      --path)       R_PATH="$2"; shift 2 ;;
      --path=*)     R_PATH="${1#*=}"; shift ;;
      --name)       R_NAME="$2"; shift 2 ;;
      --name=*)     R_NAME="${1#*=}"; shift ;;
      --db)         R_DB="$2"; shift 2 ;;
      --db=*)       R_DB="${1#*=}"; shift ;;
      --into)       R_INTO="$2"; shift 2 ;;
      --to)         R_TARGET="$2"; shift 2 ;;
      --to=*)       R_TARGET="${1#*=}"; shift ;;
      --in-place)   R_INPLACE=1; shift ;;
      --swap)       R_SWAP=1; shift ;;
      --overwrite)  R_OVERWRITE="$2"; shift 2 ;;
      --verify)     R_VERIFY=1; shift ;;
      --generate-script) R_SCRIPT="$2"; shift 2 ;;
      --force-unsafe)    R_FORCE_UNSAFE=1; shift ;;
      --profile)    R_PROFILE="$2"; shift 2 ;;
      --config-only) R_CONFIG_ONLY=1; shift ;;
      --recreate)   R_RECREATE=1; shift ;;
      --delete-extraneous) R_DELETE_EXTRANEOUS=1; shift ;;
      -*) err "Unknown flag for restore: $1"; usage_restore; exit "${EX_USAGE}" ;;
      *) _RESTORE_REST+=("$1"); shift ;;
    esac
  done
  [ -z "${R_JOB}" ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ] && R_JOB="${BGB_JOB_FILTER[0]}"

  # THIS `return 0` IS LOAD-BEARING. The line above is an && chain, and the
  # status of the last command IS the function's return value. With no --job and
  # an empty global filter the chain is false, the function returns 1, and
  # because every caller invokes it as a plain statement under `set -e` the
  # whole process exits 1 - before a single line of output. That killed every
  # restore subcommand (file, dir, volume, project, db, system) unconditionally,
  # and it did so silently, which is why only an end-to-end run found it.
  return 0
}

# -----------------------------------------------------------------------------
# file / dir
# -----------------------------------------------------------------------------
restore_path_cmd() {
  local kind="$1"; shift
  restore_parse_common "$@"
  [ -n "${R_PATH}" ] || die "${EX_USAGE}" "restore ${kind} requires --path"

  require_root
  config_load
  repo_env_load
  restic_require

  local snap
  snap="$(restore_resolve_snapshot "${R_RUN}" "${R_AT}" "${R_SNAPSHOT}" "${R_JOB}" files "${R_SOURCE_HOST}")"
  [ -n "${snap}" ] || die "${EX_PRECOND}" "No snapshot matches the given selector"
  log "Using snapshot ${snap}"

  local class; class="$(restore_classify "${R_PATH}")"
  case "${class}" in
    NEVER)
      err "'${R_PATH}' is on the NEVER list: restoring it can leave this host unbootable or unreachable."
      err "See $(restore_unsafe_list) and docs/runbooks/disaster-recovery.md."
      [ "${R_FORCE_UNSAFE}" = "1" ] || return "${EX_SAFETY}"
      warn "--force-unsafe given: proceeding against advice" ;;
    STAGED)
      if [ "${R_INPLACE}" = "1" ] && [ "${R_FORCE_UNSAFE}" != "1" ]; then
        err "'${R_PATH}' is classified STAGED: it must be reviewed before it replaces the live file."
        err "Restore it to a directory and diff it:"
        err "    bg-backup restore ${kind} --path '${R_PATH}' --to /tmp/review"
        return "${EX_SAFETY}"
      fi ;;
  esac

  if restore_is_dpkg_conffile_modified "${R_PATH}" && [ "${R_INPLACE}" = "1" ]; then
    warn "'${R_PATH}' is a package configuration file whose default changed in this OS version."
    warn "Overwriting it with the old host's copy defeats the package's own upgrade path."
    confirm "Restore it anyway?" || return "${EX_SAFETY}"
  fi

  local token; token="$(restore_new_token)"
  local staging="${R_TARGET}"
  [ -z "${staging}" ] && staging="${BGB_RESTORE_ROOT}/${token}"

  if [ "${BGB_RESTORE_PREVIEW:-0}" = "1" ]; then
    restore_preview "${snap}" "${R_PATH}"
    return $?
  fi

  install -d -m 0700 "${staging}"
  log "Restoring ${R_PATH} from ${snap} into ${staging}"

  local -a args=(restore "${snap}" --target "${staging}" --include "${R_PATH}")
  [ "${R_VERIFY}" = "1" ] && args+=(--verify)
  case "${R_OVERWRITE}" in
    always|never|if-newer|if-changed) args+=(--overwrite "${R_OVERWRITE}") ;;
  esac

  if [ -n "${R_SCRIPT}" ]; then
    restore_generate_script "${R_SCRIPT}" "${snap}" "${staging}" "${R_PATH}" "${args[@]}"
    return 0
  fi

  restic_exec_logged "${BGB_LOG_DIR}/restore.log" "${args[@]}" \
    || die "${EX_REPO}" "restore failed"

  if [ "${R_INPLACE}" != "1" ]; then
    log "Restored to ${staging}${R_PATH}"
    log "Review it, then apply with --in-place, or copy what you need by hand."
    return 0
  fi

  restore_swap_into_place "${staging}" "${R_PATH}" "${token}"
}

# -----------------------------------------------------------------------------
# Staging swap
# -----------------------------------------------------------------------------
restore_swap_into_place() {
  local staging="$1" path="$2" token="$3"
  local src="${staging}${path}"
  local backup="${path}.bgbk-old-${token}"

  [ -e "${src}" ] || die "${EX_FAIL}" "Nothing was restored at ${src}"

  confirm "Replace ${path} with the restored copy? (the current one is kept as ${backup})" \
    || { log "Left the restored copy at ${src}"; return 0; }

  # Same-filesystem check. Across filesystems this is a copy, not a rename: not
  # atomic, and it needs room for both copies at once. Saying so beats silently
  # filling a disk halfway through a recovery.
  local sdev ddev
  sdev="$(df -P "${src}" 2>/dev/null | awk 'NR==2{print $1}')"
  ddev="$(df -P "$(dirname "${path}")" 2>/dev/null | awk 'NR==2{print $1}')"
  if [ "${sdev}" != "${ddev}" ]; then
    warn "Staging and destination are on different filesystems (${sdev} vs ${ddev})."
    warn "The swap becomes a copy: it needs twice the space and is not atomic."
    confirm "Continue?" || return "${EX_SAFETY}"
  fi

  if [ -e "${path}" ]; then
    mv -T "${path}" "${backup}" || die "${EX_FAIL}" "Could not move the current ${path} aside"
    log "Previous content kept at ${backup}"
  fi
  mv -T "${src}" "${path}" || {
    err "Swap failed. Restoring the previous content."
    [ -e "${backup}" ] && mv -T "${backup}" "${path}"
    return "${EX_FAIL}"
  }

  log "Restored ${path}"
  log "Roll back with:  bg-backup restore rollback --token ${token}"
  log "Drop the safety copy with:  bg-backup restore commit --token ${token}"
  printf '%s\n' "${path}" >>"${BGB_STATE_DIR}/restore-${token}.swaps"
}

restore_commit_cmd() {
  local token=""
  while [ $# -gt 0 ]; do
    case "$1" in --token) token="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "${token}" ] || die "${EX_USAGE}" "restore commit requires --token"
  require_root
  config_load

  local list="${BGB_STATE_DIR}/restore-${token}.swaps" p
  [ -r "${list}" ] || die "${EX_PRECOND}" "Unknown restore token: ${token}"
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    if [ -e "${p}.bgbk-old-${token}" ]; then
      rm -rf "${p}.bgbk-old-${token}"
      log "Dropped the safety copy for ${p}"
    fi
  done <"${list}"
  rm -f "${list}"
  log "Committed restore ${token}"
}

restore_rollback_cmd() {
  local token=""
  while [ $# -gt 0 ]; do
    case "$1" in --token) token="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "${token}" ] || die "${EX_USAGE}" "restore rollback requires --token"
  require_root
  config_load

  local list="${BGB_STATE_DIR}/restore-${token}.swaps" p rc=0
  [ -r "${list}" ] || die "${EX_PRECOND}" "Unknown restore token: ${token}"
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    if [ -e "${p}.bgbk-old-${token}" ]; then
      rm -rf "${p}.restore-rollback.tmp"
      mv -T "${p}" "${p}.restore-rollback.tmp" 2>/dev/null || true
      if mv -T "${p}.bgbk-old-${token}" "${p}"; then
        rm -rf "${p}.restore-rollback.tmp"
        log "Rolled back ${p}"
      else
        err "Could not roll back ${p}"
        mv -T "${p}.restore-rollback.tmp" "${p}" 2>/dev/null || true
        rc=1
      fi
    else
      warn "No safety copy for ${p} (already committed?)"
    fi
  done <"${list}"
  rm -f "${list}"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Preview
# -----------------------------------------------------------------------------
restore_preview() {
  local snap="$1" path="$2"
  require_jq
  local danger=0

  printf '\n%sRestore preview%s  snapshot %s\n\n' "${C_BOLD}" "${C_RESET}" "${snap}"

  local n=0 line type name size mode
  while IFS= read -r line; do
    type="$(printf '%s'  "${line}" | jq -r '.type // ""')"
    name="$(printf '%s'  "${line}" | jq -r '.path // ""')"
    size="$(printf '%s'  "${line}" | jq -r '.size // 0')"
    mode="$(printf '%s'  "${line}" | jq -r '.mode // 0')"
    [ -n "${name}" ] || continue
    n=$(( n + 1 ))

    local class action
    class="$(restore_classify "${name}")"
    if [ -e "${name}" ]; then
      local cur_size; cur_size="$(stat -c %s "${name}" 2>/dev/null || echo 0)"
      if [ "${cur_size}" = "${size}" ]; then action="identical"; else action="overwrite"; fi
    else
      action="create"
    fi

    case "${class}" in
      NEVER)  printf '  %sDANGER%s   %-10s %s\n' "${C_RED}" "${C_RESET}" "${action}" "${name}"; danger=1 ;;
      STAGED) printf '  %sreview%s   %-10s %s\n' "${C_YELLOW}" "${C_RESET}" "${action}" "${name}" ;;
      *)      [ "${n}" -le 200 ] && printf '           %-10s %s (%s, mode %s)\n' "${action}" "${name}" "$(human_bytes "${size}")" "${mode}" ;;
    esac
  done < <(restic_capture ls --json "${snap}" "${path}" 2>/dev/null | grep '"struct_type":"node"' || true)

  printf '\n  %s entries\n' "${n}"
  if [ "${danger}" -eq 1 ]; then
    printf '\n  %sThis selection touches paths on the NEVER list.%s\n' "${C_RED}" "${C_RESET}"
    printf '  Restoring them can leave the host unbootable or unreachable.\n\n'
    return 2
  fi
  printf '\n  Nothing was written. This was a preview.\n\n'
  return 0
}

restore_generate_script() {
  local out="$1" snap="$2" staging="$3" path="$4"; shift 4
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by bg-backup %s on %s\n' "${BGB_VERSION}" "$(now_iso)"
    printf '# Review every line before running this. Nothing here is executed for you.\n'
    printf 'set -euo pipefail\n\n'
    printf 'source %s\n\n' "${BGB_REPO_ENV}"
    printf 'mkdir -p %q\n' "${staging}"
    printf '%q' "${BGB_RESTIC_BIN}"
    local a
    for a in "$@"; do printf ' %q' "${a}"; done
    printf '\n\n'
    printf '# Then review and swap by hand:\n'
    printf '#   diff -ru %q %q\n' "${path}" "${staging}${path}"
    printf '#   mv -T %q %q.bgbk-old\n' "${path}" "${path}"
    printf '#   mv -T %q%q %q\n' "${staging}" "${path}" "${path}"
  } >"${out}"
  chmod 0700 "${out}"
  log "Wrote a reviewable restore script to ${out}"
  log "Nothing has been restored. Read it, then run it."
}

# -----------------------------------------------------------------------------
# volume / project / db / system
# -----------------------------------------------------------------------------
restore_volume_cmd() {
  restore_parse_common "$@"
  [ -n "${R_NAME}" ] || die "${EX_USAGE}" "restore volume requires --name"
  require_root
  config_load
  repo_env_load
  restic_require
  require_cmd docker

  local mp; mp="$(docker volume inspect "${R_NAME}" 2>/dev/null | jq -r '.[0].Mountpoint // empty')"
  if [ -z "${mp}" ]; then
    log "Volume '${R_NAME}' does not exist - creating it"
    docker volume create "${R_NAME}" >/dev/null
    mp="$(docker volume inspect "${R_NAME}" | jq -r '.[0].Mountpoint')"
  fi

  local users; users="$(docker ps -q --filter "volume=${R_NAME}" 2>/dev/null || true)"
  if [ -n "${users}" ]; then
    err "These containers are using volume '${R_NAME}':"
    docker ps --filter "volume=${R_NAME}" --format '    {{.Names}} ({{.Image}})' >&2
    err "Restoring a volume underneath a running container corrupts both."
    confirm "Stop them, restore, and start them again?" || return "${EX_SAFETY}"
    # shellcheck disable=SC2086
    docker stop ${users} >/dev/null
    on_cleanup "docker start ${users} >/dev/null 2>&1 || true"
  fi

  local snap token staging
  snap="$(restore_resolve_snapshot "${R_RUN}" "${R_AT}" "${R_SNAPSHOT}" "${R_JOB}" files "${R_SOURCE_HOST}")"
  [ -n "${snap}" ] || die "${EX_PRECOND}" "No snapshot matches"
  token="$(restore_new_token)"
  staging="${BGB_RESTORE_ROOT}/${token}"
  install -d -m 0700 "${staging}"

  log "Restoring volume '${R_NAME}' from ${snap}"
  restic_exec_logged "${BGB_LOG_DIR}/restore.log" \
    restore "${snap}" --target "${staging}" --include "${mp}" \
    || die "${EX_REPO}" "restore failed"

  [ -d "${staging}${mp}" ] || die "${EX_FAIL}" "The snapshot does not contain ${mp}"

  if [ "${R_SWAP}" = "1" ] || confirm "Swap the restored contents into volume '${R_NAME}'?"; then
    # Swap _data, not the volume object: Docker cannot rename a volume, and this
    # keeps the driver, options and labels exactly as they were.
    mv -T "${mp}" "${mp}.bgbk-old-${token}"
    mv -T "${staging}${mp}" "${mp}"
    log "Volume '${R_NAME}' restored (previous contents at ${mp}.bgbk-old-${token})"
    printf '%s\n' "${mp}" >>"${BGB_STATE_DIR}/restore-${token}.swaps"
  else
    log "Restored contents left at ${staging}${mp}"
  fi
}

restore_project_cmd() {
  restore_parse_common "$@"
  [ -n "${R_NAME}" ] || die "${EX_USAGE}" "restore project requires --name"
  require_root
  config_load
  repo_env_load
  restic_require
  lib_source dr.sh
  dr_restore_project "${R_NAME}" "${R_RUN}" "${R_CONFIG_ONLY}" "${R_RECREATE}"
}

restore_db_cmd() {
  restore_parse_common "$@"
  [ -n "${R_DB}" ] || die "${EX_USAGE}" "restore db requires --db (e.g. postgres/app-db/app.sql)"
  require_root
  config_load
  repo_env_load
  restic_require

  # Resolve by PATH as well as by tag. Every dump is its own snapshot and they
  # all carry kind=dbdump, so without the path the newest one wins - the last
  # engine dumped in the run - and `restic dump` then reports the requested file
  # as missing from a snapshot that never contained it.
  local path="db/${R_DB}"
  local snap
  snap="$(restore_resolve_snapshot "${R_RUN}" "${R_AT}" "${R_SNAPSHOT}" "${R_JOB}" dbdump "${R_SOURCE_HOST}" "/${path}")"
  [ -n "${snap}" ] || die "${EX_PRECOND}" "No database dump snapshot contains /${path}"
  case "${R_INTO}" in
    -)
      # Straight to stdout: the operator pipes it wherever they want. This is
      # also the documented manual path in the recovery sheet.
      restic_exec dump "${snap}" "/${path}" ;;
    scratch)
      lib_source verify.sh
      verify_restore_into_scratch "${snap}" "${path}" ;;
    *)
      local container="${R_INTO}"
      local engine; engine="$(printf '%s' "${R_DB}" | cut -d/ -f1)"
      lib_source db.sh
      db_load_engine "${engine}" || die "${EX_PRECOND}" "No engine module for '${engine}'"
      local fn="db_${engine}_restore"
      declare -F "${fn}" >/dev/null 2>&1 || die "${EX_PRECOND}" "Engine '${engine}' cannot restore"
      warn "This will load the dump into the LIVE container '${container}'."
      confirm "Continue?" || return "${EX_SAFETY}"
      restic_exec dump "${snap}" "/${path}" | "${fn}" "${container}" ;;
  esac
}

restore_system_cmd() {
  restore_parse_common "$@"
  require_root
  config_load
  lib_source dr.sh
  dr_restore_system "${R_PROFILE}" "${R_RUN}"
}

# -----------------------------------------------------------------------------
# dump
# -----------------------------------------------------------------------------
cmd_dump() {
  local snap="${1:-}" path="${2:-}" out=""
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in --to) out="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "${snap}" ] && [ -n "${path}" ] || die "${EX_USAGE}" "usage: bg-backup dump <snapshot|latest> <path> [--to FILE]"

  config_load
  repo_env_load
  restic_require

  if [ -n "${out}" ]; then
    restic_exec dump "${snap}" "${path}" >"${out}"
    log "Wrote $(human_bytes "$(stat -c %s "${out}" 2>/dev/null || echo 0)") to ${out}"
  else
    restic_exec dump "${snap}" "${path}"
  fi
}
