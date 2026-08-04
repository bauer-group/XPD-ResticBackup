#!/usr/bin/env bash
# =============================================================================
# bg-backup - retention: the only irreversible code path in this tool
# =============================================================================
# Five independent rails, because in a SHARED BUCKET the cost of getting this
# wrong is not "this host loses backups" but "another host loses backups":
#
#   1. SCOPING IS MANDATORY. Every forget carries
#        --host <fqdn> --tag job=<name> --group-by host
#      Without --host, one server's retention deletes another server's snapshots
#      quietly and with exit 0. Without --tag job=, the docker job's policy is
#      silently applied to the system job's snapshots. This is the single most
#      likely catastrophic bug in a tool of this shape.
#      The grouping is host ONLY - see retention_forget_args() for why adding
#      `tags` there silently disabled retention altogether.
#   2. Dry-run always runs first and its output is inspected.
#   3. A floor: refuse if fewer than BGB_FORGET_MIN_SNAPSHOTS would remain.
#   4. A ceiling: refuse if more than BGB_FORGET_MAX_DELETE_PERCENT would go.
#   5. --keep-tag keep-forever, so an operator can pin a snapshot by hand.
#
# prune is additionally restricted to BGB_REPO_ROLE=primary so two hosts sharing
# a bucket cannot prune concurrently and remove packs from under each other.
# =============================================================================

[ -n "${_BGB_RETENTION_SOURCED:-}" ] && return 0
_BGB_RETENTION_SOURCED=1

# -----------------------------------------------------------------------------
# argv construction
# -----------------------------------------------------------------------------
# retention_forget_args <job> - one argument per line.
retention_forget_args() {
  local job="$1" v

  printf 'forget\n'
  # --- the scoping arguments that must never be omitted ----------------------
  # --host and --tag are FILTERS: they decide which snapshots restic considers
  # at all, and cmd_forget() calls this once per job, so the candidate set is
  # already exactly "this host, this job".
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--tag\njob=%s\n' "${job}"

  # --group-by is NOT a filter, and it used to say `host,tags`. That looked like
  # extra safety and was the opposite: `tags` groups by the COMPLETE tag set,
  # and restic_tag_args() stamps every snapshot with a unique `run=<id>` tag. So
  # every snapshot landed in a group of ONE, --keep-last 5 dutifully kept the
  # single member of each group, and forget deleted nothing - ever, on any host,
  # for any policy. It exited 0 and reported "nothing to remove", which is
  # indistinguishable from a repository that is already within its policy.
  #
  # Grouping by host alone is what the policy needs: the job scoping is done by
  # the --tag filter above, so within one invocation every candidate snapshot
  # belongs to the same job by construction.
  printf -- '--group-by\nhost\n'
  # --- the manual pin --------------------------------------------------------
  printf -- '--keep-tag\n%s\n' "${BGB_KEEP_TAG}"

  v="$(job_retention_value LAST)"
  [ -n "${v}" ] && [ "${v}" != "0" ] && printf -- '--keep-last\n%s\n' "${v}"
  v="$(job_retention_value DAILY)"
  [ -n "${v}" ] && [ "${v}" != "0" ] && printf -- '--keep-daily\n%s\n' "${v}"
  v="$(job_retention_value WEEKLY)"
  [ -n "${v}" ] && [ "${v}" != "0" ] && printf -- '--keep-weekly\n%s\n' "${v}"
  v="$(job_retention_value MONTHLY)"
  [ -n "${v}" ] && [ "${v}" != "0" ] && printf -- '--keep-monthly\n%s\n' "${v}"
  v="$(job_retention_value YEARLY)"
  [ -n "${v}" ] && [ "${v}" != "0" ] && printf -- '--keep-yearly\n%s\n' "${v}"
  v="${JOB_KEEP_WITHIN:-${BGB_DEFAULT_KEEP_WITHIN}}"
  [ -n "${v}" ] && printf -- '--keep-within\n%s\n' "${v}"
  return 0
}

# retention_has_policy <job> - refuse to run forget with no keep-* at all.
# restic would interpret that as "keep nothing" and delete every snapshot for
# the job. A misconfigured file must not be able to express that by omission.
retention_has_policy() {
  local job="$1" n
  n="$(retention_forget_args "${job}" | grep -c -- '--keep-\(last\|daily\|weekly\|monthly\|yearly\|within\)$' || true)"
  [ "${n:-0}" -gt 0 ]
}

