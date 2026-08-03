#!/usr/bin/env bash
# =============================================================================
# bg-backup - discover: what does this host actually have?
# =============================================================================
# Run before writing any configuration, and again whenever a stack is added.
# It answers the questions an operator would otherwise answer from memory, and
# gets wrong:
#
#   * is /var/lib/docker on its own filesystem? (the --one-file-system trap)
#   * can this host take an LVM/btrfs/ZFS snapshot, and is there room?
#   * which compose projects exist, and where are their files?
#   * which containers are databases, and which dump command applies?
#   * which images exist ONLY here and therefore cannot be pulled on restore?
#
# --write emits proposed conf.d files as *.proposed. It never overwrites live
# configuration: a discovery run on a Tuesday must not silently change what gets
# backed up on Tuesday night.
# =============================================================================

[ -n "${_BGB_DISCOVER_SOURCED:-}" ] && return 0
_BGB_DISCOVER_SOURCED=1

cmd_discover() {
  local write=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --write)
        write=1
        shift
        ;;
      -*)
        err "Unknown flag for discover: $1"
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  config_load

  # config_load() reads the GLOBAL configuration; it does not populate the JOB_*
  # surface, because a job's settings only exist once a job is selected.
  # `discover` has no job, yet it calls straight into docker_collect_paths(),
  # which dereferences JOB_DOCKER_INCLUDE_COMPOSE_FILES and friends. Under
  # `set -u` those are unbound, and because the call happens inside a process
  # substitution the abort surfaced as an empty result rather than an error -
  # `discover` printed no Docker paths at all and looked like a host with
  # nothing to back up.
  job_defaults_reset

  if [ "${BGB_JSON}" = "1" ]; then
    discover_json
    return 0
  fi

  printf '\n%sbg-backup discover%s  %s\n' "${C_BOLD}" "${C_RESET}" "$(fqdn)"

  discover_system
  discover_filesystems
  discover_snapshot_capability
  discover_docker
  discover_databases
  discover_sizes

  [ "${write}" = "1" ] && discover_write_proposals
  printf '\n'
}

# -----------------------------------------------------------------------------
discover_system() {
  printf '\n%sSystem%s\n' "${C_BOLD}" "${C_RESET}"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  printf '  os           %s %s (%s)\n' "${NAME:-?}" "${VERSION_ID:-?}" "${VERSION_CODENAME:-?}"
  printf '  kernel       %s\n' "$(uname -r)"
  printf '  arch         %s\n' "$(uname -m)"
  printf '  hostname     %s\n' "$(fqdn)"
  printf '  timezone     %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
  printf '  packages     %s manually installed\n' "$(apt-mark showmanual 2>/dev/null | grep -c '^' || echo '?')"
  printf '  units        %s enabled\n' "$(systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | grep -c '^' || echo '?')"
}

discover_filesystems() {
  printf '\n%sFilesystems%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  %-24s %-12s %8s %8s  %s\n' "MOUNTPOINT" "DEVICE" "SIZE" "USED" "TYPE"
  while read -r src size used _ _ mp; do
    printf '  %-24s %-12s %8s %8s\n' "${mp}" "$(basename "${src}")" "${size}" "${used}"
  done < <(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

  # THE trap from the full-server runbook, checked rather than remembered.
  local root_dev docker_dev
  root_dev="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
  docker_dev="$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2{print $1}')"
  if [ -n "${docker_dev}" ] && [ "${docker_dev}" != "${root_dev}" ]; then
    printf '\n  %s!%s /var/lib/docker is on a SEPARATE filesystem (%s)\n' "${C_YELLOW}" "${C_RESET}" "${docker_dev}"
    printf '    With --one-file-system a root backup SKIPS it silently.\n'
    printf '    Either add it to JOB_EXTRA_PATHS or use a docker-mode job.\n'
  fi
}

discover_snapshot_capability() {
  printf '\n%sSnapshot capability%s\n' "${C_BOLD}" "${C_RESET}"
  local found=0

  if have vgs; then
    local vg free
    while read -r vg free; do
      [ -n "${vg}" ] || continue
      found=1
      printf '  lvm          VG %-16s %s free\n' "${vg}" "${free}"
      case "${free}" in
        0* | "") printf '    %s!%s no free extents - an LVM snapshot cannot be created\n' "${C_YELLOW}" "${C_RESET}" ;;
      esac
    done < <(vgs --noheadings -o vg_name,vg_free --units g 2>/dev/null | awk '{print $1, $2}')
  fi

  if have btrfs && btrfs filesystem show >/dev/null 2>&1; then
    found=1
    printf '  btrfs        available\n'
  fi
  if have zfs && zfs list >/dev/null 2>&1; then
    found=1
    printf '  zfs          available\n'
  fi

  if [ "${found}" -eq 0 ]; then
    printf '  none         no LVM/btrfs/ZFS - JOB_QUIESCE=lvm is unavailable\n'
    printf '               Use docker-pause (seconds of freeze) instead.\n'
  fi
}

