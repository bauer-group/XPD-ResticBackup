#!/usr/bin/env bash
# =============================================================================
# bg-backup - dr: disaster recovery onto a freshly installed host
# =============================================================================
# Four verbs, deliberately separated so nothing destructive happens by accident:
#
#   bootstrap   recover credentials, then /etc/bg-backup from the config snapshot
#   plan        READ-ONLY. What would be installed, restored and reconciled.
#   run         execute one phase at a time, confirming each
#   verify      post-recovery health check
#
# `plan` writes nothing at all. That matters: the first thing an operator does
# in a recovery is find out what they are dealing with, and that step must be
# safe to run on a machine whose state they do not yet understand.
#
# The hard part of DR is not copying files back. It is reconciling a backup of
# host A with the reality of host B: different disk UUIDs, different NIC names,
# different UIDs, a newer OS with different package defaults. Everything below
# is organised around that.
# =============================================================================

[ -n "${_BGB_DR_SOURCED:-}" ] && return 0
_BGB_DR_SOURCED=1

: "${BGB_FACTS_DIR:=/var/lib/bg-backup/facts}"

cmd_dr() {
  local sub="${1:-}"; shift || true
  case "${sub}" in
    bootstrap)  dr_bootstrap "$@" ;;
    plan)       dr_plan "$@" ;;
    run)        dr_run "$@" ;;
    verify)     dr_verify "$@" ;;
    bare-metal) dr_bare_metal "$@" ;;
    ''|--help|-h) usage_dr ;;
    *) err "Unknown subcommand: dr ${sub}"; usage_dr; exit "${EX_USAGE}" ;;
  esac
}

