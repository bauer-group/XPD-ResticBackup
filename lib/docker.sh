#!/usr/bin/env bash
# =============================================================================
# bg-backup - docker: application-level backup of compose projects
# =============================================================================
# What is backed up, and why NOT /var/lib/docker:
#
#   Restoring overlay2 and the image store ties the restore to the exact Docker
#   version and storage driver of the machine that produced it. The requirement
#   here is "restorable onto a freshly installed Linux base system", and that is
#   precisely what an image-level backup cannot promise.
#
#   So instead: compose files, .env and every resolved env_file, named volume
#   contents, bind-mount sources, image DIGESTS, network SUBNETS, and logical
#   database dumps. A restore is then "install Docker, put the files back,
#   compose pull && up, load the dumps" - which works on any host.
#
# Two details that look minor and are not:
#
#   * Image digests, not tags. `compose up` re-resolves :latest, so without a
#     digest the restore silently brings up a different version than the one the
#     data was written by.
#   * Network subnets. If they are not recreated explicitly, Docker assigns new
#     ones from its address pool and every firewall rule or ACL that referenced
#     the old subnet stops matching - silently.
# =============================================================================

[ -n "${_BGB_DOCKER_SOURCED:-}" ] && return 0
_BGB_DOCKER_SOURCED=1

docker_require() {
  have docker || die "${EX_PRECOND}" "docker is not installed"
  docker info >/dev/null 2>&1 || die "${EX_PRECOND}" "Cannot talk to the Docker daemon (is it running?)"
  require_jq
}

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
  elif have docker-compose; then
    # Compose v1. Supported for discovery only; it has no `ls --format json`.
    printf 'docker-compose'
  else
    printf ''
  fi
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------
# docker_list_projects - JSON array of {Name, Status, ConfigFiles}
docker_list_projects() {
  docker compose ls --all --format json 2>/dev/null || printf '[]'
}

# docker_project_containers <project> - container IDs of a compose project
docker_project_containers() {
  local project="$1"
  docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true
}

# docker_container_json <id>
docker_container_json() {
  docker inspect "$1" 2>/dev/null | jq '.[0]' 2>/dev/null || printf '{}'
}

# docker_container_mounts <id> - one "type<TAB>source<TAB>destination<TAB>name" per line
docker_container_mounts() {
  docker inspect "$1" 2>/dev/null \
    | jq -r '.[0].Mounts[]? | [.Type, (.Source // ""), (.Destination // ""), (.Name // "")] | @tsv' \
    2>/dev/null || true
}

# docker_volume_mountpoint <name>
docker_volume_mountpoint() {
  docker volume inspect "$1" 2>/dev/null | jq -r '.[0].Mountpoint // empty' 2>/dev/null || true
}

# docker_image_ref <container> - repo@sha256:... when a digest exists, else the tag
docker_image_ref() {
  local c="$1" digest tag
  digest="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Image // empty')"
  tag="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Config.Image // empty')"
  local repo_digest
  repo_digest="$(docker image inspect "${tag}" 2>/dev/null | jq -r '.[0].RepoDigests[0] // empty')"
  if [ -n "${repo_digest}" ]; then printf '%s' "${repo_digest}"; else printf '%s' "${digest:-${tag}}"; fi
}

# docker_image_has_digest <image-tag>
docker_image_has_digest() {
  local tag="$1" d
  d="$(docker image inspect "${tag}" 2>/dev/null | jq -r '.[0].RepoDigests[0] // empty')"
  [ -n "${d}" ]
}

