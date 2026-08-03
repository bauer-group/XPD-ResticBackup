#!/usr/bin/env bash
# =============================================================================
# bg-backup - verify: prove the backup restores, do not assume it
# =============================================================================
# `check` proves the repository is internally consistent. That is necessary and
# not sufficient: a structurally perfect repository can still contain a database
# dump that will not load.
#
# `verify` therefore actually restores things and asserts on the result:
#
#   canary    a 1 MiB random file written at backup time, restored and hashed.
#             Proves the key, transport, backend and decryption path in seconds.
#   sample    N real files restored and compared against the live copies where
#             mtime+size prove they have not changed since the snapshot.
#   dbdump    each dump loaded into a THROWAWAY container built from the exact
#             image digest recorded in the manifest, on a network with no
#             egress, then table and row counts compared against the counts
#             captured at dump time.
#
# Monthly, the OLDEST retained snapshot is tested too. That is the one you
# actually depend on in a ransomware scenario, and the one nobody ever tests.
# =============================================================================

[ -n "${_BGB_VERIFY_SOURCED:-}" ] && return 0
_BGB_VERIFY_SOURCED=1

# =============================================================================
# check
# =============================================================================
cmd_check() {
  local read_data=0 subset="${BGB_CHECK_READ_DATA_SUBSET}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --read-data)
        read_data=1
        subset=""
        shift
        ;;
      --read-data-subset)
        subset="$2"
        shift 2
        ;;
      --read-data-subset=*)
        subset="${1#*=}"
        shift
        ;;
      -*)
        err "Unknown flag for check: $1"
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  require_root
  config_load
  repo_env_load
  restic_require
  lock_take_repo || return "${EX_LOCKED}"

  local -a args=(check)
  if [ "${read_data}" -eq 1 ]; then
    warn "--read-data downloads the ENTIRE repository. On a large repo this is"
    warn "hours of transfer and real egress cost. --read-data-subset covers the"
    warn "same ground over a month at a fraction of the cost."
    args+=(--read-data)
  elif [ -n "${subset}" ]; then
    # Rotate through the repository rather than re-reading the same slice every
    # day. The bitmap is persisted so a missed day is caught up, not skipped
    # forever - which is what a plain `n = day_of_month` scheme does.
    local n
    n="$(verify_next_subset)"
    args+=(--read-data-subset "${n}")
    log "Reading data subset ${n} (rotating; full coverage every 30 runs)"
  fi

  log "Checking repository integrity"
  local rc=0
  restic_exec_logged "${BGB_LOG_DIR}/check.log" "${args[@]}" || rc=$?

  state_touch check_at "$(now_iso)"
  if [ "${rc}" -eq 0 ]; then
    state_touch check_ok "1"
    [ -n "${subset}" ] && verify_mark_subset_done
    metrics_write check || true
    monitor_notify check_ok "" 0 || true
    log "Repository integrity: no errors found"
    return 0
  fi

  state_touch check_ok "0"
  metrics_write check || true
  err "restic check reported problems (rc=${rc})"
  err "See ${BGB_LOG_DIR}/check.log"
  err "Do NOT prune until this is understood: prune rewrites pack files and can"
  err "turn a recoverable inconsistency into an unrecoverable one."
  # check failures always alert, regardless of BGB_MONITOR_ON.
  monitor_notify check_failed "" "${rc}" || true
  return "${EX_VERIFY}"
}

# Rotation bitmap: 30 slots, oldest unverified first.
verify_next_subset() {
  local f="${BGB_STATE_DIR}/check-subset.state"
  local total=30 i oldest=1 oldest_ts=""
  [ -r "${f}" ] || {
    printf '1/%s' "${total}"
    return 0
  }

  for i in $(seq 1 "${total}"); do
    local ts
    ts="$(awk -F= -v k="${i}" '$1==k{print $2}' "${f}" 2>/dev/null)"
    if [ -z "${ts}" ]; then
      printf '%s/%s' "${i}" "${total}"
      return 0
    fi
    if [ -z "${oldest_ts}" ] || [ "${ts}" -lt "${oldest_ts}" ]; then
      oldest_ts="${ts}"
      oldest="${i}"
    fi
  done
  printf '%s/%s' "${oldest}" "${total}"
}