# -----------------------------------------------------------------------------
# forget
# -----------------------------------------------------------------------------
# retention_forget <job> <apply:0|1>
retention_forget() {
  local job="$1" apply="${2:-0}"
  local -a args=()
  local out before remove keep pct rc=0

  if ! retention_has_policy "${job}"; then
    err "${job}: no retention policy is configured (no keep-* value set)"
    err "restic would read that as 'keep nothing' and delete every snapshot."
    return "${EX_SAFETY}"
  fi

  mapfile -t args < <(retention_forget_args "${job}")

  # --- 2. dry run first ------------------------------------------------------
  if ! have jq; then
    # Without jq the counting rails cannot be evaluated, and rails that cannot
    # be evaluated must not be silently skipped on a destructive operation.
    err "jq is required to evaluate the retention safety rails"
    err "Install jq, or run restic forget by hand if you accept the risk."
    return "${EX_PRECOND}"
  fi

  out="$(restic_capture "${args[@]}" --dry-run --json)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    err "forget --dry-run failed (rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_REPO}"
  fi

  keep="$(printf '%s' "${out}" | jq '[.[].keep[]?]   | length' 2>/dev/null || echo 0)"
  remove="$(printf '%s' "${out}" | jq '[.[].remove[]?] | length' 2>/dev/null || echo 0)"
  before=$((keep + remove))

  if [ "${before}" -eq 0 ]; then
    log "${job}: no snapshots to consider"
    return 0
  fi
  if [ "${remove}" -eq 0 ]; then
    log "${job}: retention satisfied, nothing to remove (${keep} kept)"
    return 0
  fi

  pct=$((remove * 100 / before))

  # --- 3. floor --------------------------------------------------------------
  if [ "${keep}" -lt "${BGB_FORGET_MIN_SNAPSHOTS}" ]; then
    err "${job}: forget would leave ${keep} snapshot(s); the floor is ${BGB_FORGET_MIN_SNAPSHOTS}"
    err "Refusing. Review the policy with: bg-backup forget --job ${job} --dry-run"
    return "${EX_SAFETY}"
  fi

  # --- 4. ceiling ------------------------------------------------------------
  if [ "${pct}" -gt "${BGB_FORGET_MAX_DELETE_PERCENT}" ] && [ "${BGB_YES}" != "1" ]; then
    err "${job}: forget would remove ${remove} of ${before} snapshots (${pct}%)"
    err "That exceeds BGB_FORGET_MAX_DELETE_PERCENT=${BGB_FORGET_MAX_DELETE_PERCENT}."
    err "If this is intended (a policy change, say), re-run with --yes."
    return "${EX_SAFETY}"
  fi

  if [ "${apply}" != "1" ]; then
    log "${job}: forget (dry-run) would remove ${remove} of ${before} snapshots, keeping ${keep}"
    retention_print_removals "${out}"
    return 0
  fi

  log "${job}: removing ${remove} of ${before} snapshots (keeping ${keep})"
  retention_print_removals "${out}"

  rc=0
  restic_exec_logged "${BGB_JOB_LOG:-/dev/null}" "${args[@]}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    err "forget failed (rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_REPO}"
  fi

  state_touch "forget_${job}_at" "$(now_iso)"
  state_touch "forget_${job}_removed" "${remove}"
  return 0
}

retention_print_removals() {
  local out="$1"
  have jq || return 0
  printf '%s' "${out}" \
    | jq -r '.[].remove[]? | "    - \(.short_id)  \(.time)  \((.tags // []) | join(","))"' 2>/dev/null \
    | head -n 40 >&2 || true
}

# -----------------------------------------------------------------------------
# Command: forget
# -----------------------------------------------------------------------------
cmd_forget() {
  local apply=0 job="" rc=0 worst=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)
        apply=1
        shift
        ;;
      --dry-run)
        apply=0
        shift
        ;;
      --job)
        job="$2"
        shift 2
        ;;
      --job=*)
        job="${1#*=}"
        shift
        ;;
      -*)
        err "Unknown flag for forget: $1"
        usage_forget
        exit "${EX_USAGE}"
        ;;
      *)
        job="$1"
        shift
        ;;
    esac
  done

  require_root
  config_load
  repo_env_load
  restic_require

  lock_take_repo || return "${EX_LOCKED}"

  [ -z "${job}" ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ] && job="${BGB_JOB_FILTER[0]}"

  local -a jobs=()
  if [ -n "${job}" ]; then jobs=("${job}"); else mapfile -t jobs < <(config_list_jobs); fi

  local j
  for j in "${jobs[@]}"; do
    [ -n "${j}" ] || continue
    config_load_job "${j}"
    rc=0
    retention_forget "${j}" "${apply}" || rc=$?
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  [ "${apply}" != "1" ] && log "Nothing was deleted. Re-run with --apply to act."
  return "${worst}"
}

