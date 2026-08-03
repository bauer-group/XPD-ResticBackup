#!/usr/bin/env bash
# =============================================================================
# bg-backup - doctor: preflight and health checks
# =============================================================================
# House style (IAC-Cloud/scripts/doctor.sh, IAC-NixOS/scripts/health-check.sh):
# one line per check, ✓ / ! / ✗, a summary, and a non-zero exit only on ✗.
#
# The checks that earn their keep are the ones encoding a trap that has actually
# bitten someone:
#   * the repository prefix must end with this host's FQDN (shared bucket)
#   * /var/lib/docker on its own mount while --one-file-system is set
#   * two jobs scheduled closely enough that both quiesce Docker
#   * the recovery card has been acknowledged
#   * the recovery bundle still matches the deployed configuration
# =============================================================================

[ -n "${_BGB_DOCTOR_SOURCED:-}" ] && return 0
_BGB_DOCTOR_SOURCED=1

_DOC_PASS=0
_DOC_WARN=0
_DOC_FAIL=0
_DOC_JSON=()

_doc_ok() {
  _DOC_PASS=$((_DOC_PASS + 1))
  ok_mark "$1"
  _doc_record ok "$1" "${2:-}"
}
_doc_warn() {
  _DOC_WARN=$((_DOC_WARN + 1))
  warn_mark "$1"
  _doc_record warn "$1" "${2:-}"
}
_doc_fail() {
  _DOC_FAIL=$((_DOC_FAIL + 1))
  bad_mark "$1"
  _doc_record fail "$1" "${2:-}"
}

_doc_record() {
  _DOC_JSON+=("$(
    printf '{'
    json_kv status "$1"
    printf ','
    json_kv check "$2"
    printf ','
    json_kv detail "${3:-}"
    printf '}'
  )")
}

_doc_section() { printf '\n%s%s%s\n' "${C_BOLD}" "$1" "${C_RESET}" >&2; }

cmd_doctor() {
  local fix=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix)
        fix=1
        shift
        ;;
      -*)
        err "Unknown flag for doctor: $1"
        usage_doctor
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  printf '\n%sbg-backup doctor%s  (%s)\n' "${C_BOLD}" "${C_RESET}" "$(fqdn)" >&2

  doctor_check_environment "${fix}"
  doctor_check_installation "${fix}"
  doctor_check_configuration "${fix}"
  doctor_check_repository
  doctor_check_jobs
  doctor_check_schedules
  doctor_check_docker
  doctor_check_recovery
  doctor_check_monitoring

  doctor_summary
}

# -----------------------------------------------------------------------------
doctor_check_environment() {
  local fix="$1"
  _doc_section "Environment"

  if [ "$(id -u)" -eq 0 ]; then
    _doc_ok "running as root"
  else
    _doc_warn "not running as root - most checks will be incomplete"
  fi

  local bashver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if [ "${BASH_VERSINFO[0]}" -ge 5 ]; then
    _doc_ok "bash ${bashver}"
  else
    _doc_fail "bash ${bashver} is too old (5.0+ required)"
  fi

  if have jq; then
    _doc_ok "jq $(jq --version 2>/dev/null | sed 's/jq-//')"
  else
    _doc_fail "jq is missing - JSON output, discovery and Docker mode are unavailable" \
      "apt-get install -y jq"
  fi

  local c
  for c in curl tar; do
    have "${c}" && _doc_ok "${c} present" || _doc_fail "${c} is missing"
  done
  have openssl && _doc_ok "openssl present" || _doc_warn "openssl missing - the recovery bundle loses one of its three encryption paths"
  have age && _doc_ok "age present" || _doc_warn "age missing - the recovery bundle falls back to gpg/openssl"
  have gpg && _doc_ok "gpg present" || _doc_warn "gpg missing"
  have fusermount3 && _doc_ok "fuse3 present" || _doc_warn "fuse3 missing - 'bg-backup mount' unavailable"

  if have systemctl; then
    _doc_ok "systemd present"
  else
    _doc_warn "systemd not present - scheduling is unavailable"
  fi

  # Clock skew matters more here than it looks: restic snapshot times, retention
  # windows and SLA alerts are all wall-clock based.
  if have timedatectl; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
      _doc_ok "clock is NTP synchronised"
    else
      _doc_warn "clock is not NTP synchronised - retention and SLA checks use wall-clock time"
    fi
  fi

  if [ "${fix}" = "1" ]; then
    install -d -m 0750 "${BGB_LOG_DIR}" 2>/dev/null || true
    install -d -m 0700 "${BGB_STATE_DIR}" 2>/dev/null || true
  fi
}