# -----------------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------------
# The manifest is what `dr plan` reads to rebuild the stack. It is written to the
# facts directory and swept up by the backup as an ordinary file.
docker_write_manifest() {
  local out="$1"
  local projects p containers c
  install -d -m 0700 "$(dirname "${out}")"

  projects="$(docker_list_projects)"

  {
    printf '{'
    json_kv generated "$(now_iso)"; printf ','
    json_kv host "${BGB_HOSTNAME}"; printf ','
    json_kv docker_version "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"; printf ','
    json_kvraw storage_driver "$(json_str "$(docker info --format '{{.Driver}}' 2>/dev/null || echo unknown)")"; printf ','

    printf '"projects":['
    local first_p=1
    while IFS= read -r p; do
      [ -n "${p}" ] || continue
      [ "${first_p}" -eq 0 ] && printf ','
      first_p=0
      docker_project_manifest "${p}" "${projects}"
    done < <(printf '%s' "${projects}" | jq -r '.[].Name // empty')
    printf '],'

    printf '"networks":['
    local first_n=1 n
    while IFS= read -r n; do
      [ -n "${n}" ] || continue
      [ "${first_n}" -eq 0 ] && printf ','
      first_n=0
      docker network inspect "${n}" 2>/dev/null \
        | jq -c '.[0] | {name: .Name, driver: .Driver, scope: .Scope,
                         internal: .Internal, attachable: .Attachable,
                         ipam: .IPAM, labels: .Labels, options: .Options}' \
        2>/dev/null || printf '{}'
    done < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -vx 'bridge\|host\|none' || true)
    printf '],'

    printf '"volumes":['
    local first_v=1 v
    while IFS= read -r v; do
      [ -n "${v}" ] || continue
      [ "${first_v}" -eq 0 ] && printf ','
      first_v=0
      docker volume inspect "${v}" 2>/dev/null \
        | jq -c '.[0] | {name: .Name, driver: .Driver, options: .Options,
                         labels: .Labels, mountpoint: .Mountpoint}' \
        2>/dev/null || printf '{}'
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
    printf ']'
    printf '}\n'
  } | atomic_write "${out}" 0600

  log "Docker manifest written: ${out}"
}