# -----------------------------------------------------------------------------
# Command: prune
# -----------------------------------------------------------------------------
cmd_prune() {
  # NOT `max_unused="${BGB_PRUNE_MAX_UNUSED}"` - that default is created by
  # config_load(), which runs further down, so under `set -u` this aborted the
  # command before it parsed a flag:
  #     lib/retention.sh: line 220: BGB_PRUNE_MAX_UNUSED: unbound variable
  # `bg-backup prune` therefore never worked on any host, which also means the
  # prune timer failed on every fire. The configured default is applied after
  # config_load() instead, below.
  local max_unused="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-unused)
        max_unused="$2"
        shift 2
        ;;
      --max-unused=*)
        max_unused="${1#*=}"
        shift
        ;;
      --dry-run)
        dry=1
        shift
        ;;
      -*)
        err "Unknown flag for prune: $1"
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  require_root
  config_load
  repo_env_load
  restic_require

  # The configured default, now that config_load() has created it.
  [ -n "${max_unused}" ] || max_unused="${BGB_PRUNE_MAX_UNUSED}"

  # The role check is a safety control, not a preference: prune rewrites pack
  # files, and two hosts doing that concurrently against one repository can
  # remove data the other still references.
  if [ "${BGB_REPO_ROLE}" != "primary" ]; then
    err "This host has BGB_REPO_ROLE=${BGB_REPO_ROLE}; only a 'primary' host may prune."
    err "Prune runs from exactly one identity per repository. If that should be"
    err "this host, set BGB_REPO_ROLE=primary in ${BGB_CONFDIR}/bg-backup.conf."
    return "${EX_SAFETY}"
  fi

  lock_take_repo || return "${EX_LOCKED}"

  local -a args=(prune --max-unused "${max_unused}")
  [ "${dry}" -eq 1 ] && args+=(--dry-run)

  log "Pruning repository (max-unused ${max_unused})"
  local rc=0
  restic_exec_logged "${BGB_LOG_DIR}/prune.log" "${args[@]}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    err "prune failed (rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_REPO}"
  fi
  [ "${dry}" -eq 0 ] && state_touch prune_at "$(now_iso)"
  log "Prune complete"
  return 0
}

# -----------------------------------------------------------------------------
# Command: copy
# -----------------------------------------------------------------------------
cmd_copy() {
  local job=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --job)
        job="$2"
        shift 2
        ;;
      --job=*)
        job="${1#*=}"
        shift
        ;;
      --to) shift 2 ;;
      *) shift ;;
    esac
  done

  require_root
  config_load

  [ -n "${BGB_SECONDARY_REPO_ENV}" ] \
    || die "${EX_PRECOND}" "No secondary repository configured (BGB_SECONDARY_REPO_ENV)"
  [ -f "${BGB_SECONDARY_REPO_ENV}" ] \
    || die "${EX_PRECOND}" "Secondary repository environment not found: ${BGB_SECONDARY_REPO_ENV}"

  # Load the PRIMARY first; these become the --from-* side of the copy.
  repo_env_load
  restic_require
  lock_take_repo || return "${EX_LOCKED}"

  local src_repo="${RESTIC_REPOSITORY}"
  local src_pass="${RESTIC_PASSWORD_FILE:-}"

  # Read the secondary repository's settings in a subshell so its variables
  # cannot leak into, and silently redirect, operations on the primary.
  redact_register_file "${BGB_SECONDARY_REPO_ENV}"
  local dst_repo dst_pass
  # shellcheck disable=SC1090
  dst_repo="$(
    . "${BGB_SECONDARY_REPO_ENV}" >/dev/null 2>&1
    printf '%s' "${RESTIC_REPOSITORY:-}"
  )"
  # shellcheck disable=SC1090
  dst_pass="$(
    . "${BGB_SECONDARY_REPO_ENV}" >/dev/null 2>&1
    printf '%s' "${RESTIC_PASSWORD_FILE:-}"
  )"

  [ -n "${dst_repo}" ] || die "${EX_PRECOND}" "${BGB_SECONDARY_REPO_ENV}: RESTIC_REPOSITORY is not set"
  if [ "${dst_repo}" = "${src_repo}" ]; then
    die "${EX_PRECOND}" "The secondary repository is the same as the primary - refusing to copy a repository onto itself"
  fi

  # restic copy semantics: RESTIC_REPOSITORY is the DESTINATION and --from-repo
  # is the SOURCE. Getting these the wrong way round would quietly copy the
  # (possibly empty) secondary over the primary's snapshot list.
  cat >&2 <<'EOF'

Note: the secondary repository must have been created with

    restic init --from-repo <primary> --copy-chunker-params

Without matching chunker parameters restic re-chunks every blob, deduplication
against the primary is lost, and the copy can end up several times larger.

EOF

  local -a jobs=()
  if [ -n "${job}" ]; then jobs=("${job}"); else mapfile -t jobs < <(config_list_jobs); fi

  local j rc=0 worst=0
  for j in "${jobs[@]}"; do
    [ -n "${j}" ] || continue
    config_load_job "${j}"
    [ "${JOB_COPY_TO_SECONDARY}" = "1" ] || {
      debug "${j}: copy disabled"
      continue
    }

    log "Copying job '${j}' to the secondary repository"
    rc=0
    (
      export RESTIC_REPOSITORY="${dst_repo}"
      [ -n "${dst_pass}" ] && export RESTIC_PASSWORD_FILE="${dst_pass}"
      export RESTIC_FROM_REPOSITORY="${src_repo}"
      [ -n "${src_pass}" ] && export RESTIC_FROM_PASSWORD_FILE="${src_pass}"
      "${BGB_RESTIC_BIN}" copy --host "${BGB_HOSTNAME}" --tag "job=${j}"
    ) || rc=$?
    [ "${rc}" -ne 0 ] && warn "copy failed for job '${j}' (rc=${rc})"
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  [ "${worst}" -eq 0 ] && state_touch copy_at "$(now_iso)"
  return "${worst}"
}