doctor_check_installation() {
  local fix="$1"
  _doc_section "Installation"

  if [ -x "${BGB_RESTIC_BIN}" ]; then
    local v
    v="$(restic_version)"
    if version_ge "${v}" "${BGB_RESTIC_MIN_VERSION}"; then
      _doc_ok "restic ${v} at ${BGB_RESTIC_BIN}"
    else
      _doc_fail "restic ${v} is older than the required ${BGB_RESTIC_MIN_VERSION}" \
        "distribution packages are too old (22.04 ships 0.12.1, 24.04 ships 0.16.4)"
    fi
  else
    _doc_fail "restic not found at ${BGB_RESTIC_BIN}"
  fi

  if [ -L /usr/local/sbin/bg-backup ]; then
    _doc_ok "bg-backup symlink -> $(readlink -f /usr/local/sbin/bg-backup 2>/dev/null)"
  else
    _doc_warn "/usr/local/sbin/bg-backup is not a symlink into the release directory"
  fi

  local d
  for d in "${BGB_LOG_DIR}" "${BGB_STATE_DIR}" "${BGB_CACHE_DIR}"; do
    if [ -d "${d}" ]; then
      _doc_ok "directory ${d}"
    else
      if [ "${fix}" = "1" ]; then
        install -d -m 0700 "${d}" && _doc_ok "created ${d}"
      else
        _doc_warn "missing directory: ${d} (doctor --fix creates it)"
      fi
    fi
  done

  # Free space for the restic cache. A full cache filesystem makes restic fail
  # in ways that look like repository corruption.
  if [ -d "${BGB_CACHE_DIR}" ]; then
    local avail_kb
    avail_kb="$(df -Pk "${BGB_CACHE_DIR}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "${avail_kb}" ] && [ "${avail_kb}" -lt 1048576 ]; then
      _doc_warn "less than 1 GiB free on the cache filesystem ($(human_bytes $((avail_kb * 1024))))"
    else
      _doc_ok "cache filesystem has $(human_bytes $((${avail_kb:-0} * 1024))) free"
    fi
  fi
}