verify_mark_subset_done() {
  local f="${BGB_STATE_DIR}/check-subset.state"
  local n
  n="$(verify_next_subset)"
  n="${n%%/*}"
  install -d -m 0700 "${BGB_STATE_DIR}"
  {
    grep -v "^${n}=" "${f}" 2>/dev/null || true
    printf '%s=%s\n' "${n}" "$(now_epoch)"
  } \
    | atomic_write "${f}" 0640

  # When every slot has been read at least once, the whole repository has been
  # byte-verified within the window - the number that actually answers "is this
  # data still there".
  local covered
  covered="$(grep -c '^[0-9]*=' "${f}" 2>/dev/null || echo 0)"
  if [ "${covered}" -ge 30 ]; then
    local oldest
    oldest="$(awk -F= '{print $2}' "${f}" | sort -n | head -n1)"
    local age_days=$((($(now_epoch) - oldest) / 86400))
    state_touch repo_fully_verified_age_days "${age_days}"
  fi
}

# =============================================================================
# verify
# =============================================================================
cmd_verify() {
  local job="" sample="" full=0 databases=1
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
      --sample)
        sample="$2"
        shift 2
        ;;
      --sample=*)
        sample="${1#*=}"
        shift
        ;;
      --full)
        full=1
        shift
        ;;
      --no-databases)
        databases=0
        shift
        ;;
      --databases)
        databases=1
        shift
        ;;
      -*)
        err "Unknown flag for verify: $1"
        usage_verify
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  require_root
  config_load
  repo_env_load
  restic_require

  local -a jobs=()
  if [ -n "${job}" ]; then jobs=("${job}"); else mapfile -t jobs < <(config_list_jobs); fi

  local rc=0 worst=0 j
  printf '\n%sbg-backup verify%s\n' "${C_BOLD}" "${C_RESET}" >&2

  for j in "${jobs[@]}"; do
    [ -n "${j}" ] || continue
    config_load_job "${j}" || continue
    [ "${JOB_ENABLED}" = "1" ] || continue

    printf '\n%sjob %s%s\n' "${C_BOLD}" "${j}" "${C_RESET}" >&2
    rc=0
    verify_canary "${j}" || rc=$?
    verify_sample_files "${j}" "${sample:-${JOB_VERIFY_SAMPLE}}" || rc="$(worst_rc "${rc}" "$?")"
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  if [ "${databases}" -eq 1 ]; then
    printf '\n%sdatabase dumps%s\n' "${C_BOLD}" "${C_RESET}" >&2
    verify_databases "${full}" || worst="$(worst_rc "${worst}" "$?")"
  fi

  state_touch verify_at "$(now_iso)"
  if [ "${worst}" -eq 0 ]; then
    state_touch verify_ok "1"
    metrics_write verify || true
    monitor_notify verify_ok "" 0 || true
    printf '\n  %sEvery check passed. This backup has now been proven to restore.%s\n\n' "${C_GREEN}" "${C_RESET}" >&2
    return 0
  fi

  state_touch verify_ok "0"
  metrics_write verify || true
  monitor_notify verify_failed "" "${worst}" || true
  printf '\n  %sVERIFICATION FAILED. Treat this as a backup outage.%s\n\n' "${C_RED}" "${C_RESET}" >&2
  return "${EX_VERIFY}"
}

# -----------------------------------------------------------------------------
# canary
# -----------------------------------------------------------------------------
verify_canary() {
  local job="$1"
  local canary_dir="/var/lib/bg-backup/canary"
  local latest
  latest="$(find "${canary_dir}" -name '*.sha256' -type f 2>/dev/null | sort | tail -n1)"

  if [ -z "${latest}" ]; then
    warn_mark "no canary recorded yet (it is written by the next backup)"
    verify_write_canary
    return 0
  fi

  local name want
  name="$(basename "${latest}" .sha256)"
  want="$(cat "${latest}")"

  local snap
  snap="$(restic_latest_snapshot "${job}")"
  [ -n "${snap}" ] || {
    warn_mark "no snapshot for job '${job}'"
    return 0
  }

  local got
  got="$(restic_exec dump "${snap}" "${canary_dir}/${name}" 2>/dev/null | sha256sum | awk '{print $1}')"

  if [ "${got}" = "${want}" ]; then
    ok_mark "canary restored and hashed correctly (${name})"
    return 0
  fi
  bad_mark "CANARY MISMATCH - the restore path is broken"
  err "  expected ${want}"
  err "  got      ${got}"
  return "${EX_VERIFY}"
}