docker_project_manifest() {
  local project="$1" projects="$2" c
  printf '{'
  json_kv name "${project}"; printf ','
  json_kvraw config_files "$(printf '%s' "${projects}" \
    | jq -c --arg n "${project}" '[.[] | select(.Name==$n) | .ConfigFiles] | .[0] // "" | split(",")' 2>/dev/null || printf '[]')"; printf ','
  json_kv status "$(printf '%s' "${projects}" | jq -r --arg n "${project}" '.[] | select(.Name==$n) | .Status // ""')"; printf ','

  printf '"containers":['
  local first=1
  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    [ "${first}" -eq 0 ] && printf ','
    first=0
    docker inspect "${c}" 2>/dev/null | jq -c '.[0] | {
      id: .Id[0:12],
      name: (.Name | ltrimstr("/")),
      image: .Config.Image,
      image_id: .Image,
      service: (.Config.Labels["com.docker.compose.service"] // ""),
      working_dir: (.Config.Labels["com.docker.compose.project.working_dir"] // ""),
      config_files: (.Config.Labels["com.docker.compose.project.config_files"] // ""),
      restart_policy: .HostConfig.RestartPolicy.Name,
      ports: .HostConfig.PortBindings,
      mounts: [.Mounts[]? | {type: .Type, source: .Source, destination: .Destination, name: .Name, rw: .RW}],
      networks: (.NetworkSettings.Networks | keys),
      labels: .Config.Labels,
      state: .State.Status,
      health: (.State.Health.Status // "none")
    }' 2>/dev/null || printf '{}'
  done < <(docker_project_containers "${project}")
  printf ']}'
}

# -----------------------------------------------------------------------------
# Path collection
# -----------------------------------------------------------------------------
# docker_collect_paths <project> - every host path this project needs restored,
# one per line, deduplicated by the caller.
docker_collect_paths() {
  local project="$1" c type src dst name mp cf dir

  # Compose files and their directory (which also picks up .env sitting beside
  # them - the single most commonly forgotten file in a Docker restore).
  if [ "${JOB_DOCKER_INCLUDE_COMPOSE_FILES}" = "1" ]; then
    while IFS= read -r c; do
      [ -n "${c}" ] || continue
      cf="$(docker inspect "${c}" 2>/dev/null \
            | jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty')"
      dir="$(docker inspect "${c}" 2>/dev/null \
            | jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty')"
      [ -n "${dir}" ] && [ -d "${dir}" ] && printf '%s\n' "${dir}"
      local f
      IFS=',' read -r -a __cfs <<<"${cf}"
      for f in "${__cfs[@]:-}"; do
        [ -n "${f}" ] && [ -e "${f}" ] && printf '%s\n' "${f}"
      done
    done < <(docker_project_containers "${project}")
  fi

  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    while IFS=$'\t' read -r type src dst name; do
      case "${type}" in
        volume)
          [ "${JOB_DOCKER_INCLUDE_NAMED_VOLUMES}" = "1" ] || continue
          [ -n "${name}" ] || continue
          mp="$(docker_volume_mountpoint "${name}")"
          [ -n "${mp}" ] && [ -d "${mp}" ] && printf '%s\n' "${mp}"
          ;;
        bind)
          [ "${JOB_DOCKER_INCLUDE_BIND_MOUNTS}" = "1" ] || continue
          [ -n "${src}" ] || continue
          # Never follow a bind mount of a system path into the backup: someone
          # mounting /etc or / into a container must not silently double the
          # backup or pull in paths the system job already excludes.
          case "${src}" in
            /|/etc|/usr|/var|/var/lib|/var/lib/docker|/proc|/sys|/dev|/run)
              warn "Skipping suspicious bind mount source: ${src} (container ${c:0:12})"
              continue ;;
          esac
          [ -e "${src}" ] && printf '%s\n' "${src}"
          ;;
      esac
    done < <(docker_container_mounts "${c}")
  done < <(docker_project_containers "${project}")

  return 0
}

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
docker_backup_run() {
  local job="$1" run_id="$2"; shift 2
  local -a extra_tags=("$@")
  local rc=0 worst=0 project

  docker_require

  local factsdir="/var/lib/bg-backup/facts"
  install -d -m 0700 "${factsdir}"

  # --- 1. Manifest first ----------------------------------------------------
  # Written before anything is paused, so it records the intended running state
  # rather than the frozen one.
  if [ "${JOB_DOCKER_IMAGE_MANIFEST}" = "1" ] || [ "${JOB_DOCKER_NETWORK_MANIFEST}" = "1" ]; then
    docker_write_manifest "${factsdir}/docker-manifest.json"
  fi

  # --- 2. Warn about unrecoverable images -----------------------------------
  docker_warn_local_images

  # --- 3. Database dumps ----------------------------------------------------
  # Dumps run BEFORE the file backup and while everything is still running:
  # a logical dump needs a live server, and it is transactionally consistent in
  # its own right, so it does not need the quiesce window.
  if [ "${JOB_DB_DUMP}" = "1" ]; then
    db_dump_all "${job}" "${run_id}" || worst="$(worst_rc "${worst}" "$?")"
  fi

  # --- 4. Export images that exist nowhere else ------------------------------
  if [ "${JOB_DOCKER_EXPORT_IMAGES}" != "none" ]; then
    docker_export_images "${job}" "${run_id}" || warn "Image export failed (non-fatal)"
  fi

  # --- 5. Files, per project, each with its own short quiesce window ---------
  local -a projects=()
  mapfile -t projects < <(docker_select_projects)

  if [ "${#projects[@]}" -eq 0 ]; then
    warn "No compose projects discovered - backing up the extra paths only"
  fi

  local -a all_paths=()
  for project in "${projects[@]}"; do
    [ -n "${project}" ] || continue
    log "Collecting paths for compose project '${project}'"
    while IFS= read -r p; do
      [ -n "${p}" ] && all_paths+=("${p}")
    done < <(docker_collect_paths "${project}")
  done

  local p
  for p in "${JOB_DOCKER_EXTRA_PATHS[@]:-}"; do
    [ -n "${p}" ] && [ -e "${p}" ] && all_paths+=("${p}")
  done
  all_paths+=("${factsdir}")

  if [ "${JOB_DOCKER_INCLUDE_OVERLAY2}" = "1" ]; then
    warn "JOB_DOCKER_INCLUDE_OVERLAY2=1: including /var/lib/docker (much larger, restore is version-bound)"
    all_paths+=("/var/lib/docker")
  fi

  # Deduplicate and drop paths nested inside another selected path.
  local -a paths=()
  mapfile -t paths < <(docker_dedup_paths "${all_paths[@]:-}")

  if [ "${#paths[@]}" -eq 0 ]; then
    warn "No Docker paths to back up"
    return "${worst}"
  fi

  # The quiesce window covers only the file read, not the dumps above.
  local -a filter=()
  if [ "${JOB_QUIESCE_SCOPE}" = "host" ]; then
    filter=()
  else
    for project in "${projects[@]}"; do
      [ -n "${project}" ] && filter+=(--filter "label=com.docker.compose.project=${project}")
    done
  fi
  quiesce_begin "${job}" "${filter[@]:-}"

  local -a args=(backup --host "${BGB_HOSTNAME}" --json)
  mapfile -t -O "${#args[@]}" args < <(restic_tag_args "${job}" "${run_id}" "${JOB_TAGS[@]:-}" "${extra_tags[@]:-}")
  args+=(--tag "kind=files")
  [ "${JOB_EXCLUDE_CACHES}" = "1" ] && args+=(--exclude-caches)
  if [ -n "${JOB_EXCLUDE_FILE}" ] && [ -r "${JOB_EXCLUDE_FILE}" ]; then
    args+=(--exclude-file "${JOB_EXCLUDE_FILE}")
  fi
  local e
  for e in "${JOB_EXCLUDES[@]:-}"; do
    [ -n "${e}" ] && args+=(--exclude "${e}")
  done
  args+=("${paths[@]}")

  local jsonl; jsonl="$(tmp_file "docker.XXXXXX.jsonl")"
  log "Backing up ${#paths[@]} Docker path(s)"
  rc=0
  set +e
  restic_exec "${args[@]}" | tee -a "${jsonl}" >>"${BGB_JOB_LOG}"
  rc="${PIPESTATUS[0]}"
  set -e

  quiesce_end "${job}" || true

  backup_absorb_summary "${jsonl}" "${rc}"
  local mapped=0
  restic_map_rc "${rc}" || mapped=$?
  worst="$(worst_rc "${worst}" "${mapped}")"
  return "${worst}"
}

