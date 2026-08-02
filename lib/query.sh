#!/usr/bin/env bash
# =============================================================================
# bg-backup - query: read-only views of the repository
# =============================================================================
# snapshots, ls, find, diff, mount, stats, unlock and runs.
#
# `runs` is the important one. Every backup produces SEVERAL snapshots - the
# file tree, one per database dump, the image exports - and resolving "latest"
# per snapshot independently would happily pair Monday's database dump with
# Tuesday's volume contents. A run groups them, and a run is what you restore.
# =============================================================================

[ -n "${_BGB_QUERY_SOURCED:-}" ] && return 0
_BGB_QUERY_SOURCED=1

query_prepare() {
  config_load
  repo_env_load
  restic_require
}

# -----------------------------------------------------------------------------
# snapshots
# -----------------------------------------------------------------------------
cmd_snapshots() {
  local job="" tag="" last="" all_hosts=0 show_paths=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --job)     job="$2"; shift 2 ;;
      --job=*)   job="${1#*=}"; shift ;;
      --tag)     tag="$2"; shift 2 ;;
      --tag=*)   tag="${1#*=}"; shift ;;
      --last)    last="$2"; shift 2 ;;
      --last=*)  last="${1#*=}"; shift ;;
      --all-hosts) all_hosts=1; shift ;;
      --paths)   show_paths=1; shift ;;
      -*) err "Unknown flag for snapshots: $1"; exit "${EX_USAGE}" ;;
      *) shift ;;
    esac
  done
  [ -z "${job}" ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ] && job="${BGB_JOB_FILTER[0]}"

  query_prepare

  local -a args=(snapshots)
  [ "${all_hosts}" -eq 0 ] && args+=(--host "${BGB_HOSTNAME}")
  # AND: `--job web --tag kind=dbdump` must mean both, not either.
  mapfile -t -O "${#args[@]}" args < <(restic_tag_filter_args "${job:+job=${job}}" "${tag}")
  [ -n "${last}" ] && args+=(--latest "${last}")

  if [ "${BGB_JSON}" = "1" ]; then
    require_jq
    restic_capture "${args[@]}" --json | jq '.'
    return 0
  fi

  if ! have jq; then
    # Plain restic output is a perfectly good fallback here, and refusing would
    # be unhelpful in exactly the situation (a rescue system) where this command
    # matters most.
    restic_exec "${args[@]}"
    return $?
  fi

  local json
  json="$(restic_capture "${args[@]}" --json)" || return "${EX_REPO}"
  local n; n="$(printf '%s' "${json}" | jq 'length')"
  if [ "${n}" = "0" ]; then
    log "No snapshots match"
    return 0
  fi

  printf '\n  %-10s %-20s %-10s %-26s %s\n' "ID" "TIME" "SIZE" "TAGS" "PATHS"
  printf '%s' "${json}" | jq -r --argjson paths "${show_paths}" '
    sort_by(.time) | .[] |
    [ .short_id,
      (.time | sub("\\..*";"") | sub("T";" ")),
      ((.summary.total_bytes_processed // 0) | tostring),
      ((.tags // []) | map(select(startswith("bg-backup=") | not)) | join(",")),
      ((.paths // []) | if $paths == 1 then join(",") else (.[0] // "") end)
    ] | @tsv' \
  | while IFS=$'\t' read -r id time size tags paths; do
      printf '  %-10s %-20s %-10s %-26s %s\n' \
        "${id}" "${time}" "$(human_bytes "${size}")" "${tags:0:26}" "${paths}"
    done
  printf '\n  %s snapshot(s)\n\n' "${n}"
}

# -----------------------------------------------------------------------------
# runs
# -----------------------------------------------------------------------------
cmd_runs() {
  local sub="${1:-list}"; shift || true
  case "${sub}" in
    list) runs_list "$@" ;;
    show) runs_show "$@" ;;
    diff) runs_diff "$@" ;;
    *) err "Unknown subcommand: runs ${sub}"; exit "${EX_USAGE}" ;;
  esac
}

runs_list() {
  local job="" limit=20
  while [ $# -gt 0 ]; do
    case "$1" in
      --job) job="$2"; shift 2 ;;
      --job=*) job="${1#*=}"; shift ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  query_prepare
  require_jq

  local -a args=(snapshots --host "${BGB_HOSTNAME}" --json)
  [ -n "${job}" ] && args+=(--tag "job=${job}")

  local json; json="$(restic_capture "${args[@]}")" || return "${EX_REPO}"

  # Group by the run= tag. Snapshots without one predate this tool (or were made
  # by hand) and are listed under "-" rather than hidden.
  #
  # Every tag extraction below is wrapped in jq's first(): a snapshot carrying
  # two tags with the same key otherwise yields two values, jq emits one row per
  # combination, and the run appears to contain more snapshots than it does. A
  # duplicate kind= tag on the PostgreSQL globals dump did exactly that. That tag
  # is fixed at the source, but a selector that miscounts whenever the data
  # surprises it is a second, independent bug.
  printf '\n  %-24s %-14s %-6s %-20s %s\n' "RUN" "JOB" "SNAPS" "TIME" "KINDS"
  printf '%s' "${json}" | jq -r '
    [ .[] | . as $s
      | ($s.tags // []) as $t
      | { run:  first($t[] | select(startswith("run=")) | sub("run=";"")) // "-",
          job:  first($t[] | select(startswith("job=")) | sub("job=";"")) // "-",
          kind: first($t[] | select(startswith("kind=")) | sub("kind=";"")) // "files",
          time: $s.time, id: $s.short_id } ]
    | group_by(.run) | map({
        run: .[0].run, job: .[0].job, n: length,
        time: (map(.time) | sort | .[0] | sub("\\..*";"") | sub("T";" ")),
        kinds: (map(.kind) | unique | join(","))
      }) | sort_by(.time) | reverse | .[]
    | [.run, .job, (.n|tostring), .time, .kinds] | @tsv' 2>/dev/null \
  | head -n "${limit}" \
  | while IFS=$'\t' read -r run job n time kinds; do
      printf '  %-24s %-14s %-6s %-20s %s\n' "${run}" "${job}" "${n}" "${time}" "${kinds}"
    done
  printf '\n'
}

runs_show() {
  local run="${1:-}"
  [ -n "${run}" ] || die "${EX_USAGE}" "usage: bg-backup runs show <run-id>"
  query_prepare
  require_jq
  restic_capture snapshots --host "${BGB_HOSTNAME}" --tag "run=${run}" --json | jq '.'
}

runs_diff() {
  local a="${1:-}" b="${2:-}"
  [ -n "${a}" ] && [ -n "${b}" ] || die "${EX_USAGE}" "usage: bg-backup runs diff <run-a> <run-b>"
  query_prepare
  require_jq
  local sa sb
  # AND. With repeated --tag flags both queries would match every snapshot of
  # either run plus every kind=files snapshot ever taken, and .[0] would then
  # diff two arbitrary snapshots while looking entirely successful.
  sa="$(restic_capture snapshots --tag "run=${a},kind=files" --json | jq -r '.[0].short_id // empty')"
  sb="$(restic_capture snapshots --tag "run=${b},kind=files" --json | jq -r '.[0].short_id // empty')"
  [ -n "${sa}" ] && [ -n "${sb}" ] || die "${EX_PRECOND}" "Could not resolve both runs to file snapshots"
  restic_exec diff "${sa}" "${sb}"
}

# -----------------------------------------------------------------------------
# ls / find / diff / mount / stats / unlock
# -----------------------------------------------------------------------------
cmd_ls() {
  local snap="${1:-latest}"; shift || true
  query_prepare
  local -a args=(ls "${snap}")
  [ $# -gt 0 ] && args+=("$@")
  [ "${BGB_JSON}" = "1" ] && args+=(--json)
  restic_exec "${args[@]}"
}

cmd_find() {
  local pattern="${1:-}"; shift || true
  [ -n "${pattern}" ] || die "${EX_USAGE}" "usage: bg-backup find <pattern>"
  query_prepare
  local -a args=(find --host "${BGB_HOSTNAME}" "${pattern}")
  [ "${BGB_JSON}" = "1" ] && args+=(--json)
  [ $# -gt 0 ] && args+=("$@")
  restic_exec "${args[@]}"
}

cmd_diff() {
  local a="${1:-}" b="${2:-}"
  [ -n "${a}" ] && [ -n "${b}" ] || die "${EX_USAGE}" "usage: bg-backup diff <snapshot-a> <snapshot-b>"
  query_prepare
  local -a args=(diff "${a}" "${b}")
  [ "${BGB_JSON}" = "1" ] && args+=(--json)
  restic_exec "${args[@]}"
}

cmd_mount() {
  local dir="${1:-}"
  [ -n "${dir}" ] || die "${EX_USAGE}" "usage: bg-backup mount <directory>"
  require_root
  query_prepare
  require_cmd fusermount3 "apt-get install -y fuse3"

  install -d -m 0700 "${dir}"
  log "Mounting the repository read-only at ${dir}"
  log "Browse it in another terminal; press Ctrl-C here to unmount."

  # Ensure the mount is always released, including on Ctrl-C. A leftover FUSE
  # mount makes the directory unusable and confuses later runs.
  on_cleanup "fusermount3 -u '${dir}' 2>/dev/null || true"
  restic_exec mount "${dir}"
}

cmd_stats() {
  local mode="restore-size" job=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --mode=*) mode="${1#*=}"; shift ;;
      --job) job="$2"; shift 2 ;;
      --job=*) job="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done
  query_prepare
  local -a args=(stats --mode "${mode}" --host "${BGB_HOSTNAME}")
  [ -n "${job}" ] && args+=(--tag "job=${job}")
  [ "${BGB_JSON}" = "1" ] && args+=(--json)
  restic_exec "${args[@]}"
}

cmd_unlock() {
  local remove_all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --remove-all) remove_all=1; shift ;;
      *) shift ;;
    esac
  done
  require_root
  query_prepare

  # Show who holds the lock before removing it. Blindly unlocking a repository
  # another host is actively writing to is how a repository gets damaged.
  local locks; locks="$(restic_capture list locks 2>/dev/null || true)"
  if [ -z "${locks}" ]; then
    log "No repository locks are held"
    return 0
  fi
  warn "The repository holds $(printf '%s' "${locks}" | grep -c '^') lock(s)"
  warn "If another host or another process is mid-write, removing them can damage the repository."

  local -a args=(unlock)
  [ "${remove_all}" -eq 1 ] && args+=(--remove-all)
  [ "${remove_all}" -eq 1 ] && ! confirm "Remove ALL locks, including other hosts'?" && return 0

  restic_exec "${args[@]}"
}