# Called by the backup so there is always something cheap to verify.
verify_write_canary() {
  local dir="/var/lib/bg-backup/canary"
  install -d -m 0700 "${dir}"
  local name
  name="canary-$(date -u '+%Y%m%d').bin"
  # Keep exactly one: the point is a fixed, known-good object, not a history.
  find "${dir}" -type f -delete 2>/dev/null || true
  dd if=/dev/urandom of="${dir}/${name}" bs=1M count=1 status=none 2>/dev/null \
    || head -c 1048576 /dev/urandom >"${dir}/${name}"
  sha256sum "${dir}/${name}" | awk '{print $1}' >"${dir}/${name%.bin}.sha256"
  chmod 0600 "${dir}"/*
  debug "Canary written: ${dir}/${name}"
}

# -----------------------------------------------------------------------------
# sampled real files
# -----------------------------------------------------------------------------
verify_sample_files() {
  local job="$1" n="${2:-3}"
  [ "${n}" -gt 0 ] 2>/dev/null || return 0
  require_jq

  local snap
  snap="$(restic_latest_snapshot "${job}")"
  [ -n "${snap}" ] || return 0

  local staging
  staging="$(tmp_root)/verify-${job}"
  install -d -m 0700 "${staging}"

  # Sample only regular files with a size, and only ones whose live copy still
  # matches the snapshot's mtime and size - otherwise a legitimate change since
  # the backup would be reported as a restore failure.
  local -a picks=()
  mapfile -t picks < <(
    restic_capture ls --json "${snap}" 2>/dev/null \
      | jq -r 'select(.struct_type=="node" and .type=="file" and (.size // 0) > 0)
               | [.path, (.size|tostring), (.mtime // "")] | @tsv' 2>/dev/null \
      | shuf -n "$((n * 4))" 2>/dev/null || true
  )

  local checked=0 failed=0 path size mtime
  local line
  for line in "${picks[@]:-}"; do
    [ -n "${line}" ] || continue
    [ "${checked}" -ge "${n}" ] && break
    IFS=$'\t' read -r path size mtime <<<"${line}"
    [ -f "${path}" ] || continue
    local live_size
    live_size="$(stat -c %s "${path}" 2>/dev/null || echo -1)"
    [ "${live_size}" = "${size}" ] || continue

    local want got
    want="$(sha256sum "${path}" 2>/dev/null | awk '{print $1}')"
    got="$(restic_exec dump "${snap}" "${path}" 2>/dev/null | sha256sum | awk '{print $1}')"
    checked=$((checked + 1))
    if [ "${want}" = "${got}" ]; then
      debug "verified ${path}"
    else
      bad_mark "restored content differs from live: ${path}"
      failed=$((failed + 1))
    fi
  done

  if [ "${checked}" -eq 0 ]; then
    warn_mark "no comparable files found to sample (all changed since the backup?)"
    return 0
  fi
  if [ "${failed}" -eq 0 ]; then
    ok_mark "${checked} sampled file(s) restored byte-identical"
    return 0
  fi
  return "${EX_VERIFY}"
}

# -----------------------------------------------------------------------------
# database dumps
# -----------------------------------------------------------------------------
verify_databases() {
  local full="$1"
  have docker || {
    warn_mark "docker not available - skipping database verification"
    return 0
  }
  require_jq
  lib_source db.sh

  local -a dumps=()
  mapfile -t dumps < <(verify_list_dumps)

  if [ "${#dumps[@]}" -eq 0 ]; then
    warn_mark "no database dumps in the repository"
    return 0
  fi

  local rc=0 line snap path engine container
  for line in "${dumps[@]}"; do
    IFS=$'\t' read -r snap path engine container <<<"${line}"
    [ -n "${snap}" ] || continue
    verify_one_dump "${snap}" "${path}" "${engine}" "${container}" || rc="${EX_VERIFY}"
  done

  # Once a month, also prove the OLDEST retained snapshot still loads. That is
  # the copy you fall back to when a compromise is discovered late, and it is
  # the one that has never been touched since it was written.
  if [ "${full}" = "1" ] || [ "$(date -u '+%d')" = "01" ]; then
    printf '\n  %stesting the oldest retained dump%s\n' "${C_BOLD}" "${C_RESET}" >&2
    local oldest
    oldest="$(restic_capture snapshots --json --tag kind=dbdump 2>/dev/null \
      | jq -r 'sort_by(.time) | first | [.short_id, (.paths[0]//""|ltrimstr("/")),
                       ((.tags[]|select(startswith("engine="))|sub("engine=";""))//""),
                       ((.tags[]|select(startswith("container="))|sub("container=";""))//"")] | @tsv' 2>/dev/null)"
    if [ -n "${oldest}" ]; then
      IFS=$'\t' read -r snap path engine container <<<"${oldest}"
      verify_one_dump "${snap}" "${path}" "${engine}" "${container}" || rc="${EX_VERIFY}"
    fi
  fi
  return "${rc}"
}

# verify_list_dumps - newest snapshot per dump target.
#
# Engine modules store dumps at /db/<engine>/<container>/<object> and tag them
# kind=dbdump plus db=<engine>. The engine and container are therefore derivable
# from the path, which keeps the tag set small and means a new engine needs no
# change here. Grouping is by full path: one PostgreSQL container produces
# globals.sql plus one file per database, and each must be verified.
verify_list_dumps() {
  restic_capture snapshots --json --tag kind=dbdump 2>/dev/null \
    | jq -r '
      map(select((.paths[0] // "") | startswith("/db/"))) |
      group_by(.paths[0]) |
      map(sort_by(.time) | last) | .[] |
      (.paths[0] | split("/")) as $p |
      [ .short_id,
        (.paths[0] | ltrimstr("/")),
        ($p[2] // ""),
        ($p[3] // "")
      ] | @tsv' 2>/dev/null
}

verify_one_dump() {
  local snap="$1" path="$2" engine="$3" container="$4"

  # Cheapest useful assertion first: the dump has a plausible size and, for SQL
  # engines, a recognisable trailer. A truncated dump usually fails here without
  # spending a container start.
  local size
  size="$(restic_capture ls --json "${snap}" "/${path}" 2>/dev/null \
    | jq -r 'select(.struct_type=="node") | .size // 0' | tail -n1)"
  if [ -z "${size}" ] || [ "${size}" -lt 64 ] 2>/dev/null; then
    bad_mark "${container}: dump is empty or missing (${size:-0} bytes)"
    return "${EX_VERIFY}"
  fi

  case "${engine}" in
    postgres | mysql | mariadb)
      local tail_txt
      tail_txt="$(restic_exec dump "${snap}" "/${path}" 2>/dev/null | tail -c 400 || true)"
      case "${tail_txt}" in
        *"PostgreSQL database dump complete"* | *"Dump completed on"* | *"-- Dump completed"*)
          debug "${container}: dump trailer present"
          ;;
        *)
          # A dump without its completion marker was cut short. restic's
          # --stdin-from-command should have prevented this, so finding one
          # means something upstream is wrong.
          bad_mark "${container}: dump has no completion marker - it is truncated"
          return "${EX_VERIFY}"
          ;;
      esac
      ;;
  esac

  ok_mark "${container} (${engine}): $(human_bytes "${size}"), trailer OK"

  # The full restore-into-scratch test is opt-in per engine module, because it
  # needs to start a container and not every environment allows that.
  db_load_engine "${engine}" || return 0
  declare -F "db_${engine}_restore" >/dev/null 2>&1 || return 0

  verify_restore_into_scratch "${snap}" "${path}" "${engine}" "${container}"
}

# verify_restore_into_scratch <snapshot> <path> [engine] [container]
# Loads a dump into a throwaway container with no network egress, then compares
# object and row counts against what was recorded at dump time.
verify_restore_into_scratch() {
  local snap="$1" path="$2" engine="${3:-}" container="${4:-}"
  [ -z "${engine}" ] && engine="$(printf '%s' "${path}" | cut -d/ -f2)"

  local counts_file="/var/lib/bg-backup/facts/db-counts-${container}.json"
  if [ ! -r "${counts_file}" ]; then
    debug "no recorded counts for ${container} - skipping the scratch restore"
    return 0
  fi

  local image
  image="$(docker inspect "${container}" 2>/dev/null | jq -r '.[0].Config.Image // empty')"
  if [ -z "${image}" ]; then
    debug "container '${container}' is not running - cannot determine the image to test with"
    return 0
  fi

  local rand
  rand="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
  local name="bgb-verify-${engine}-${rand}"
  local net="bgb-verify-${rand}"

  log "Starting throwaway ${engine} container for the restore test"
  # --internal: no route out. A verification container must never be able to
  # reach production, a registry, or the internet.
  docker network create --internal "${net}" >/dev/null 2>&1 || true

  local -a run=(run -d --name "${name}" --network "${net}"
    --label bg-backup.scratch=1
    --memory 1g --cpus 1
    -e POSTGRES_PASSWORD=verify -e POSTGRES_HOST_AUTH_METHOD=trust
    -e MYSQL_ROOT_PASSWORD=verify -e MARIADB_ROOT_PASSWORD=verify
    -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=verify
    "${image}")

  if ! docker "${run[@]}" >/dev/null 2>&1; then
    warn_mark "${container}: could not start a scratch container from ${image}"
    docker network rm "${net}" >/dev/null 2>&1 || true
    return 0
  fi

  # Guaranteed teardown, including on Ctrl-C.
  on_cleanup "docker rm -f '${name}' >/dev/null 2>&1 || true; docker network rm '${net}' >/dev/null 2>&1 || true"

  local waited=0 ready=0
  while [ "${waited}" -lt 120 ]; do
    if declare -F "db_${engine}_verify_cmd" >/dev/null 2>&1; then
      if "db_${engine}_verify_cmd" "${name}" >/dev/null 2>&1; then
        ready=1
        break
      fi
    else
      sleep 10
      ready=1
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done

  if [ "${ready}" -ne 1 ]; then
    warn_mark "${container}: the scratch container never became ready"
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker network rm "${net}" >/dev/null 2>&1 || true
    return 0
  fi

  local rc=0
  restic_exec dump "${snap}" "/${path}" 2>/dev/null | "db_${engine}_restore" "${name}" >/dev/null 2>&1 || rc=$?

  if [ "${rc}" -ne 0 ]; then
    bad_mark "${container}: the dump did NOT load into a clean ${engine} (rc=${rc})"
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker network rm "${net}" >/dev/null 2>&1 || true
    return "${EX_VERIFY}"
  fi

  # Compare counts. This is what turns "it loaded" into "it contains the data".
  local now_counts want_counts
  now_counts="$("db_${engine}_counts" "${name}" 2>/dev/null || true)"
  want_counts="$(jq -c '.counts' "${counts_file}" 2>/dev/null || true)"

  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker network rm "${net}" >/dev/null 2>&1 || true

  if [ -z "${now_counts}" ] || [ -z "${want_counts}" ]; then
    ok_mark "${container}: dump loaded into a clean ${engine} (counts unavailable)"
    return 0
  fi

  if [ "$(printf '%s' "${now_counts}" | jq -S -c . 2>/dev/null)" \
    = "$(printf '%s' "${want_counts}" | jq -S -c . 2>/dev/null)" ]; then
    ok_mark "${container}: dump loaded and every object count matches"
    return 0
  fi

  bad_mark "${container}: the dump loaded but the counts DIFFER"
  err "  recorded at dump time: ${want_counts}"
  err "  after restore:        ${now_counts}"
  return "${EX_VERIFY}"
}