discover_docker() {
  have docker || {
    printf '\n%sDocker%s\n  not installed\n' "${C_BOLD}" "${C_RESET}"
    return 0
  }
  if ! docker info >/dev/null 2>&1; then
    printf '\n%sDocker%s\n  daemon not reachable\n' "${C_BOLD}" "${C_RESET}"
    return 0
  fi
  require_jq

  printf '\n%sDocker%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  version      %s (storage driver: %s)\n' \
    "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
    "$(docker info --format '{{.Driver}}' 2>/dev/null)"

  local projects
  projects="$(docker compose ls --all --format json 2>/dev/null || echo '[]')"
  local n
  n="$(printf '%s' "${projects}" | jq 'length')"
  printf '  projects     %s\n' "${n}"

  local p
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    printf '\n  %sproject %s%s\n' "${C_BOLD}" "${p}" "${C_RESET}"
    printf '    config     %s\n' "$(printf '%s' "${projects}" | jq -r --arg n "${p}" '.[] | select(.Name==$n) | .ConfigFiles // ""')"
    local c
    while IFS= read -r c; do
      [ -n "${c}" ] || continue
      printf '    container  %-28s %s\n' \
        "$(docker inspect "${c}" | jq -r '.[0].Name' | sed 's|^/||')" \
        "$(docker inspect "${c}" | jq -r '.[0].Config.Image')"
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${p}")

    local -a paths=()
    lib_source docker.sh
    mapfile -t paths < <(docker_collect_paths "${p}" 2>/dev/null | sort -u)
    if [ "${#paths[@]}" -gt 0 ]; then
      printf '    paths      %s\n' "${#paths[@]} host path(s) would be backed up"
      local q
      for q in "${paths[@]:0:8}"; do printf '               %s\n' "${q}"; done
      [ "${#paths[@]}" -gt 8 ] && printf '               ... and %s more\n' "$((${#paths[@]} - 8))"
    fi
  done < <(printf '%s' "${projects}" | jq -r '.[].Name // empty')

  # Images that exist only here cannot be pulled during a restore. This is the
  # single most common way an otherwise-correct Docker backup turns out to be
  # unrestorable, and it is invisible until the restore.
  printf '\n  %simages without a registry digest%s\n' "${C_BOLD}" "${C_RESET}"
  local c tag missing=0
  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    tag="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Config.Image // empty')"
    [ -n "${tag}" ] || continue
    if ! docker image inspect "${tag}" 2>/dev/null | jq -e '.[0].RepoDigests[0]' >/dev/null 2>&1; then
      printf '    %s!%s %s (built locally, never pushed)\n' "${C_YELLOW}" "${C_RESET}" "${tag}"
      missing=$((missing + 1))
    fi
  done < <(docker ps -q 2>/dev/null || true)
  if [ "${missing}" -eq 0 ]; then
    printf '    none - every running image can be pulled again\n'
  else
    printf '    %s image(s) must be exported: set JOB_DOCKER_EXPORT_IMAGES=missing\n' "${missing}"
  fi
}

discover_databases() {
  have docker || return 0
  docker info >/dev/null 2>&1 || return 0
  lib_source db.sh

  printf '\n%sDatabases%s\n' "${C_BOLD}" "${C_RESET}"

  # discover runs before any job is loaded, so give the planner a permissive
  # default rather than an empty engine list.
  JOB_DB_ENGINES=(postgres mariadb mysql mongodb redis influxdb clickhouse elasticsearch mssql)
  JOB_DB_EXCLUDE_CONTAINERS=()

  local -a plan=()
  mapfile -t plan < <(db_plan 2>/dev/null || true)

  if [ "${#plan[@]}" -eq 0 ]; then
    printf '  none detected\n'
    return 0
  fi

  printf '  %-28s %-14s %-10s %s\n' "CONTAINER" "ENGINE" "TIER" "DUMP"
  local line c name engine tier
  for line in "${plan[@]}"; do
    IFS=$'\t' read -r c name engine tier <<<"${line}"
    local notes=""
    if declare -F "db_${engine}_notes" >/dev/null 2>&1; then
      notes="$("db_${engine}_notes" 2>/dev/null | head -n1)"
    fi
    printf '  %-28s %-14s %-10s %s\n' "${name}" "${engine}" "${tier}" "${notes}"
  done
  printf '\n  Each of these is dumped with restic --stdin-from-command, so a failed\n'
  printf '  dump aborts the backup instead of storing a truncated file.\n'
}