docker_select_projects() {
  local p
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    if [ "${#JOB_DOCKER_PROJECTS[@]}" -gt 0 ]; then
      local want found=0 w
      for w in "${JOB_DOCKER_PROJECTS[@]}"; do
        [ "${w}" = "${p}" ] && found=1
      done
      [ "${found}" -eq 1 ] || continue
    fi
    local x skip=0
    for x in "${JOB_DOCKER_EXCLUDE_PROJECTS[@]:-}"; do
      [ "${x}" = "${p}" ] && skip=1
    done
    [ "${skip}" -eq 1 ] && continue
    printf '%s\n' "${p}"
  done < <(docker_list_projects | jq -r '.[].Name // empty')
}

# docker_dedup_paths <paths...> - sort, unique, and drop any path that is
# already covered by an ancestor. Passing both /opt/app and /opt/app/data to
# restic stores the nested tree twice in the snapshot's path list.
docker_dedup_paths() {
  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "$@" | grep -v '^$' | sort -u)
  local prev="" p
  for p in "${sorted[@]:-}"; do
    [ -n "${p}" ] || continue
    if [ -n "${prev}" ] && [ "${p#"${prev}"/}" != "${p}" ]; then
      continue
    fi
    printf '%s\n' "${p}"
    prev="${p}"
  done
}

# -----------------------------------------------------------------------------
# Images
# -----------------------------------------------------------------------------
docker_warn_local_images() {
  local c tag missing=0
  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    tag="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Config.Image // empty')"
    [ -n "${tag}" ] || continue
    if ! docker_image_has_digest "${tag}"; then
      warn "Image '${tag}' has no registry digest (built locally, never pushed)"
      missing=$(( missing + 1 ))
    fi
  done < <(docker ps -q 2>/dev/null || true)

  if [ "${missing}" -gt 0 ]; then
    warn "${missing} running container(s) use an image that exists only on this host."
    warn "They cannot be pulled during a restore. JOB_DOCKER_EXPORT_IMAGES=${JOB_DOCKER_EXPORT_IMAGES}"
    [ "${JOB_DOCKER_EXPORT_IMAGES}" = "none" ] && \
      warn "With EXPORT_IMAGES=none these stacks are NOT restorable. Set it to 'missing'."
  fi
}

docker_export_images() {
  local job="$1" run_id="$2"
  local c tag rc=0

  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    tag="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Config.Image // empty')"
    [ -n "${tag}" ] || continue

    if [ "${JOB_DOCKER_EXPORT_IMAGES}" = "missing" ] && docker_image_has_digest "${tag}"; then
      continue
    fi

    local safe; safe="$(printf '%s' "${tag}" | tr -c 'A-Za-z0-9._-' '_')"
    log "Exporting image ${tag} into the repository"
    # --stdin-from-command so a failing `docker save` aborts instead of storing
    # a truncated tar that looks like a valid backup.
    restic_exec backup \
      --stdin-from-command \
      --stdin-filename "images/${safe}.tar" \
      --host "${BGB_HOSTNAME}" \
      --tag "bg-backup=1" --tag "job=${job}" --tag "run=${run_id}" \
      --tag "kind=image" --tag "image=${tag}" \
      -- docker save "${tag}" >>"${BGB_JOB_LOG}" 2>&1 || rc=$?
  done < <(docker ps -q 2>/dev/null || true)
  return "${rc}"
}