# =============================================================================
# bootstrap
# =============================================================================
dr_bootstrap() {
  local bundle="" bundle_url="" repo="" password_file="" snapshot=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle)        bundle="$2"; shift 2 ;;
      --bundle-url)    bundle_url="$2"; shift 2 ;;
      --repo)          repo="$2"; shift 2 ;;
      --password-file) password_file="$2"; shift 2 ;;
      --snapshot)      snapshot="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  require_root

  printf '\n%sbg-backup disaster recovery - bootstrap%s\n\n' "${C_BOLD}" "${C_RESET}" >&2

  # --- Path A: a recovery bundle -------------------------------------------
  if [ -n "${bundle_url}" ] && [ -z "${bundle}" ]; then
    bundle="$(tmp_root)/bundle.download"
    log "Fetching the bundle from ${bundle_url}"
    case "${bundle_url}" in
      s3://*)  have aws && aws s3 cp "${bundle_url}" "${bundle}" >/dev/null \
                 || die "${EX_PRECOND}" "Could not fetch the bundle (aws cli required)" ;;
      http*)   curl -fsSL -o "${bundle}" "${bundle_url}" \
                 || die "${EX_PRECOND}" "Could not fetch the bundle" ;;
      *)       die "${EX_USAGE}" "Unsupported bundle URL: ${bundle_url}" ;;
    esac
    # Preserve the suffix so config import can pick the right decryptor.
    case "${bundle_url}" in
      *.age) mv "${bundle}" "${bundle}.age"; bundle="${bundle}.age" ;;
      *.gpg) mv "${bundle}" "${bundle}.gpg"; bundle="${bundle}.gpg" ;;
      *.enc) mv "${bundle}" "${bundle}.enc"; bundle="${bundle}.enc" ;;
    esac
  fi

  if [ -n "${bundle}" ]; then
    config_load
    lib_source secrets.sh
    secrets_cmd_import --in "${bundle}" --force
    log "Configuration recovered from the bundle"
    dr_plan
    return 0
  fi

  # --- Path B: credentials from the recovery sheet --------------------------
  # This is the path that matters: an operator with a printed page and nothing
  # else must be able to get from here to a restore.
  config_load
  install -d -m 0750 "${BGB_CONFDIR}"
  install -d -m 0700 "${BGB_CONFDIR}/credentials"

  if [ -z "${repo}" ]; then
    [ -t 0 ] || die "${EX_USAGE}" "Non-interactive bootstrap needs --bundle or --repo"
    printf 'Repository URL (section 1 of the recovery sheet): ' >&2
    read -r repo
  fi
  [ -n "${repo}" ] || die "${EX_USAGE}" "No repository URL"

  local passphrase=""
  if [ -n "${password_file}" ]; then
    passphrase="$(cat "${password_file}")"
  elif [ -t 0 ]; then
    printf 'Repository passphrase: ' >&2
    stty -echo 2>/dev/null || true; read -r passphrase; stty echo 2>/dev/null || true; printf '\n' >&2
  fi
  [ -n "${passphrase}" ] || die "${EX_USAGE}" "No repository passphrase"
  redact_register "${passphrase}"

  local s3key="" s3secret="" s3region="us-east-1"
  case "${repo}" in
    s3:*)
      if [ -t 0 ]; then
        printf 'S3 access key id: ' >&2; read -r s3key
        printf 'S3 secret access key: ' >&2
        stty -echo 2>/dev/null || true; read -r s3secret; stty echo 2>/dev/null || true; printf '\n' >&2
        printf 'S3 region [us-east-1]: ' >&2; read -r s3region
        [ -z "${s3region}" ] && s3region="us-east-1"
      fi ;;
  esac

  local keyfile="${BGB_CONFDIR}/credentials/repo.key"
  printf '%s' "${passphrase}" >"${keyfile}"
  chmod 0400 "${keyfile}"

  lib_source init.sh
  init_write_env "${BGB_CONFDIR}/credentials/repo.env" "${repo}" "${keyfile}" "${s3key}" "${s3secret}" "${s3region}"

  repo_env_load
  restic_require

  log "Testing the repository"
  restic_repo_reachable || die "${EX_REPO}" "The repository is not reachable with these credentials"
  log "Repository OK"

  # --- Recover the configuration from the config snapshot -------------------
  log "Looking for the configuration snapshot (tag bg-backup-config)"
  require_jq
  local snap
  if [ -n "${snapshot}" ]; then
    snap="${snapshot}"
  else
    snap="$(restic_capture snapshots --tag bg-backup-config --json 2>/dev/null \
            | jq -r 'sort_by(.time) | last | .short_id // empty')"
  fi

  if [ -z "${snap}" ]; then
    warn "No configuration snapshot found."
    warn "You have repository access, but the job definitions must be recreated by hand."
    log "Snapshots that do exist:"
    cmd_snapshots || true
    return 0
  fi

  log "Restoring /etc/bg-backup from snapshot ${snap}"
  local staging; staging="$(tmp_root)/cfg"
  install -d -m 0700 "${staging}"
  restic_exec restore "${snap}" --target "${staging}" --include "${BGB_CONFDIR}" \
    || die "${EX_REPO}" "Could not restore the configuration"

  if [ -d "${staging}${BGB_CONFDIR}" ]; then
    # Do not clobber the credentials we were just handed: they are what got us
    # here, and the snapshot's copy may predate a rotation.
    local f
    for f in "${staging}${BGB_CONFDIR}"/*; do
      [ -e "${f}" ] || continue
      case "$(basename "${f}")" in
        credentials) continue ;;
      esac
      cp -a "${f}" "${BGB_CONFDIR}/"
    done
    if [ -d "${staging}${BGB_CONFDIR}/credentials" ]; then
      for f in "${staging}${BGB_CONFDIR}/credentials"/*; do
        [ -e "${f}" ] || continue
        case "$(basename "${f}")" in
          repo.env|repo.key) continue ;;
          *) cp -a "${f}" "${BGB_CONFDIR}/credentials/" ;;
        esac
      done
    fi
    chmod 0700 "${BGB_CONFDIR}/credentials"
    chmod 0400 "${BGB_CONFDIR}"/credentials/* 2>/dev/null || true
    log "Configuration recovered"
  fi

  if [ -d "${staging}/var/lib/bg-backup/facts" ]; then
    install -d -m 0700 /var/lib/bg-backup
    cp -a "${staging}/var/lib/bg-backup/facts" /var/lib/bg-backup/
    log "System facts recovered"
  fi

  log "Bootstrap complete."
  printf '\nNext:  bg-backup dr plan\n\n' >&2
}

# =============================================================================
# plan  (READ-ONLY)
# =============================================================================
dr_plan() {
  local run="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  config_load

  if [ -n "${out}" ]; then
    dr_plan_render "${run}" >"${out}"
    log "Plan written to ${out}"
    return 0
  fi
  dr_plan_render "${run}" >&2
}

dr_plan_render() {
  local run="$1"
  local f="${BGB_FACTS_DIR}/host.env"

  printf '\n%s================ DISASTER RECOVERY PLAN ================%s\n' "${C_BOLD}" "${C_RESET}"
  printf '\nNothing below has been executed. This is a report.\n'

  if [ ! -r "${f}" ]; then
    printf '\n  %sNo system facts available.%s\n' "${C_YELLOW}" "${C_RESET}"
    printf '  Run "bg-backup dr bootstrap" first, or restore the facts directory.\n'
    printf '  Without them only file restore is possible - no package, network or\n'
    printf '  account reconciliation.\n\n'
    return 0
  fi

  # --- Source vs target ------------------------------------------------------
  local s_host s_os s_ver s_arch s_kernel s_virt s_fw
  # shellcheck disable=SC1090
  . "${f}"
  s_host="${hostname:-?}"; s_os="${os_id:-?}"; s_ver="${os_version:-?}"
  s_arch="${arch:-?}"; s_kernel="${kernel:-?}"; s_virt="${virt:-?}"; s_fw="${firmware:-?}"

  local t_os t_ver t_arch
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  t_os="${ID:-?}"; t_ver="${VERSION_ID:-?}"; t_arch="$(uname -m)"

  printf '\n%s1. SOURCE vs TARGET%s\n\n' "${C_BOLD}" "${C_RESET}"
  printf '  %-14s %-24s %s\n' "" "BACKED UP" "THIS HOST"
  printf '  %-14s %-24s %s\n' "hostname" "${s_host}" "$(fqdn)"
  printf '  %-14s %-24s %s\n' "os"       "${s_os} ${s_ver}" "${t_os} ${t_ver}"
  printf '  %-14s %-24s %s\n' "arch"     "${s_arch}" "${t_arch}"
  printf '  %-14s %-24s %s\n' "kernel"   "${s_kernel}" "$(uname -r)"
  printf '  %-14s %-24s %s\n' "virt"     "${s_virt}" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf '  %-14s %-24s %s\n' "firmware" "${s_fw}" "$([ -d /sys/firmware/efi ] && echo uefi || echo bios)"

  local blocked=0
  if [ "${s_os}" != "${t_os}" ]; then
    printf '\n  %sREFUSE%s different distribution (%s -> %s)\n' "${C_RED}" "${C_RESET}" "${s_os}" "${t_os}"
    blocked=1
  elif [ "${s_ver}" != "${t_ver}" ]; then
    if dr_version_lt "${t_ver}" "${s_ver}"; then
      printf '\n  %sREFUSE%s the target OS is OLDER than the source (%s -> %s)\n' "${C_RED}" "${C_RESET}" "${s_ver}" "${t_ver}"
      printf '         Database dumps are forward-compatible only. A PostgreSQL 16\n'
      printf '         dump does not load into PostgreSQL 15.\n'
      blocked=1
    else
      printf '\n  %sWARN%s   OS upgrade %s -> %s. Package names drift, third-party\n' "${C_YELLOW}" "${C_RESET}" "${s_ver}" "${t_ver}"
      printf '         repositories may have no build, and engine majors differ.\n'
      printf '         Requires --allow-os-upgrade.\n'
    fi
  fi
  if [ "${s_arch}" != "${t_arch}" ]; then
    printf '\n  %sREFUSE%s architecture change (%s -> %s): /usr/local binaries and\n' "${C_RED}" "${C_RESET}" "${s_arch}" "${t_arch}"
    printf '         pinned image digests are for the wrong platform.\n'
    blocked=1
  fi

  # --- Packages --------------------------------------------------------------
  printf '\n%s2. PACKAGES%s\n\n' "${C_BOLD}" "${C_RESET}"
  local nman nhold
  nman="$(grep -c '^' "${BGB_FACTS_DIR}/packages-manual.txt" 2>/dev/null || echo 0)"
  nhold="$(grep -c '^' "${BGB_FACTS_DIR}/packages-hold.txt" 2>/dev/null || echo 0)"
  printf '  %s package(s) to install, %s held\n' "${nman}" "${nhold}"
  printf '  Method: apt-mark hold, then one apt-get install transaction.\n'
  printf '  NOT dpkg --set-selections + dselect-upgrade: that removes packages the\n'
  printf '  freshly installed system needs.\n'
  if [ -r "${BGB_FACTS_DIR}/apt-config.tar" ]; then
    printf '  APT sources and keyrings will be restored first, and apt-get update\n'
    printf '  must succeed before any install - a silently unreachable third-party\n'
    printf '  repository is how a rebuild quietly loses the interesting packages.\n'
  fi

  # --- Storage ---------------------------------------------------------------
  printf '\n%s3. STORAGE RECONCILIATION%s\n\n' "${C_BOLD}" "${C_RESET}"
  if [ -r "${BGB_FACTS_DIR}/disk-blkid.txt" ]; then
    local changed=0 uuid dev
    while IFS= read -r line; do
      dev="${line%%:*}"
      uuid="$(printf '%s' "${line}" | grep -o 'UUID="[^"]*"' | head -n1 | cut -d'"' -f2)"
      [ -n "${uuid}" ] || continue
      if ! blkid 2>/dev/null | grep -q "\"${uuid}\""; then
        printf '  %sCHANGED%s %s had UUID %s - not present on this host\n' "${C_YELLOW}" "${C_RESET}" "${dev}" "${uuid}"
        changed=$(( changed + 1 ))
      fi
    done <"${BGB_FACTS_DIR}/disk-blkid.txt"
    if [ "${changed}" -eq 0 ]; then
      printf '  All backed-up filesystem UUIDs are present here.\n'
    else
      printf '\n  %s/etc/fstab will be STAGED, not applied.%s A wrong fstab drops the\n' "${C_BOLD}" "${C_RESET}"
      printf '  host into an emergency shell at boot, which needs console access.\n'
    fi
  fi

  # --- Network ---------------------------------------------------------------
  printf '\n%s4. NETWORK RECONCILIATION%s\n\n' "${C_BOLD}" "${C_RESET}"
  if [ -r "${BGB_FACTS_DIR}/net-links.json" ] && have jq; then
    local iface mac
    while IFS=$'\t' read -r iface mac; do
      [ -n "${iface}" ] || continue
      [ "${iface}" = "lo" ] && continue
      local now
      now="$(ip -j link show 2>/dev/null | jq -r --arg m "${mac}" '.[] | select(.address==$m) | .ifname' | head -n1)"
      if [ -n "${now}" ] && [ "${now}" = "${iface}" ]; then
        printf '  %-14s %s  unchanged\n' "${iface}" "${mac}"
      elif [ -n "${now}" ]; then
        printf '  %s%-14s%s %s  is now %s\n' "${C_YELLOW}" "${iface}" "${C_RESET}" "${mac}" "${now}"
      else
        printf '  %s%-14s%s %s  NOT PRESENT on this host\n' "${C_RED}" "${iface}" "${C_RESET}" "${mac}"
      fi
    done < <(jq -r '.[] | [.ifname, .address] | @tsv' "${BGB_FACTS_DIR}/net-links.json" 2>/dev/null)
    printf '\n  Netplan will be STAGED and applied only with "netplan try --timeout 120",\n'
    printf '  which reverts itself if not confirmed. Never "netplan apply" over SSH.\n'
  fi

  # --- Docker ----------------------------------------------------------------
  printf '\n%s5. DOCKER%s\n\n' "${C_BOLD}" "${C_RESET}"
  local mf="${BGB_FACTS_DIR}/docker-manifest.json"
  if [ -r "${mf}" ] && have jq; then
    printf '  %s compose project(s), %s volume(s), %s network(s)\n' \
      "$(jq '.projects | length' "${mf}" 2>/dev/null || echo '?')" \
      "$(jq '.volumes | length'  "${mf}" 2>/dev/null || echo '?')" \
      "$(jq '.networks | length' "${mf}" 2>/dev/null || echo '?')"
    jq -r '.projects[]? | "    - \(.name) (\(.containers | length) containers)"' "${mf}" 2>/dev/null
    printf '\n  Order: networks (with recorded subnets) -> volumes -> compose files\n'
    printf '  -> pull images BY DIGEST -> start databases and wait for health\n'
    printf '  -> load dumps -> start the rest.\n'
  else
    printf '  No docker manifest in the facts directory.\n'
  fi

  # --- Databases -------------------------------------------------------------
  printf '\n%s6. DATABASE DUMPS%s\n\n' "${C_BOLD}" "${C_RESET}"
  if ( repo_env_load ) >/dev/null 2>&1 && have jq; then
    repo_env_load >/dev/null 2>&1 || true
    local -a args=(snapshots --json --tag kind=dbdump)
    [ -n "${run}" ] && args+=(--tag "run=${run}")
    restic_capture "${args[@]}" 2>/dev/null \
      | jq -r 'sort_by(.time) | .[] | "    - \(.short_id)  \(.time[0:19])  \((.tags//[]) | map(select(startswith("container="))) | join(""))"' \
      2>/dev/null | tail -n 20
  else
    printf '  (repository not reachable - cannot list)\n'
  fi

  # --- Never / staged --------------------------------------------------------
  printf '\n%s7. NOT RESTORED AUTOMATICALLY%s\n\n' "${C_BOLD}" "${C_RESET}"
  printf '  NEVER   /boot, /lib/modules, /etc/machine-id, /var/lib/dpkg,\n'
  printf '          /var/lib/docker/overlay2, the account databases\n'
  printf '  STAGED  /etc/fstab, /etc/netplan, /etc/ssh/sshd_config, /etc/pam.d,\n'
  printf '          firewall rules, /etc/default/grub\n\n'
  printf '  The kernel and bootloader are reinstalled from packages, never copied.\n'
  printf '  Accounts are MERGED by UID/GID reconciliation, never overwritten.\n'
  printf '  See %s\n' "$(restore_unsafe_list 2>/dev/null || echo 'share/dr/unsafe-restore.list')"

  printf '\n%s8. NEXT%s\n\n' "${C_BOLD}" "${C_RESET}"
  if [ "${blocked}" -eq 1 ]; then
    printf '  %sBLOCKED.%s Resolve the REFUSE items above before running any phase.\n\n' "${C_RED}" "${C_RESET}"
  else
    printf '    bg-backup dr run --phase system     packages, config, accounts\n'
    printf '    bg-backup dr run --phase docker     projects, volumes, images\n'
    printf '    bg-backup dr run --phase databases  load the dumps\n'
    printf '    bg-backup dr verify                 prove it worked\n\n'
  fi
  printf '%s=======================================================%s\n\n' "${C_BOLD}" "${C_RESET}"
}

dr_version_lt() {
  # dr_version_lt A B -> true when A < B
  [ "$1" = "$2" ] && return 1
  local first
  first="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [ "${first}" = "$1" ]
}

# =============================================================================
# run
# =============================================================================
dr_run() {
  local phase="" dry=0 allow_os_upgrade=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) phase="$2"; shift 2 ;;
      --phase=*) phase="${1#*=}"; shift ;;
      --dry-run) dry=1; shift ;;
      --allow-os-upgrade) allow_os_upgrade=1; shift ;;
      *) shift ;;
    esac
  done
  [ -n "${phase}" ] || die "${EX_USAGE}" "dr run requires --phase system|docker|databases|all"

  require_root
  config_load
  repo_env_load
  restic_require

  [ "${dry}" = "1" ] && BGB_DRY_RUN=1

  case "${phase}" in
    system)    dr_phase_system "${allow_os_upgrade}" ;;
    docker)    dr_phase_docker ;;
    databases) dr_phase_databases ;;
    all)
      dr_phase_system "${allow_os_upgrade}" || return $?
      dr_phase_docker || return $?
      dr_phase_databases || return $?
      dr_verify ;;
    *) die "${EX_USAGE}" "Unknown phase: ${phase}" ;;
  esac
}

dr_phase_system() {
  local allow_os_upgrade="$1"
  printf '\n%s=== DR phase: system ===%s\n\n' "${C_BOLD}" "${C_RESET}" >&2
  confirm "Reconcile packages, configuration and accounts on this host?" || return "${EX_SAFETY}"

  dr_restore_apt_config
  dr_install_packages
  dr_reconcile_accounts
  dr_restore_payload_dirs
  dr_stage_dangerous
  dr_enable_units
  log "System phase complete. Review the staged files before rebooting."
}

dr_restore_apt_config() {
  local t="${BGB_FACTS_DIR}/apt-config.tar"
  [ -r "${t}" ] || { warn "No APT configuration in the facts directory"; return 0; }
  log "Restoring APT sources and keyrings"
  [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] tar -C / -xf ${t}"; return 0; }
  tar -C / -xf "${t}"

  log "Refreshing package lists"
  # A gate, not a warning: a third-party repository that does not resolve means
  # the packages that made this host special will be missing, and the failure
  # would otherwise only surface as "some service is not installed".
  if ! apt-get update 2>&1 | tee /tmp/bgb-apt-update.log | grep -qv '^$'; then
    :
  fi
  if grep -qiE '^(E|Err):' /tmp/bgb-apt-update.log; then
    err "apt-get update reported errors:"
    grep -iE '^(E|Err):' /tmp/bgb-apt-update.log | sed 's/^/    /' >&2
    err "Fix the repository configuration before installing packages."
    return "${EX_PRECOND}"
  fi
}

dr_install_packages() {
  local manual="${BGB_FACTS_DIR}/packages-manual.txt"
  local hold="${BGB_FACTS_DIR}/packages-hold.txt"
  [ -r "${manual}" ] || { warn "No package list in the facts directory"; return 0; }

  if [ -s "${hold}" ]; then
    log "Re-applying package holds before installing"
    [ "${BGB_DRY_RUN}" = "1" ] || xargs -r apt-mark hold <"${hold}" >/dev/null
  fi

  local n; n="$(grep -c '^' "${manual}")"
  log "Installing ${n} package(s)"
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] apt-get install --no-install-recommends \$(cat ${manual})"
    return 0
  fi

  local failed="${BGB_FACTS_DIR}/packages-failed.txt"
  : >"${failed}"
  if ! xargs -r -a "${manual}" apt-get install -y --no-install-recommends >/dev/null 2>&1; then
    warn "The single transaction failed - bisecting package by package"
    local p
    while IFS= read -r p; do
      [ -n "${p}" ] || continue
      apt-get install -y --no-install-recommends "${p}" >/dev/null 2>&1 \
        || { printf '%s\n' "${p}" >>"${failed}"; warn "could not install: ${p}"; }
    done <"${manual}"
    if [ -s "${failed}" ]; then
      warn "$(grep -c '^' "${failed}") package(s) could not be installed - see ${failed}"
    fi
  fi
}

dr_reconcile_accounts() {
  local pw="${BGB_FACTS_DIR}/users-passwd.txt"
  local gr="${BGB_FACTS_DIR}/users-group.txt"
  [ -r "${pw}" ] || { warn "No account facts"; return 0; }

  log "Reconciling users and groups"
  local -a remap=()
  local name pass uid gid gecos home shell

  while IFS=: read -r name pass gid _; do
    [ -n "${name}" ] || continue
    [ "${gid}" -lt 1000 ] 2>/dev/null && getent group "${name}" >/dev/null 2>&1 && continue
    local cur; cur="$(getent group "${name}" | cut -d: -f3)"
    if [ -z "${cur}" ]; then
      if ! getent group "${gid}" >/dev/null 2>&1; then
        [ "${BGB_DRY_RUN}" = "1" ] || groupadd --gid "${gid}" "${name}" 2>/dev/null || true
      else
        [ "${BGB_DRY_RUN}" = "1" ] || groupadd "${name}" 2>/dev/null || true
        remap+=("gid ${gid} -> $(getent group "${name}" | cut -d: -f3) (${name})")
      fi
    elif [ "${cur}" != "${gid}" ]; then
      remap+=("gid ${gid} -> ${cur} (${name})")
    fi
  done <"${gr}"

  while IFS=: read -r name pass uid gid gecos home shell; do
    [ -n "${name}" ] || continue
    [ "${uid}" -lt 1000 ] 2>/dev/null && getent passwd "${name}" >/dev/null 2>&1 && continue
    local cur; cur="$(getent passwd "${name}" | cut -d: -f3)"
    if [ -z "${cur}" ]; then
      if ! getent passwd "${uid}" >/dev/null 2>&1; then
        [ "${BGB_DRY_RUN}" = "1" ] || useradd --uid "${uid}" --gid "${gid}" -M \
          --home-dir "${home}" --shell "${shell}" --comment "${gecos}" "${name}" 2>/dev/null || true
      else
        [ "${BGB_DRY_RUN}" = "1" ] || useradd --gid "${gid}" -M --home-dir "${home}" \
          --shell "${shell}" --comment "${gecos}" "${name}" 2>/dev/null || true
        remap+=("uid ${uid} -> $(getent passwd "${name}" | cut -d: -f3) (${name})")
      fi
    elif [ "${cur}" != "${uid}" ]; then
      remap+=("uid ${uid} -> ${cur} (${name})")
    fi
  done <"${pw}"

  # /etc/subuid and /etc/subgid must be reproduced exactly. With userns-remap or
  # rootless Docker, every file inside a volume is owned at a fixed offset from
  # the base; a different base makes the whole volume unreadable to its own
  # container, and it looks like data corruption rather than a mapping problem.
  local s
  for s in subuid subgid; do
    if [ -r "${BGB_FACTS_DIR}/users-${s}.txt" ] && [ -s "${BGB_FACTS_DIR}/users-${s}.txt" ]; then
      if ! cmp -s "${BGB_FACTS_DIR}/users-${s}.txt" "/etc/${s}"; then
        warn "/etc/${s} differs from the backup - restoring it exactly"
        [ "${BGB_DRY_RUN}" = "1" ] || cp -f "${BGB_FACTS_DIR}/users-${s}.txt" "/etc/${s}"
      fi
    fi
  done

  if [ "${#remap[@]}" -gt 0 ]; then
    printf '\n%sUID/GID REMAPPING REQUIRED%s\n\n' "${C_YELLOW}" "${C_RESET}" >&2
    printf '  %s\n' "${remap[@]}" >&2
    cat >&2 <<'EOF'

  Restored files carry the OLD numeric owners. Applying the mapping is a
  recursive chown, and a wrong recursive chown is not recoverable, so it is
  never done automatically.

  Review the list, then:

      bg-backup dr fix-ownership --apply

EOF
    printf '%s\n' "${remap[@]}" >"${BGB_FACTS_DIR}/uid-remap.txt"
    return "${EX_SAFETY}"
  fi
  log "Accounts reconciled with no remapping needed"
}

dr_restore_payload_dirs() {
  local snap
  snap="$(restore_resolve_snapshot "" "" "" "" files)"
  [ -n "${snap}" ] || { warn "No file snapshot found"; return 0; }

  log "Restoring payload directories from ${snap}"
  local -a includes=(/etc /root /home /opt /srv /usr/local /var/www /data /var/docker)
  local -a args=(restore "${snap}" --target /)
  local p
  for p in "${includes[@]}"; do args+=(--include "${p}"); done

  # Excluding the dangerous paths at restore time is what makes "restore to /"
  # safe here; they are staged separately in dr_stage_dangerous.
  local class glob
  while read -r class glob; do
    case "${class}" in NEVER|STAGED) args+=(--exclude "${glob}") ;; esac
  done < <(grep -E '^(NEVER|STAGED)' "$(restore_unsafe_list)" 2>/dev/null || true)

  restic_exec_logged "${BGB_LOG_DIR}/dr-restore.log" "${args[@]}" \
    || warn "Some payload paths could not be restored"
}

dr_stage_dangerous() {
  local snap staging
  snap="$(restore_resolve_snapshot "" "" "" "" files)"
  [ -n "${snap}" ] || return 0
  staging="/var/lib/bg-backup/restore/staged"
  install -d -m 0700 "${staging}"

  log "Staging the paths that must be reviewed by a human"
  local -a args=(restore "${snap}" --target "${staging}")
  local class glob
  while read -r class glob; do
    [ "${class}" = "STAGED" ] && args+=(--include "${glob}")
  done < <(grep -E '^STAGED' "$(restore_unsafe_list)" 2>/dev/null || true)

  restic_exec restore "${args[@]:1}" >/dev/null 2>&1 || true

  cat >&2 <<EOF

Staged for review at ${staging}:

    diff -ru /etc/netplan ${staging}/etc/netplan
    diff -u  /etc/fstab   ${staging}/etc/fstab

  Apply netplan ONLY with:  netplan try --timeout 120
  (it reverts itself if you do not confirm - never "netplan apply" over SSH)

  Validate sshd BEFORE installing it:
    sshd -t -f ${staging}/etc/ssh/sshd_config

EOF
}

dr_enable_units() {
  local f="${BGB_FACTS_DIR}/units-enabled.txt"
  [ -r "${f}" ] || return 0
  log "Enabling units that were enabled on the source host"
  local unit missing=0
  while read -r unit _; do
    [ -n "${unit}" ] || continue
    case "${unit}" in *.service|*.timer|*.socket|*.target|*.path|*.mount) ;; *) continue ;; esac
    if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
      [ "${BGB_DRY_RUN}" = "1" ] || systemctl enable "${unit}" >/dev/null 2>&1 || true
    else
      warn "unit no longer exists: ${unit}"
      missing=$(( missing + 1 ))
    fi
  done <"${f}"
  # Units that vanished are the best early warning that a package install
  # silently failed - surfaced rather than swallowed.
  [ "${missing}" -gt 0 ] && warn "${missing} unit(s) from the backup do not exist here - check the package list"
  return 0
}

dr_phase_docker() {
  printf '\n%s=== DR phase: docker ===%s\n\n' "${C_BOLD}" "${C_RESET}" >&2
  require_cmd docker
  require_jq
  local mf="${BGB_FACTS_DIR}/docker-manifest.json"
  [ -r "${mf}" ] || die "${EX_PRECOND}" "No docker manifest at ${mf}"

  confirm "Recreate networks, volumes and compose projects on this host?" || return "${EX_SAFETY}"

  # 1. Networks with their recorded subnets, BEFORE any compose up.
  log "Recreating networks with their recorded subnets"
  local net subnet gateway driver
  while IFS=$'\t' read -r net driver subnet gateway; do
    [ -n "${net}" ] || continue
    docker network inspect "${net}" >/dev/null 2>&1 && { debug "network exists: ${net}"; continue; }
    local -a a=(network create --driver "${driver:-bridge}")
    [ -n "${subnet}" ] && [ "${subnet}" != "null" ] && a+=(--subnet "${subnet}")
    [ -n "${gateway}" ] && [ "${gateway}" != "null" ] && a+=(--gateway "${gateway}")
    a+=("${net}")
    [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] docker ${a[*]}"; continue; }
    docker "${a[@]}" >/dev/null && log "created network ${net} (${subnet:-auto})"
  done < <(jq -r '.networks[]? | [.name, .driver, (.ipam.Config[0].Subnet // ""), (.ipam.Config[0].Gateway // "")] | @tsv' "${mf}")

  # 2. Volumes.
  log "Recreating volumes"
  local vol vdriver
  while IFS=$'\t' read -r vol vdriver; do
    [ -n "${vol}" ] || continue
    docker volume inspect "${vol}" >/dev/null 2>&1 && continue
    [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] docker volume create ${vol}"; continue; }
    docker volume create --driver "${vdriver:-local}" "${vol}" >/dev/null && log "created volume ${vol}"
  done < <(jq -r '.volumes[]? | [.name, .driver] | @tsv' "${mf}")

  # 3. Volume contents, while nothing is running.
  log "Restoring volume contents"
  local snap; snap="$(restore_resolve_snapshot "" "" "" "" files)"
  if [ -n "${snap}" ]; then
    local mp
    while IFS= read -r mp; do
      [ -n "${mp}" ] || continue
      [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] restore ${mp}"; continue; }
      restic_exec restore "${snap}" --target / --include "${mp}" >/dev/null 2>&1 \
        || warn "could not restore ${mp}"
    done < <(jq -r '.volumes[]?.mountpoint // empty' "${mf}")
  fi

  # 4. Images by digest.
  dr_pull_images "${mf}"

  # 5. Bring projects up.
  local project wd
  while IFS=$'\t' read -r project wd; do
    [ -n "${project}" ] || continue
    [ -d "${wd}" ] || { warn "working directory missing for '${project}': ${wd}"; continue; }
    log "Starting compose project '${project}' in ${wd}"
    [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] docker compose -p ${project} up -d"; continue; }
    ( cd "${wd}" && docker compose up -d ) || warn "compose up failed for '${project}'"
  done < <(jq -r '.projects[]? | [.name, (.containers[0].working_dir // "")] | @tsv' "${mf}")
}

dr_pull_images() {
  local mf="$1" ref tag rc
  log "Pulling images by digest"
  while IFS=$'\t' read -r tag ref; do
    [ -n "${tag}" ] || continue
    if docker image inspect "${tag}" >/dev/null 2>&1; then continue; fi
    [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] docker pull ${ref:-${tag}}"; continue; }

    rc=0
    docker pull "${ref:-${tag}}" >/dev/null 2>&1 || rc=$?
    if [ "${rc}" -eq 0 ]; then
      # Tag the digest back to the name the compose file uses, so `compose up`
      # does not re-resolve :latest to something newer than the data expects.
      [ -n "${ref}" ] && [ "${ref}" != "${tag}" ] && docker tag "${ref}" "${tag}" 2>/dev/null || true
      log "pulled ${tag}"
      continue
    fi

    log "Registry pull failed for ${tag} - looking for an exported copy"
    local safe; safe="$(printf '%s' "${tag}" | tr -c 'A-Za-z0-9._-' '_')"
    local isnap
    isnap="$(restic_capture snapshots --json --tag kind=image --tag "image=${tag}" 2>/dev/null \
             | jq -r 'sort_by(.time) | last | .short_id // empty')"
    if [ -n "${isnap}" ]; then
      restic_exec dump "${isnap}" "/images/${safe}.tar" | docker load \
        && log "loaded ${tag} from the repository" \
        || err "could not load ${tag}"
    else
      err "IMAGE UNAVAILABLE: ${tag}"
      err "It is not in any registry and was never exported."
      err "The containers using it cannot be recreated."
    fi
  done < <(jq -r '.projects[]?.containers[]? | [.image, ""] | @tsv' "${mf}" | sort -u)
}

dr_phase_databases() {
  printf '\n%s=== DR phase: databases ===%s\n\n' "${C_BOLD}" "${C_RESET}" >&2
  require_cmd docker
  require_jq
  lib_source db.sh

  log "Waiting for database containers to become healthy"
  local c name waited
  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    name="$(db_container_name "${c}")"
    waited=0
    while [ "${waited}" -lt 300 ]; do
      local health
      health="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].State.Health.Status // "none"')"
      case "${health}" in
        healthy|none) break ;;
      esac
      sleep 5; waited=$(( waited + 5 ))
    done
    [ "${waited}" -ge 300 ] && warn "${name} did not become healthy within 300s"
  done < <(docker ps -q 2>/dev/null || true)

  # Order matters: globals and roles before data, or the restore creates objects
  # owned by roles that do not exist yet.
  local snap path engine container
  while IFS=$'\t' read -r snap path engine container; do
    [ -n "${snap}" ] || continue
    log "Restoring ${engine} dump into '${container}'"
    if ! docker inspect "${container}" >/dev/null 2>&1; then
      warn "container '${container}' does not exist here - skipping"
      continue
    fi
    db_load_engine "${engine}" || { warn "no engine module for ${engine}"; continue; }
    local fn="db_${engine}_restore"
    declare -F "${fn}" >/dev/null 2>&1 || { warn "engine ${engine} cannot restore"; continue; }
    [ "${BGB_DRY_RUN}" = "1" ] && { log "[dry-run] restore ${path} into ${container}"; continue; }
    restic_exec dump "${snap}" "/${path}" | "${fn}" "${container}" \
      && log "loaded ${path}" || err "FAILED to load ${path}"
  done < <(dr_list_dumps)
}

# dr_list_dumps - newest dump per target, ordered so that a restore replays
# cluster globals BEFORE any per-database dump. Loading a database first would
# GRANT to roles that do not exist yet, and PostgreSQL reports that as a pile of
# warnings rather than an error - so it looks like it worked.
dr_list_dumps() {
  require_jq
  restic_capture snapshots --json --tag kind=dbdump 2>/dev/null \
    | jq -r '
      map(select((.paths[0] // "") | startswith("/db/"))) |
      group_by(.paths[0]) |
      map(sort_by(.time) | last) |
      sort_by((.paths[0] | test("/globals\\.")) | not) | .[] |
      (.paths[0] | split("/")) as $p |
      [ .short_id,
        (.paths[0] | ltrimstr("/")),
        ($p[2] // ""),
        ($p[3] // "")
      ] | @tsv' 2>/dev/null
}

# =============================================================================
# verify
# =============================================================================
dr_verify() {
  printf '\n%s=== DR verification ===%s\n\n' "${C_BOLD}" "${C_RESET}" >&2
  local fail=0 warns=0

  local f="${BGB_FACTS_DIR}/units-enabled.txt"
  if [ -r "${f}" ]; then
    local unit missing=0
    while read -r unit _; do
      case "${unit}" in *.service|*.timer) ;; *) continue ;; esac
      systemctl list-unit-files "${unit}" >/dev/null 2>&1 || missing=$(( missing + 1 ))
    done <"${f}"
    [ "${missing}" -eq 0 ] && ok_mark "all backed-up units exist" \
      || { warn_mark "${missing} unit(s) from the backup are missing"; warns=$(( warns + 1 )); }
  fi

  local failed; failed="$(systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c '^' || echo 0)"
  [ "${failed}" -eq 0 ] && ok_mark "no failed units" \
    || { bad_mark "${failed} failed unit(s): systemctl --failed"; fail=$(( fail + 1 )); }

  if have docker && docker info >/dev/null 2>&1; then
    local running expected
    running="$(docker ps -q | grep -c '^' || echo 0)"
    expected="$(jq '[.projects[]?.containers[]?] | length' "${BGB_FACTS_DIR}/docker-manifest.json" 2>/dev/null || echo 0)"
    if [ "${running}" -ge "${expected}" ] && [ "${expected}" -gt 0 ]; then
      ok_mark "${running} container(s) running (expected ${expected})"
    elif [ "${expected}" -gt 0 ]; then
      bad_mark "${running} container(s) running, expected ${expected}"
      fail=$(( fail + 1 ))
    fi

    local v empty=0
    while IFS= read -r v; do
      [ -n "${v}" ] || continue
      local mp; mp="$(docker volume inspect "${v}" 2>/dev/null | jq -r '.[0].Mountpoint // ""')"
      [ -n "${mp}" ] && [ -d "${mp}" ] && [ -z "$(ls -A "${mp}" 2>/dev/null)" ] && {
        warn_mark "volume '${v}' is empty"; empty=$(( empty + 1 )); }
    done < <(jq -r '.volumes[]?.name // empty' "${BGB_FACTS_DIR}/docker-manifest.json" 2>/dev/null)
    [ "${empty}" -eq 0 ] && ok_mark "no restored volume is empty" || warns=$(( warns + empty ))
  fi

  # Listening ports against the ss capture: the cheapest proof that services are
  # not merely running but actually serving.
  if [ -r "${BGB_FACTS_DIR}/net-listening.txt" ]; then
    local want got missing_ports=0 port
    while IFS= read -r port; do
      [ -n "${port}" ] || continue
      ss -lntu 2>/dev/null | grep -q ":${port}\b" || { warn_mark "port ${port} is not listening"; missing_ports=$(( missing_ports + 1 )); }
    done < <(awk '{print $5}' "${BGB_FACTS_DIR}/net-listening.txt" 2>/dev/null \
             | grep -oE '[0-9]+$' | sort -un | head -n 30)
    [ "${missing_ports}" -eq 0 ] && ok_mark "all previously listening ports are open again" \
      || warns=$(( warns + missing_ports ))
  fi

  # The last and most important item: the new host must be protecting itself
  # before anyone goes home.
  if [ -f "${BGB_REPO_ENV}" ] && restic_repo_reachable; then
    ok_mark "the repository is reachable from this host"
    printf '\n  Run a backup now, before you consider this finished:\n' >&2
    printf '      bg-backup backup --all\n\n' >&2
  else
    bad_mark "this host cannot reach the backup repository"
    fail=$(( fail + 1 ))
  fi

  printf '\n  %s failure(s), %s warning(s)\n\n' "${fail}" "${warns}" >&2
  [ "${fail}" -gt 0 ] && return "${EX_VERIFY}"
  return 0
}

# =============================================================================
# bare-metal
# =============================================================================
dr_bare_metal() {
  local target="/mnt/target" in_rescue=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --i-am-in-rescue) in_rescue=1; shift ;;
      *) shift ;;
    esac
  done
  require_root

  # Refuse outside a rescue environment. Running this against a live root
  # filesystem would overwrite the system that is executing it.
  local rootfs; rootfs="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
  case "${rootfs}" in
    squashfs|overlay|tmpfs|rootfs) in_rescue=1 ;;
  esac
  if [ "${in_rescue}" -ne 1 ]; then
    err "This does not look like a rescue or live environment (root fs: ${rootfs})."
    err "Bare-metal recovery overwrites a root filesystem; doing that to the one"
    err "you are running from does not end well."
    err "Boot a rescue image, or pass --i-am-in-rescue if you are certain."
    return "${EX_SAFETY}"
  fi

  cat >&2 <<'EOF'

Bare-metal recovery is deliberately semi-automatic. These cases are REFUSED
outright, because getting them subtly wrong produces a host that boots into an
unrecoverable state:

  * LUKS-encrypted root       (keyfile / TPM enrolment cannot be reproduced)
  * ZFS or btrfs root with a different subvolume or dataset layout
  * software RAID not fully described by mdadm.conf
  * Secure Boot with custom MOK keys
  * a firmware mode change (BIOS <-> UEFI) versus the source
  * cloud VMs - reinstall and use "dr run" instead; it is faster and safer

EOF

  config_load
  repo_env_load
  restic_require

  # Generate the partitioning script; never execute it. One wrong device name
  # destroys the wrong disk, and that decision belongs to a human looking at
  # the actual machine.
  local script="${BGB_FACTS_DIR}/bare-metal-partition.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# GENERATED BY bg-backup - REVIEW EVERY LINE BEFORE RUNNING\n'
    printf '# This script is NOT executed automatically. It destroys data.\n'
    printf 'set -euo pipefail\n\n'
    local f
    for f in "${BGB_FACTS_DIR}"/disk-partitions-*.sfdisk; do
      [ -e "${f}" ] || continue
      local dev; dev="/dev/$(basename "${f}" .sfdisk | sed 's/^disk-partitions-//')"
      printf '# Original layout of %s:\n' "${dev}"
      sed 's/^/#   /' "${f}"
      printf '# sfdisk %s < %s\n\n' "${dev}" "${f}"
    done
  } >"${script}"
  chmod 0700 "${script}"

  log "Partition layout script generated (NOT executed): ${script}"
  cat >&2 <<EOF

Remaining steps, in order:

  1. Partition and format, using ${script} as the reference.
  2. mount your new root at ${target}
  3. bg-backup restore system --profile full --to ${target}
  4. for d in dev dev/pts proc sys run; do mount --rbind /\$d ${target}/\$d; done
     [ -d /sys/firmware/efi ] && mount --bind /sys/firmware/efi/efivars ${target}/sys/firmware/efi/efivars
  5. chroot ${target} apt-get install --reinstall -y linux-image-generic \\
       \$([ -d /sys/firmware/efi ] && echo 'grub-efi-amd64 shim-signed' || echo 'grub-pc')
     chroot ${target} grub-install <disk>
     chroot ${target} update-grub
     chroot ${target} update-initramfs -c -k all

     The kernel and bootloader are REINSTALLED, never restored. A copied /boot
     referencing modules that were not copied with it panics at boot.

  6. Rewrite ${target}/etc/fstab from the CURRENT blkid output, line by line.
  7. Pre-reboot gate - do not skip:
       findmnt --verify --fstab
       ls ${target}/boot/vmlinuz-* ${target}/boot/initrd.img-*
       chroot ${target} grub-probe /
       chroot ${target} sshd -t
       [ -d /sys/firmware/efi ] && efibootmgr

EOF
}

# =============================================================================
# helpers used by restore.sh
# =============================================================================
dr_restore_project() {
  local project="$1" run="$2" config_only="$3" recreate="$4"
  require_jq
  local mf="${BGB_FACTS_DIR}/docker-manifest.json"
  [ -r "${mf}" ] || die "${EX_PRECOND}" "No docker manifest - cannot restore a project"

  local wd
  wd="$(jq -r --arg p "${project}" '.projects[] | select(.name==$p) | .containers[0].working_dir // ""' "${mf}")"
  [ -n "${wd}" ] || die "${EX_PRECOND}" "Project '${project}' is not in the manifest"

  local snap; snap="$(restore_resolve_snapshot "${run}" "" "" "" files)"
  [ -n "${snap}" ] || die "${EX_PRECOND}" "No snapshot matches"

  log "Restoring compose files for '${project}' from ${snap}"
  restic_exec restore "${snap}" --target / --include "${wd}" \
    || die "${EX_REPO}" "Could not restore ${wd}"

  [ "${config_only}" = "1" ] && { log "Config-only restore finished"; return 0; }

  local v
  while IFS= read -r v; do
    [ -n "${v}" ] || continue
    log "Restoring volume ${v}"
    restic_exec restore "${snap}" --target / --include "${v}" >/dev/null 2>&1 \
      || warn "could not restore ${v}"
  done < <(jq -r --arg p "${project}" \
    '.projects[] | select(.name==$p) | .containers[]?.mounts[]? | select(.type=="volume") | .source' "${mf}" | sort -u)

  if [ "${recreate}" = "1" ]; then
    log "Recreating the stack"
    ( cd "${wd}" && docker compose up -d --force-recreate )
  else
    log "Files restored. Bring the stack up with:  cd ${wd} && docker compose up -d"
  fi
}

dr_restore_system() {
  local profile="$1" run="$2"
  case "${profile}" in
    safe)   dr_restore_payload_dirs ;;
    staged) dr_stage_dangerous ;;
    full)   dr_restore_payload_dirs; dr_stage_dangerous ;;
    *) die "${EX_USAGE}" "Unknown profile: ${profile} (safe|staged|full)" ;;
  esac
}