discover_sizes() {
  printf '\n%sEstimated backup size%s\n' "${C_BOLD}" "${C_RESET}"
  local total=0 p sz
  for p in /etc /root /home /opt /srv /var/www /data /var/docker; do
    [ -d "${p}" ] || continue
    sz="$(du -sb "${p}" 2>/dev/null | awk '{print $1}')"
    [ -n "${sz}" ] || continue
    printf '  %-16s %s\n' "${p}" "$(human_bytes "${sz}")"
    total=$((total + sz))
  done
  if [ -d /var/lib/docker/volumes ]; then
    sz="$(du -sb /var/lib/docker/volumes 2>/dev/null | awk '{print $1}')"
    [ -n "${sz}" ] && {
      printf '  %-16s %s\n' "docker volumes" "$(human_bytes "${sz}")"
      total=$((total + sz))
    }
  fi
  printf '  %-16s %s (before deduplication and compression)\n' "TOTAL" "$(human_bytes "${total}")"
}

# -----------------------------------------------------------------------------
discover_write_proposals() {
  local out="${BGB_CONFDIR}/conf.d"
  install -d -m 0750 "${out}"

  local has_docker=0
  have docker && docker info >/dev/null 2>&1 && has_docker=1

  local src="${BGB_SHARE_DIR}/config/conf.d"
  local f target
  for f in "${src}"/*.conf.example; do
    [ -e "${f}" ] || continue
    local base
    base="$(basename "${f}" .conf.example)"
    [ "${base}" = "20-docker" ] && [ "${has_docker}" -eq 0 ] && continue
    target="${out}/${base}.conf"
    if [ -e "${target}" ]; then
      target="${target}.proposed"
    fi
    install -m 0640 "${f}" "${target}"
    log "Wrote ${target}"
  done

  printf '\n  Proposals written as *.proposed where a live file already existed.\n'
  printf '  Review, then rename. Nothing that runs tonight has been changed.\n'
}

discover_json() {
  require_jq
  local body

  body="$(printf '%s' '"system":{')"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  body+="$(json_kv os_id "${ID:-}"),"
  body+="$(json_kv os_version "${VERSION_ID:-}"),"
  body+="$(json_kv os_codename "${VERSION_CODENAME:-}"),"
  body+="$(json_kv kernel "$(uname -r)"),"
  body+="$(json_kv arch "$(uname -m)")"
  body+='},'

  local root_dev docker_dev
  root_dev="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
  docker_dev="$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2{print $1}')"
  body+='"filesystems":{'
  body+="$(json_kv root_device "${root_dev}"),"
  body+="$(json_kv docker_device "${docker_dev}"),"
  body+="$(json_kvraw docker_separate_mount "$(json_bool "$([ -n "${docker_dev}" ] && [ "${docker_dev}" != "${root_dev}" ] && echo 1 || echo 0)")")"
  body+='},'

  local projects='[]' dbs='[]'
  if have docker && docker info >/dev/null 2>&1; then
    projects="$(docker compose ls --all --format json 2>/dev/null || echo '[]')"
    lib_source db.sh
    JOB_DB_ENGINES=(postgres mariadb mysql mongodb redis influxdb clickhouse elasticsearch mssql)
    JOB_DB_EXCLUDE_CONTAINERS=()
    dbs='['
    local first=1 line c name engine tier
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      IFS=$'\t' read -r c name engine tier <<<"${line}"
      [ "${first}" -eq 0 ] && dbs+=","
      first=0
      dbs+="{$(json_kv container "${name}"),$(json_kv engine "${engine}"),$(json_kv tier "${tier}")}"
    done < <(db_plan 2>/dev/null || true)
    dbs+=']'
  fi
  body+="$(json_kvraw compose_projects "${projects}"),"
  body+="$(json_kvraw databases "${dbs}")"

  json_envelope ok "${body}"
}
