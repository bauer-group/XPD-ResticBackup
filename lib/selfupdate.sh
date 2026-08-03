#!/usr/bin/env bash
# =============================================================================
# bg-backup - selfupdate / uninstall
# =============================================================================
# Releases are installed side by side under /opt/bg-backup/releases/<version>
# and activated by moving the `current` symlink. That makes an upgrade atomic
# and a rollback instant - which matters because the thing being upgraded is the
# thing that runs unattended at 03:00.
#
# Configuration is NEVER touched by an update.
# =============================================================================

[ -n "${_BGB_SELFUPDATE_SOURCED:-}" ] && return 0
_BGB_SELFUPDATE_SOURCED=1

: "${BGB_PREFIX:=/opt/bg-backup}"
: "${BGB_REPO_SLUG:=bauer-group/XPD-ResticBackup}"

cmd_self_update() {
  local check_only=0 want="" restic_only=0 rollback=0 channel="${BGB_UPDATE_CHANNEL}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)
        check_only=1
        shift
        ;;
      --version)
        want="$2"
        shift 2
        ;;
      --version=*)
        want="${1#*=}"
        shift
        ;;
      --restic-only)
        restic_only=1
        shift
        ;;
      --rollback)
        rollback=1
        shift
        ;;
      --channel)
        channel="$2"
        shift 2
        ;;
      -*)
        err "Unknown flag for self-update: $1"
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  require_root
  config_load

  [ "${rollback}" -eq 1 ] && {
    selfupdate_rollback
    return $?
  }
  [ "${restic_only}" -eq 1 ] && {
    selfupdate_restic
    return $?
  }

  local latest
  latest="$(selfupdate_latest_version "${channel}")"
  [ -n "${want}" ] && latest="${want}"

  if [ -z "${latest}" ]; then
    err "Could not determine the available version (no network, or GitHub is unreachable)"
    return "${EX_PRECOND}"
  fi

  if [ "${latest#v}" = "${BGB_VERSION}" ]; then
    log "Already on ${BGB_VERSION} - nothing to do"
    return 0
  fi

  log "Installed: ${BGB_VERSION}   Available: ${latest#v}"
  if [ "${check_only}" -eq 1 ]; then
    printf '%s\n' "${latest#v}"
    return 0
  fi

  confirm "Upgrade bg-backup from ${BGB_VERSION} to ${latest#v}?" || return 0

  # The installer is the single implementation of "put a release on this host",
  # so an upgrade and a fresh install cannot drift apart.
  log "Running the installer for ${latest}"
  local url="https://raw.githubusercontent.com/${BGB_REPO_SLUG}/${latest}/install.sh"
  local script
  script="$(tmp_file "install.XXXXXX.sh")"
  curl -fsSL -o "${script}" "${url}" || die "${EX_PRECOND}" "Could not download the installer for ${latest}"

  REF="${latest}" RESTIC_INSTALL=0 bash "${script}" \
    || die "${EX_FAIL}" "The upgrade failed. The previous release is still active."

  log "Reconciling systemd units with the configuration"
  lib_source systemd.sh
  systemd_sync || warn "schedule sync failed - run: bg-backup schedule sync"

  log "Running doctor against the new release"
  "${BGB_PREFIX}/current/bin/bg-backup.sh" doctor || warn "doctor reported problems"

  log "Upgraded to ${latest#v}. Roll back with: bg-backup self-update --rollback"
}

selfupdate_latest_version() {
  local channel="${1:-stable}"
  case "${channel}" in
    edge)
      printf 'main'
      return 0
      ;;
  esac
  have curl || return 1
  curl -fsSL "https://api.github.com/repos/${BGB_REPO_SLUG}/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4
}

selfupdate_rollback() {
  local current previous
  current="$(readlink -f "${BGB_PREFIX}/current" 2>/dev/null)"
  previous="$(find "${BGB_PREFIX}/releases" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | awk -v cur="${current}" '$2 != cur {print $2; exit}')"

  [ -n "${previous}" ] || die "${EX_PRECOND}" "No previous release to roll back to"

  log "Rolling back: $(basename "${current}") -> $(basename "${previous}")"
  confirm "Continue?" || return 0

  ln -sfn "${previous}" "${BGB_PREFIX}/current.new"
  mv -T "${BGB_PREFIX}/current.new" "${BGB_PREFIX}/current"

  lib_source systemd.sh
  systemd_sync || true
  log "Rolled back to $(basename "${previous}")"
}

# Called with no arguments from cmd_self_update; the parameter is for callers
# that want to pin a version.
# shellcheck disable=SC2120
selfupdate_restic() {
  local want="${1:-}"
  warn "Updating restic alone makes this host diverge from the rest of the fleet."
  warn "For a fleet, bump the pinned version in the Ansible role instead."
  confirm "Continue?" || return 0

  local url="https://raw.githubusercontent.com/${BGB_REPO_SLUG}/main/install.sh"
  local script
  script="$(tmp_file "install.XXXXXX.sh")"
  curl -fsSL -o "${script}" "${url}" || die "${EX_PRECOND}" "Could not download the installer"
  # Not named `env`: an array called `env` next to a call to the `env` COMMAND
  # reads as a bug even though bash resolves it correctly.
  local -a envv=(RESTIC_INSTALL=1 FORCE=1)
  [ -n "${want}" ] && envv+=("RESTIC_VERSION=${want}")
  env "${envv[@]}" bash "${script}"
}

# =============================================================================
# uninstall
# =============================================================================
cmd_uninstall() {
  local purge=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)
        purge=1
        shift
        ;;
      *) shift ;;
    esac
  done
  require_root
  config_load

  cat >&2 <<'EOF'

This removes the bg-backup tool from this host.

It does NOT touch the remote repository. Your backups will still exist, still be
readable with a plain restic binary, and still cost money at your storage
provider. Removing them is a separate, deliberate act.

EOF
  confirm "Remove bg-backup from this host?" || return 0

  if have systemctl; then
    local unit
    while IFS= read -r unit; do
      [ -n "${unit}" ] || continue
      systemctl disable --now "${unit}" >/dev/null 2>&1 || true
    done < <(systemctl list-unit-files --no-legend 'bg-backup*' 2>/dev/null | awk '{print $1}')
    rm -f /etc/systemd/system/bg-backup*.service /etc/systemd/system/bg-backup*.timer
    rm -rf /etc/systemd/system/bg-backup*.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
    log "Removed systemd units"
  fi

  rm -f /usr/local/sbin/bg-backup /usr/local/bin/bg-backup
  rm -f /etc/logrotate.d/bg-backup
  rm -rf "${BGB_PREFIX}"
  log "Removed the tool"

  if [ "${purge}" -eq 1 ]; then
    warn "PURGE will delete ${BGB_CONFDIR} - including the repository passphrase."
    warn "If that passphrase exists nowhere else, every backup becomes permanently"
    warn "unreadable. Export the recovery bundle first if you have not."
    if confirm "Delete configuration, credentials, state and logs?"; then
      rm -rf "${BGB_CONFDIR}" /var/lib/bg-backup "${BGB_LOG_DIR}"
      log "Purged configuration, state and logs"
    fi
  else
    log "Kept ${BGB_CONFDIR}, /var/lib/bg-backup and ${BGB_LOG_DIR}"
  fi

  printf '\n%sThe remote repository has NOT been touched.%s\n\n' "${C_YELLOW}" "${C_RESET}" >&2
}