doctor_check_configuration() {
  local fix="$1"
  _doc_section "Configuration"

  local main="${BGB_CONFIG_FILE:-${BGB_CONFDIR}/bg-backup.conf}"
  if [ -f "${main}" ]; then
    if (config_require_perms "${main}" 0640) >/dev/null 2>&1; then
      _doc_ok "main configuration permissions"
    else
      if [ "${fix}" = "1" ]; then
        chown root:root "${main}" && chmod 0640 "${main}" && _doc_ok "fixed permissions on ${main}"
      else
        _doc_fail "${main} is world/group readable or not owned by root" "chmod 0640 ${main}"
      fi
    fi
    if (config_lint "${main}") >/dev/null 2>&1; then
      _doc_ok "main configuration syntax"
    else
      _doc_fail "main configuration does not validate" "run: bg-backup config validate"
    fi
  else
    _doc_warn "no main configuration at ${main} (built-in defaults are in use)"
  fi

  local cred f
  for cred in repo.env repo.key notify.env; do
    f="${BGB_CONFDIR}/credentials/${cred}"
    [ -e "${f}" ] || continue
    local mode
    mode="$(stat -c '%a' "${f}" 2>/dev/null)"
    case "${cred}" in
      repo.key) [ "${mode}" = "400" ] && _doc_ok "${cred} mode ${mode}" || {
        [ "${fix}" = "1" ] && chmod 0400 "${f}" && _doc_ok "fixed ${cred} to 0400" \
          || _doc_fail "${cred} has mode ${mode}, expected 400" "chmod 0400 ${f}"
      } ;;
      *) case "${mode}" in
        400 | 600) _doc_ok "${cred} mode ${mode}" ;;
        *) [ "${fix}" = "1" ] && chmod 0400 "${f}" && _doc_ok "fixed ${cred} to 0400" \
          || _doc_fail "${cred} has mode ${mode}, expected 400 or 600" "chmod 0400 ${f}" ;;
      esac ;;
    esac
  done

  local d="${BGB_CONFDIR}/credentials"
  if [ -d "${d}" ]; then
    local dmode
    dmode="$(stat -c '%a' "${d}" 2>/dev/null)"
    [ "${dmode}" = "700" ] && _doc_ok "credentials directory mode 700" \
      || { [ "${fix}" = "1" ] && chmod 0700 "${d}" && _doc_ok "fixed credentials directory to 0700" \
        || _doc_warn "credentials directory has mode ${dmode}, expected 700"; }
  fi

  local n
  n="$(config_list_jobs | grep -c '^' || true)"
  if [ "${n:-0}" -gt 0 ]; then
    _doc_ok "${n} job(s) defined"
  else
    _doc_warn "no jobs defined in ${BGB_CONFDIR}/conf.d"
  fi
}

doctor_check_repository() {
  _doc_section "Repository"

  if [ ! -f "${BGB_REPO_ENV}" ]; then
    _doc_fail "no repository configured" "run: bg-backup init"
    return 0
  fi

  if ! (repo_env_load) >/dev/null 2>&1; then
    _doc_fail "the repository environment does not load" "run: bg-backup config validate"
    return 0
  fi
  repo_env_load >/dev/null 2>&1 || true

  # THE shared-bucket check. Getting the prefix wrong is how one host's
  # retention silently deletes another host's snapshots.
  local prefix
  prefix="$(repo_prefix)"
  local host
  host="$(fqdn)"
  if [ "${prefix}" = "${host}" ]; then
    _doc_ok "repository prefix matches this host (${prefix})"
  else
    _doc_fail "repository prefix is '${prefix}' but this host is '${host}'" \
      "In a shared bucket this is how one host's forget deletes another host's snapshots."
  fi

  if restic_repo_reachable; then
    _doc_ok "repository reachable and the key works"
  else
    _doc_fail "repository is NOT reachable, or the key is wrong"
    return 0
  fi

  if restic_is_locked; then
    _doc_warn "the repository currently holds a lock (a run in progress, or a stale lock)" \
      "check with: bg-backup unlock"
  else
    _doc_ok "no repository lock held"
  fi

  local n
  n="$(restic_capture snapshots --json --host "${BGB_HOSTNAME}" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    _doc_ok "${n} snapshot(s) for this host"
  else
    _doc_warn "no snapshots yet for this host"
  fi

  if [ "${BGB_REPO_ROLE}" = "primary" ]; then
    _doc_ok "repository role: primary (this host may prune)"
  else
    _doc_ok "repository role: ${BGB_REPO_ROLE} (prune is disabled here, by design)"
  fi

  local last_check
  last_check="$(state_get_repo check_at)"
  if [ -n "${last_check}" ]; then
    _doc_ok "last integrity check: ${last_check}"
  else
    _doc_warn "no 'restic check' has been recorded yet"
  fi

  local last_verify
  last_verify="$(state_get_repo verify_at)"
  if [ -n "${last_verify}" ]; then
    _doc_ok "last proven restore: ${last_verify}"
  else
    _doc_warn "no restore has ever been verified" \
      "A backup that has never been restored is a hypothesis. Run: bg-backup verify"
  fi
}

doctor_check_jobs() {
  _doc_section "Jobs"
  local job age sla status

  while IFS= read -r job; do
    [ -n "${job}" ] || continue
    if ! (config_load_job "${job}") >/dev/null 2>&1; then
      _doc_fail "job '${job}' does not validate" "run: bg-backup config validate"
      continue
    fi
    config_load_job "${job}" >/dev/null 2>&1 || true

    if [ "${JOB_ENABLED}" != "1" ]; then
      _doc_ok "job '${job}' is disabled"
      continue
    fi

    status="$(state_field "${job}" status)"
    age="$(state_age_hours "${job}")"
    sla="${JOB_ALERT_MAX_AGE_HOURS}"

    if [ -z "${status}" ]; then
      _doc_warn "job '${job}' has never run"
    elif [ -z "${age}" ]; then
      _doc_warn "job '${job}': last status ${status}, age unknown"
    elif awk -v a="${age}" -v m="${sla}" 'BEGIN{exit !(a <= m)}'; then
      _doc_ok "job '${job}': ${status}, ${age}h old (SLA ${sla}h)"
    else
      _doc_fail "job '${job}' is ${age}h old, past its ${sla}h SLA (last status: ${status})"
    fi
  done < <(config_list_jobs)
}

doctor_check_schedules() {
  have systemctl || return 0
  _doc_section "Schedules"

  local job unit n=0
  while IFS= read -r job; do
    [ -n "${job}" ] || continue
    unit="bg-backup@${job}.timer"
    if systemctl list-unit-files "${unit}" >/dev/null 2>&1 \
      && systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
      _doc_ok "timer ${unit}: $(systemctl show -p NextElapseUSecRealtime --value "${unit}" 2>/dev/null || echo enabled)"
      n=$((n + 1))
    else
      _doc_warn "timer ${unit} is not enabled"
    fi
  done < <(config_list_jobs)

  [ "${n}" -eq 0 ] && _doc_warn "no backup timer is enabled - nothing runs automatically"

  # Two jobs quiescing Docker at the same time is the exact trap the resticprofile
  # runbook warns about, and it is invisible until the night it happens.
  doctor_check_schedule_collisions
}

doctor_check_schedule_collisions() {
  local -a quiescing=()
  local job
  while IFS= read -r job; do
    [ -n "${job}" ] || continue
    (config_load_job "${job}") >/dev/null 2>&1 || continue
    config_load_job "${job}" >/dev/null 2>&1 || true
    case "${JOB_QUIESCE}" in
      docker-stop | docker-pause | service-stop)
        [ -n "${JOB_SCHEDULE}" ] && quiescing+=("${job}|${JOB_SCHEDULE}")
        ;;
    esac
  done < <(config_list_jobs)

  [ "${#quiescing[@]}" -lt 2 ] && return 0

  local i j a b an bn as bs
  for ((i = 0; i < ${#quiescing[@]}; i++)); do
    for ((j = i + 1; j < ${#quiescing[@]}; j++)); do
      a="${quiescing[i]}"
      b="${quiescing[j]}"
      an="${a%%|*}"
      as="${a#*|}"
      bn="${b%%|*}"
      bs="${b#*|}"
      if [ "${as}" = "${bs}" ]; then
        _doc_fail "jobs '${an}' and '${bn}' both quiesce services at the same time (${as})" \
          "They will fight over the same containers. Move them apart."
      fi
    done
  done
}

doctor_check_docker() {
  have docker || return 0
  _doc_section "Docker"

  if ! docker info >/dev/null 2>&1; then
    _doc_warn "cannot talk to the Docker daemon"
    return 0
  fi
  _doc_ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"

  # THE --one-file-system trap, straight out of the full-server runbook.
  local root_dev docker_dev
  root_dev="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
  docker_dev="$(df -P /var/lib/docker 2>/dev/null | awk 'NR==2{print $1}')"
  if [ -n "${docker_dev}" ] && [ "${docker_dev}" != "${root_dev}" ]; then
    local covered=0 job p
    while IFS= read -r job; do
      [ -n "${job}" ] || continue
      (config_load_job "${job}") >/dev/null 2>&1 || continue
      config_load_job "${job}" >/dev/null 2>&1 || true
      [ "${JOB_ONE_FILE_SYSTEM}" = "1" ] || {
        covered=1
        break
      }
      for p in "${JOB_PATHS[@]:-}" "${JOB_EXTRA_PATHS[@]:-}"; do
        case "${p}" in /var/lib/docker*) covered=1 ;; esac
      done
      [ "${JOB_MODE}" = "docker" ] && covered=1
    done < <(config_list_jobs)

    if [ "${covered}" -eq 1 ]; then
      _doc_ok "/var/lib/docker is a separate mount and is covered"
    else
      _doc_fail "/var/lib/docker is on its own filesystem (${docker_dev}) and --one-file-system will SKIP it" \
        "Add /var/lib/docker to JOB_EXTRA_PATHS, or use a docker-mode job."
    fi
  else
    _doc_ok "/var/lib/docker is on the root filesystem"
  fi

  if have jq; then
    local nproj
    nproj="$(docker compose ls --all --format json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
    _doc_ok "${nproj} compose project(s) discovered"

    # An image with no registry digest cannot be pulled during a restore.
    local c tag missing=0
    while IFS= read -r c; do
      [ -n "${c}" ] || continue
      tag="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Config.Image // empty')"
      [ -n "${tag}" ] || continue
      docker image inspect "${tag}" 2>/dev/null | jq -e '.[0].RepoDigests[0]' >/dev/null 2>&1 \
        || missing=$((missing + 1))
    done < <(docker ps -q 2>/dev/null || true)

    if [ "${missing}" -eq 0 ]; then
      _doc_ok "every running image has a registry digest"
    else
      _doc_warn "${missing} running container(s) use a locally built image with no registry digest" \
        "Set JOB_DOCKER_EXPORT_IMAGES=missing, or they are not restorable."
    fi
  fi
}

doctor_check_recovery() {
  _doc_section "Recovery readiness"

  if [ -f "${BGB_STATE_DIR}/card-ack" ]; then
    _doc_ok "recovery card acknowledged ($(awk -F= '/acknowledged/{print $2}' "${BGB_STATE_DIR}/card-ack" 2>/dev/null))"
  else
    _doc_warn "the recovery card has not been acknowledged" \
      "If the passphrase exists only on this host, a total loss is unrecoverable."
  fi

  local bundle="${BGB_ESCROW_LOCAL}"
  if [ -f "${bundle}" ]; then
    local age_days
    age_days=$((($(now_epoch) - $(stat -c %Y "${bundle}")) / 86400))
    if [ "${age_days}" -le "${BGB_ESCROW_MAX_AGE_DAYS}" ]; then
      _doc_ok "recovery bundle is ${age_days} day(s) old"
    else
      _doc_warn "recovery bundle is ${age_days} days old (limit ${BGB_ESCROW_MAX_AGE_DAYS})" \
        "run: bg-backup config export"
    fi
  else
    _doc_warn "no local recovery bundle" "run: bg-backup config export --out ${bundle}"
  fi

  # The most common way the bootstrap story rots: someone adds a credential and
  # never re-exports, so the bundle restores a configuration that no longer works.
  local recorded current
  recorded="$(state_get_repo config_hash)"
  if [ -n "${recorded}" ] && declare -F backup_config_hash >/dev/null 2>&1; then
    current="$(backup_config_hash)"
    if [ "${recorded}" = "${current}" ]; then
      _doc_ok "the recovery bundle matches the deployed configuration"
    else
      _doc_warn "the configuration has changed since the last export" \
        "run: bg-backup config export"
    fi
  fi

  local rkeys
  rkeys="$(restic_capture key list --json 2>/dev/null | jq -r '[.[]? | select(.username=="recovery")] | length' 2>/dev/null || echo 0)"
  if [ "${rkeys:-0}" -gt 0 ]; then
    _doc_ok "an independent recovery key exists"
  else
    _doc_warn "no independent recovery key" \
      "Without one, a host compromise means rebuilding the repository rather than removing a key."
  fi
}

doctor_check_monitoring() {
  _doc_section "Monitoring"

  local any=0 n
  for n in ${BGB_NOTIFIERS}; do
    case "${n}" in
      uptime-kuma) [ -n "${BGB_MONITOR_KUMA_PUSH_URL}" ] && {
        _doc_ok "uptime-kuma configured"
        any=1
      } \
        || _doc_warn "uptime-kuma listed but BGB_MONITOR_KUMA_PUSH_URL is empty" ;;
      email) [ -n "${BGB_MONITOR_MAIL_TO}" ] && {
        _doc_ok "email to ${BGB_MONITOR_MAIL_TO}"
        any=1
      } \
        || _doc_warn "email listed but BGB_MONITOR_MAIL_TO is empty" ;;
      teams) [ -n "${BGB_MONITOR_TEAMS_WEBHOOK_URL}" ] && {
        _doc_ok "Teams webhook configured"
        any=1
      } \
        || _doc_warn "teams listed but no webhook URL" ;;
      prometheus) [ -n "${BGB_METRICS_TEXTFILE}" ] && {
        if [ -d "$(dirname "${BGB_METRICS_TEXTFILE}")" ]; then
          _doc_ok "prometheus textfile: ${BGB_METRICS_TEXTFILE}"
          any=1
        else
          _doc_warn "textfile collector directory does not exist: $(dirname "${BGB_METRICS_TEXTFILE}")"
        fi
      } || _doc_warn "prometheus listed but BGB_METRICS_TEXTFILE is empty" ;;
    esac
  done

  [ "${any}" -eq 0 ] && _doc_fail "no working notification channel is configured" \
    "A backup nobody hears about failing is a backup that fails silently for months."

  if have mail || have sendmail || have msmtp; then
    _doc_ok "a local mail transport is available"
  else
    [ -n "${BGB_MONITOR_MAIL_TO}" ] && _doc_fail "email is configured but no MTA is installed"
  fi

  # Redaction is a security control; if it is broken, everything downstream leaks.
  if redact_selftest 2>/dev/null; then
    _doc_ok "redaction self-test passed"
  else
    _doc_fail "REDACTION SELF-TEST FAILED - do not paste logs or notifications anywhere"
  fi
}

doctor_summary() {
  if [ "${BGB_JSON}" = "1" ]; then
    local body first=1 c
    body='"checks":['
    for c in "${_DOC_JSON[@]:-}"; do
      [ -n "${c}" ] || continue
      [ "${first}" -eq 0 ] && body+=","
      body+="${c}"
      first=0
    done
    body+="],"
    body+="$(json_kvraw pass "${_DOC_PASS}"),"
    body+="$(json_kvraw warn "${_DOC_WARN}"),"
    body+="$(json_kvraw fail "${_DOC_FAIL}")"
    local verdict="ok"
    [ "${_DOC_WARN}" -gt 0 ] && verdict="warn"
    [ "${_DOC_FAIL}" -gt 0 ] && verdict="fail"
    json_envelope "${verdict}" "${body}"
  fi

  printf '\n%s%d passed, %d warning(s), %d failure(s)%s\n\n' \
    "${C_BOLD}" "${_DOC_PASS}" "${_DOC_WARN}" "${_DOC_FAIL}" "${C_RESET}" >&2

  [ "${_DOC_FAIL}" -gt 0 ] && return "${EX_PRECOND}"
  return 0
}
