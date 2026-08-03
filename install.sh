#!/usr/bin/env bash
# =============================================================================
# bg-backup - Installer
# =============================================================================
# BAUER GROUP | https://github.com/bauer-group/XPD-ResticBackup
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
#
# Pinned version:
#   curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | \
#     REF=v1.0.0 bash
#
# Non-interactive with a repository (unattended provisioning):
#   curl -fsSL .../install.sh | \
#     INIT_REPO=1 ENABLE_TIMERS=1 \
#     BGB_REPOSITORY='s3:https://s3.example.com/backup-server/host.example.com' \
#     BGB_PASSWORD_FILE=/root/.bgb-pass \
#     BGB_S3_ACCESS_KEY=... BGB_S3_SECRET_KEY=... bash
#
# Cloud-Init (user-data):
#   runcmd:
#     - curl -fsSL .../install.sh | bash
#
# Uninstall:
#   curl -fsSL .../install.sh | UNINSTALL=1 bash
#
# Configuration is by environment variable, never argv - the script is piped
# into bash and has no usable command line.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
REPO_SLUG="${REPO_SLUG:-bauer-group/XPD-ResticBackup}"
REPO_URL="${REPO_URL:-https://github.com/${REPO_SLUG}}"
REF="${REF:-main}"                          # main | v1.2.3 | <sha>
INSTALL_METHOD="${INSTALL_METHOD:-tarball}" # tarball | git | local
SOURCE_DIR="${SOURCE_DIR:-}"                # local checkout; implies INSTALL_METHOD=local

PREFIX="${PREFIX:-/opt/bg-backup}"
BINDIR="${BINDIR:-/usr/local/sbin}"
CONFDIR="${CONFDIR:-/etc/bg-backup}"
LOGDIR="${LOGDIR:-/var/log/bg-backup}"
STATEDIR="${STATEDIR:-/var/lib/bg-backup}"
UNITDIR="${UNITDIR:-/etc/systemd/system}"

RESTIC_INSTALL="${RESTIC_INSTALL:-1}"
RESTIC_VERSION="${RESTIC_VERSION:-0.19.1}"
RESTIC_BINARY="${RESTIC_BINARY:-}"    # pre-downloaded binary (air-gapped)
RESTIC_VERIFY="${RESTIC_VERIFY:-gpg}" # gpg | sha | none
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"

INSTALL_JQ="${INSTALL_JQ:-1}"
INSTALL_FUSE="${INSTALL_FUSE:-0}"
INSTALL_LOGROTATE="${INSTALL_LOGROTATE:-1}"
OFFLINE="${OFFLINE:-0}"

PROFILE="${PROFILE:-server}" # minimal | server | docker
INIT_REPO="${INIT_REPO:-0}"
ENABLE_TIMERS="${ENABLE_TIMERS:-0}"
RUN_DISCOVER="${RUN_DISCOVER:-0}"

UNINSTALL="${UNINSTALL:-0}"
PURGE="${PURGE:-0}"
FORCE="${FORCE:-0}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"

MARKER_FILE="${CONFDIR}/.installed"
LOCK_DIR="/run/lock/bg-backup-install.d"
LOG_FILE="${LOG_FILE:-${LOGDIR}/install.log}"

RESTIC_RELEASE_KEY_FPR="CF8F18F2844575973F79D4E191A6868BD3F7A907"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

log() { echo "${GREEN}[bg-backup]${NC} $*"; }
warn() { echo "${YELLOW}[bg-backup WARN]${NC} $*" >&2; }
err() { echo "${RED}[bg-backup ERROR]${NC} $*" >&2; }

TMP_DIR=""
cleanup() {
  [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
  rm -rf "${LOCK_DIR}"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This installer must be run as root"
    err "  curl -fsSL .../install.sh | sudo bash"
    exit 1
  fi
}

acquire_lock() {
  local owner=""
  mkdir -p "$(dirname "${LOCK_DIR}")" 2>/dev/null || true
  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    # /run/lock is tmpfs, so a lock can only be stale within the same boot;
    # a live PID check is therefore sufficient to reclaim it safely.
    if [ -n "${owner}" ] && kill -0 "${owner}" 2>/dev/null; then
      err "Another installation is running (PID ${owner})"
      exit 1
    fi
    warn "Reclaiming stale installer lock (PID ${owner:-unknown})"
    rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}"
  fi
  echo "$$" >"${LOCK_DIR}/pid"
}

detect_os() {
  if [ ! -r /etc/os-release ]; then
    err "Cannot detect OS: /etc/os-release not found"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-unknown}"
  # shellcheck disable=SC2034  # consumed by version gating below and by callers
  OS_VERSION_MAJOR="${OS_VERSION%%.*}"

  case "${OS_ID}" in
    ubuntu | debian | linuxmint | pop) OS_FAMILY="debian" ;;
    centos | rhel | rocky | almalinux | fedora | ol) OS_FAMILY="redhat" ;;
    *) OS_FAMILY="unknown" ;;
  esac

  log "Detected ${OS_ID} ${OS_VERSION} (${OS_CODENAME}), family: ${OS_FAMILY}"

  # Never hard-fail on an unrecognised release. 26.04 "resolute" was unknown to
  # every piece of tooling on the day it shipped, and an installer that refuses
  # to run on a new LTS is an installer that gets bypassed with a manual copy.
  if [ "${OS_ID}" = "ubuntu" ]; then
    case "${OS_VERSION}" in
      22.04 | 24.04 | 26.04) : ;;
      *) warn "Ubuntu ${OS_VERSION} is outside the tested set (22.04, 24.04, 26.04) - continuing" ;;
    esac
  elif [ "${OS_FAMILY}" != "debian" ]; then
    warn "Only Ubuntu 22.04/24.04/26.04 is tested; ${OS_ID} is unsupported"
    if [ "${FORCE}" != "1" ]; then
      err "Refusing to continue. Set FORCE=1 to install anyway."
      exit 1
    fi
  fi
}

detect_arch() {
  local m
  m="$(uname -m)"
  case "${m}" in
    x86_64 | amd64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    armv7l | armv6l) ARCH="arm" ;;
    i686 | i386) ARCH="386" ;;
    riscv64) ARCH="riscv64" ;;
    *)
      err "Unsupported architecture: ${m}"
      err "Supported: x86_64, aarch64, armv7l, i686, riscv64"
      exit 1
      ;;
  esac
  log "Architecture: ${ARCH}"
}

install_dependencies() {
  local -a want=(ca-certificates curl tar bzip2)
  [ "${INSTALL_JQ}" = "1" ] && want+=(jq)
  [ "${INSTALL_FUSE}" = "1" ] && want+=(fuse3)
  [ "${INSTALL_LOGROTATE}" = "1" ] && want+=(logrotate)
  [ "${RESTIC_VERIFY}" = "gpg" ] && want+=(gnupg)

  local -a missing=()
  local p
  for p in "${want[@]}"; do
    dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "ok installed" || missing+=("${p}")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "All dependencies present"
    return 0
  fi

  if [ "${OFFLINE}" = "1" ]; then
    warn "OFFLINE=1 and missing packages: ${missing[*]} - continuing without them"
    return 0
  fi

  log "Installing dependencies: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

# -----------------------------------------------------------------------------
# restic
# -----------------------------------------------------------------------------
# Upstream publishes SHA256SUMS and SHA256SUMS.asc signed by the restic release
# key. That key is vendored in this repository (reviewed once by a human,
# fingerprint pinned) so verification never depends on a reachable keyserver.
#
# We do NOT install the distribution package: jammy ships restic 0.12.1, which
# has neither repository-format-v2 compression nor --stdin-from-command. A
# database dump piped into 0.12.1 cannot fail safely, which is the whole point.
install_restic() {
  local target="/usr/local/bin/restic"

  if [ "${RESTIC_INSTALL}" != "1" ]; then
    log "RESTIC_INSTALL=0 - assuming restic is already on PATH"
    command -v restic >/dev/null 2>&1 || warn "restic not found on PATH"
    return 0
  fi

  if [ -n "${RESTIC_BINARY}" ]; then
    log "Installing restic from local file: ${RESTIC_BINARY}"
    install -o root -g root -m 0755 "${RESTIC_BINARY}" "${target}"
    "${target}" version >/dev/null || {
      err "Provided restic binary is not executable"
      exit 1
    }
    log "restic installed: $("${target}" version | head -1)"
    return 0
  fi

  if [ -x "${target}" ]; then
    local cur
    cur="$("${target}" version 2>/dev/null | awk '{print $2; exit}')"
    if [ "${cur}" = "${RESTIC_VERSION}" ] && [ "${FORCE}" != "1" ]; then
      log "restic ${cur} already installed (pinned version) - skipping download"
      return 0
    fi
  fi

  if [ "${OFFLINE}" = "1" ]; then
    err "OFFLINE=1 but restic is not installed and RESTIC_BINARY is unset"
    exit 1
  fi

  local base file dl verified="none"
  base="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}"
  file="restic_${RESTIC_VERSION}_linux_${ARCH}.bz2"
  dl="${TMP_DIR}/restic"
  mkdir -p "${dl}"

  log "Downloading restic ${RESTIC_VERSION} (${ARCH})"
  curl -fsSL --retry 3 --retry-delay 5 -o "${dl}/${file}" "${base}/${file}"
  curl -fsSL --retry 3 --retry-delay 5 -o "${dl}/SHA256SUMS" "${base}/SHA256SUMS"
  curl -fsSL --retry 3 --retry-delay 5 -o "${dl}/SHA256SUMS.asc" "${base}/SHA256SUMS.asc" || true

  # --- Step 1: GPG signature over SHA256SUMS --------------------------------
  local keyfile="${PAYLOAD_DIR}/share/restic/restic-release-key.asc"
  local fprfile="${PAYLOAD_DIR}/share/restic/restic-release-key.fpr"

  if [ "${RESTIC_VERIFY}" = "gpg" ] && command -v gpg >/dev/null 2>&1 \
    && [ -s "${dl}/SHA256SUMS.asc" ] && [ -s "${keyfile}" ]; then
    local gnupg="${dl}/gnupg" want status
    mkdir -p "${gnupg}"
    chmod 0700 "${gnupg}"
    want="$(tr -d ' \r\n' <"${fprfile}")"
    [ -n "${want}" ] || want="${RESTIC_RELEASE_KEY_FPR}"

    if gpg --homedir "${gnupg}" --batch --quiet --import "${keyfile}" 2>/dev/null; then
      # Verify against --status-fd and require VALIDSIG for the PINNED
      # fingerprint. Checking only "gpg exited 0" would accept a signature from
      # any key that happened to be in the keyring; checking only "the pinned
      # key is present" would not tie it to this signature at all.
      status="$(gpg --homedir "${gnupg}" --batch --status-fd 1 --verify \
        "${dl}/SHA256SUMS.asc" "${dl}/SHA256SUMS" 2>/dev/null || true)"
      if printf '%s' "${status}" | grep -q "VALIDSIG ${want}"; then
        verified="gpg"
        log "GPG signature verified (${want})"
      else
        err "GPG verification of SHA256SUMS FAILED - the signature is missing,"
        err "invalid, or made by a key other than the pinned restic release key."
        err "Refusing to install. Pinned fingerprint: ${want}"
        exit 1
      fi
    else
      warn "Could not import the vendored restic key - falling back to digest pinning"
    fi
  fi

  # --- Step 2: checksum, always ---------------------------------------------
  local sums="${dl}/SHA256SUMS"
  local pinned="${PAYLOAD_DIR}/share/restic/SHA256SUMS.pinned"
  if [ "${verified}" != "gpg" ]; then
    # Without a signature, an unsigned SHA256SUMS fetched over the same channel
    # as the binary proves nothing - whoever could swap one could swap both.
    # Only a digest list that went through code review in this repository is
    # trustworthy at that point.
    if [ -s "${pinned}" ] && grep -q " ${file}\$" "${pinned}"; then
      sums="${pinned}"
      verified="pinned"
      warn "GPG unavailable - verifying against the digest pinned in this release"
    elif [ "${ALLOW_UNVERIFIED}" = "1" ]; then
      warn "PROCEEDING WITHOUT VERIFICATION (ALLOW_UNVERIFIED=1)"
      verified="none"
    else
      err "Cannot verify restic: no usable GPG signature and no pinned digest for ${file}"
      err "Install gnupg, pin RESTIC_VERSION to a release covered by SHA256SUMS.pinned,"
      err "or set ALLOW_UNVERIFIED=1 if you accept the risk."
      exit 1
    fi
  fi

  if [ "${verified}" != "none" ]; then
    (cd "${dl}" && grep " ${file}\$" "${sums}" | sha256sum -c --strict -) >/dev/null \
      || {
        err "SHA256 mismatch for ${file} - refusing to install"
        exit 1
      }
    log "Checksum verified (${verified})"
  fi

  bunzip2 -c "${dl}/${file}" >"${dl}/restic.bin"
  chmod 0755 "${dl}/restic.bin"
  "${dl}/restic.bin" version >/dev/null || {
    err "Downloaded restic is not executable"
    exit 1
  }
  install -o root -g root -m 0755 "${dl}/restic.bin" "${target}"
  log "restic installed: $("${target}" version | head -1)"
}

# -----------------------------------------------------------------------------
# Payload
# -----------------------------------------------------------------------------
fetch_payload() {
  PAYLOAD_DIR="${TMP_DIR}/payload"

  if [ -n "${SOURCE_DIR}" ]; then
    INSTALL_METHOD="local"
  fi

  case "${INSTALL_METHOD}" in
    local)
      [ -d "${SOURCE_DIR}" ] || {
        err "SOURCE_DIR does not exist: ${SOURCE_DIR}"
        exit 1
      }
      log "Installing from local source: ${SOURCE_DIR}"
      mkdir -p "${PAYLOAD_DIR}"
      tar -C "${SOURCE_DIR}" -cf - bin lib share VERSION 2>/dev/null | tar -C "${PAYLOAD_DIR}" -xf -
      ;;
    git)
      command -v git >/dev/null 2>&1 || {
        err "INSTALL_METHOD=git but git is not installed"
        exit 1
      }
      log "Cloning ${REPO_URL} @ ${REF}"
      git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${PAYLOAD_DIR}" >/dev/null 2>&1
      ;;
    tarball)
      local url
      case "${REF}" in
        v* | [0-9]*) url="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/tags/${REF}" ;;
        *) url="https://codeload.github.com/${REPO_SLUG}/tar.gz/refs/heads/${REF}" ;;
      esac
      log "Downloading payload ${REF}"
      mkdir -p "${PAYLOAD_DIR}"
      curl -fsSL --retry 3 --retry-delay 5 "${url}" \
        | tar -C "${PAYLOAD_DIR}" -xz --strip-components=1
      ;;
    *)
      err "Unknown INSTALL_METHOD: ${INSTALL_METHOD} (tarball|git|local)"
      exit 1
      ;;
  esac

  # Sanity: the tree must look like this product before we trust it.
  local f
  for f in bin/bg-backup.sh lib/core.sh VERSION; do
    [ -e "${PAYLOAD_DIR}/${f}" ] || {
      err "Payload is incomplete: ${f} missing"
      exit 1
    }
  done

  # Syntax gate. Installing a payload that cannot be parsed would leave the host
  # with a broken binary in PATH and timers pointing at it.
  local bad=0
  while IFS= read -r f; do
    bash -n "${f}" 2>/dev/null || {
      err "Syntax error in payload: ${f#"${PAYLOAD_DIR}"/}"
      bad=1
    }
  done < <(find "${PAYLOAD_DIR}/bin" "${PAYLOAD_DIR}/lib" "${PAYLOAD_DIR}/share" -name '*.sh' -type f 2>/dev/null)
  [ "${bad}" -eq 0 ] || {
    err "Refusing to install a payload that does not parse"
    exit 1
  }

  PAYLOAD_VERSION="$(tr -d ' \r\n' <"${PAYLOAD_DIR}/VERSION")"
  log "Payload version: ${PAYLOAD_VERSION}"
}

install_payload() {
  local dest="${PREFIX}/releases/${PAYLOAD_VERSION}"
  local staging="${dest}.tmp.$$"

  mkdir -p "${PREFIX}/releases"
  rm -rf "${staging}"
  mkdir -p "${staging}"
  tar -C "${PAYLOAD_DIR}" -cf - bin lib share VERSION | tar -C "${staging}" -xf -
  chmod 0755 "${staging}/bin/bg-backup.sh"
  find "${staging}/share" -name '*.sh' -type f -exec chmod 0755 {} + 2>/dev/null || true

  rm -rf "${dest}"
  mv -T "${staging}" "${dest}"

  # Atomic activation: create the new link beside the old one and rename over
  # it, so `current` is never briefly missing while a timer might fire.
  ln -sfn "${dest}" "${PREFIX}/current.new"
  mv -T "${PREFIX}/current.new" "${PREFIX}/current"

  install -d -m 0755 "${BINDIR}"
  ln -sfn "${PREFIX}/current/bin/bg-backup.sh" "${BINDIR}/bg-backup"
  # /usr/local/bin as well: many sudo configurations drop sbin from PATH.
  [ -d /usr/local/bin ] && ln -sfn "${BINDIR}/bg-backup" /usr/local/bin/bg-backup

  log "Installed ${PAYLOAD_VERSION} to ${dest}"

  # Keep the last N releases so self-update --rollback has somewhere to go.
  local -a old=()
  mapfile -t old < <(find "${PREFIX}/releases" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | tail -n +$((KEEP_RELEASES + 1)) | cut -d' ' -f2-)
  local d
  for d in "${old[@]:-}"; do
    [ -n "${d}" ] && [ "${d}" != "${dest}" ] || continue
    log "Pruning old release: $(basename "${d}")"
    rm -rf "${d}"
  done
}

# -----------------------------------------------------------------------------
# Directories, configuration, units
# -----------------------------------------------------------------------------
setup_directories() {
  install -d -m 0750 "${CONFDIR}"
  install -d -m 0700 "${CONFDIR}/credentials"
  install -d -m 0750 "${CONFDIR}/conf.d"
  install -d -m 0755 "${CONFDIR}/excludes"
  install -d -m 0750 "${CONFDIR}/hooks"
  install -d -m 0750 "${LOGDIR}"
  install -d -m 0750 "${LOGDIR}/jobs"
  install -d -m 0700 "${STATEDIR}"
  install -d -m 0700 "${STATEDIR}/state"
  install -d -m 0700 "${STATEDIR}/cache"
  install -d -m 0700 "${STATEDIR}/tmp"
  install -d -m 0700 "${STATEDIR}/facts"
  install -d -m 0700 "${STATEDIR}/restore"
  install -d -m 0700 "${STATEDIR}/export"
}

seed_config() {
  local src="${PREFIX}/current/share/config"
  local f base target

  _seed() {
    local from="$1" to="$2" mode="$3"
    if [ ! -e "${to}" ]; then
      install -m "${mode}" "${from}" "${to}"
      log "Created ${to}"
    else
      # Never modify live configuration on upgrade. Drop the new default beside
      # it so an operator can diff deliberately.
      if ! cmp -s "${from}" "${to}.new" 2>/dev/null; then
        install -m "${mode}" "${from}" "${to}.new"
        warn "${to} exists - new default written to ${to}.new (diff it)"
      fi
    fi
  }

  [ -e "${src}/bg-backup.conf.example" ] \
    && _seed "${src}/bg-backup.conf.example" "${CONFDIR}/bg-backup.conf" 0640

  for f in "${PREFIX}"/current/share/excludes/*.exclude; do
    [ -e "${f}" ] || continue
    install -m 0644 "${f}" "${CONFDIR}/excludes/$(basename "${f}")"
  done

  # Job profiles decide which conf.d entries are seeded.
  local -a jobs=()
  case "${PROFILE}" in
    minimal) jobs=(90-config) ;;
    server) jobs=(10-system 90-config) ;;
    docker) jobs=(10-system 20-docker 90-config) ;;
    *)
      warn "Unknown PROFILE=${PROFILE}, using 'server'"
      jobs=(10-system 90-config)
      ;;
  esac
  for base in "${jobs[@]}"; do
    f="${src}/conf.d/${base}.conf.example"
    target="${CONFDIR}/conf.d/${base}.conf"
    [ -e "${f}" ] && _seed "${f}" "${target}" 0640
  done
}

install_units() {
  command -v systemctl >/dev/null 2>&1 || {
    warn "systemd not present - skipping units"
    return 0
  }
  local src="${PREFIX}/current/share/systemd" f
  [ -d "${src}" ] || {
    warn "No systemd templates in payload"
    return 0
  }

  for f in "${src}"/*.service "${src}"/*.timer; do
    [ -e "${f}" ] || continue
    install -m 0644 "${f}" "${UNITDIR}/$(basename "${f}")"
  done

  if [ "${INSTALL_LOGROTATE}" = "1" ] && [ -e "${PREFIX}/current/share/logrotate/bg-backup" ]; then
    install -d -m 0755 /etc/logrotate.d
    install -m 0644 "${PREFIX}/current/share/logrotate/bg-backup" /etc/logrotate.d/bg-backup
  fi

  systemctl daemon-reload 2>/dev/null || true
  log "systemd units installed (nothing enabled yet)"
}

# -----------------------------------------------------------------------------
# Optional non-interactive repository setup
# -----------------------------------------------------------------------------
maybe_init_repo() {
  [ "${INIT_REPO}" = "1" ] || return 0

  if [ -z "${BGB_REPOSITORY:-}" ]; then
    err "INIT_REPO=1 but BGB_REPOSITORY is not set"
    exit 1
  fi
  if [ -z "${BGB_PASSWORD:-}" ] && [ -z "${BGB_PASSWORD_FILE:-}" ]; then
    err "INIT_REPO=1 but neither BGB_PASSWORD nor BGB_PASSWORD_FILE is set"
    exit 1
  fi

  local -a args=(init --non-interactive --repo "${BGB_REPOSITORY}" --profile "${PROFILE}")
  [ -n "${BGB_PASSWORD_FILE:-}" ] && args+=(--password-file "${BGB_PASSWORD_FILE}")
  [ -n "${BGB_S3_ACCESS_KEY:-}" ] && args+=(--s3-key "${BGB_S3_ACCESS_KEY}")
  [ -n "${BGB_S3_SECRET_KEY:-}" ] && args+=(--s3-secret "${BGB_S3_SECRET_KEY}")
  [ -n "${BGB_S3_REGION:-}" ] && args+=(--s3-region "${BGB_S3_REGION}")

  log "Initialising repository (non-interactive)"
  # BGB_PASSWORD reaches init through the environment, never as an argument:
  # /proc/<pid>/cmdline is world-readable, /proc/<pid>/environ is not.
  if ! BGB_PASSWORD="${BGB_PASSWORD:-}" "${BINDIR}/bg-backup" "${args[@]}"; then
    err "Repository initialisation failed - not enabling any timer"
    exit 1
  fi

  if [ "${RUN_DISCOVER}" = "1" ]; then
    "${BINDIR}/bg-backup" discover --write || warn "discover failed (non-fatal)"
  fi

  if [ "${ENABLE_TIMERS}" = "1" ]; then
    log "Enabling timers"
    "${BINDIR}/bg-backup" schedule sync
    "${BINDIR}/bg-backup" schedule enable
  fi
}

# -----------------------------------------------------------------------------
# Uninstall
# -----------------------------------------------------------------------------
do_uninstall() {
  log "Uninstalling bg-backup"

  if command -v systemctl >/dev/null 2>&1; then
    local unit
    while IFS= read -r unit; do
      [ -n "${unit}" ] || continue
      systemctl disable --now "${unit}" 2>/dev/null || true
    done < <(systemctl list-unit-files --no-legend 'bg-backup*' 2>/dev/null | awk '{print $1}')
    rm -f "${UNITDIR}"/bg-backup*.service "${UNITDIR}"/bg-backup*.timer
    rm -rf "${UNITDIR}"/bg-backup*.service.d
    systemctl daemon-reload 2>/dev/null || true
  fi

  rm -f "${BINDIR}/bg-backup" /usr/local/bin/bg-backup
  rm -rf "${PREFIX}"
  rm -f /etc/logrotate.d/bg-backup

  if [ "${PURGE}" = "1" ]; then
    if [ "${FORCE}" != "1" ] && [ -t 0 ]; then
      printf '%s' "PURGE=1 will delete ${CONFDIR} (including credentials), ${STATEDIR} and ${LOGDIR}. Continue? [y/N] "
      local reply
      read -r reply
      case "${reply}" in [yY] | [yY][eE][sS]) : ;; *)
        log "Aborted; configuration kept."
        PURGE=0
        ;;
      esac
    fi
  fi

  if [ "${PURGE}" = "1" ]; then
    rm -rf "${CONFDIR}" "${STATEDIR}" "${LOGDIR}"
    log "Purged configuration, state and logs"
  else
    log "Kept ${CONFDIR}, ${STATEDIR} and ${LOGDIR} (use PURGE=1 to remove)"
  fi

  echo
  echo "${RED}The remote repository has NOT been touched.${NC}"
  echo "Your backups still exist and still cost money. To remove them you must"
  echo "delete them at the storage backend deliberately - this installer will"
  echo "never do that for you."
  log "Uninstall complete"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  require_root
  mkdir -p "${LOGDIR}" 2>/dev/null || true
  acquire_lock

  if [ "${UNINSTALL}" = "1" ]; then
    do_uninstall
    exit 0
  fi

  if [ -f "${MARKER_FILE}" ] && [ "${FORCE}" != "1" ]; then
    local installed
    installed="$(awk -F= '/^version=/{print $2}' "${MARKER_FILE}" 2>/dev/null || true)"
    log "bg-backup ${installed:-?} is already installed - upgrading in place"
    log "(configuration is never modified; FORCE=1 redoes everything)"
  fi

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bg-backup-install.XXXXXX")"

  detect_os
  detect_arch
  install_dependencies
  fetch_payload
  install_restic
  install_payload
  setup_directories
  seed_config
  install_units

  cat >"${MARKER_FILE}" <<EOF
version=${PAYLOAD_VERSION}
ref=${REF}
restic=${RESTIC_VERSION}
installed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  chmod 0600 "${MARKER_FILE}"

  maybe_init_repo

  echo
  log "Installation complete: bg-backup ${PAYLOAD_VERSION}"
  echo
  "${BINDIR}/bg-backup" doctor || true
  echo
  if [ "${INIT_REPO}" != "1" ]; then
    cat <<EOF
Next steps:

  1. Configure a repository and generate a passphrase:
       bg-backup init

  2. Look at what this host actually has (filesystems, compose projects, databases):
       bg-backup discover

  3. Run a first backup by hand before trusting a timer:
       bg-backup backup --all

  4. Prove you can get it back, then arm the schedule:
       bg-backup restore preview file --path /etc/hostname
       bg-backup schedule sync && bg-backup schedule enable

  No timer is enabled until you do step 4. A scheduled backup that fails every
  night is worse than no schedule: it produces alert fatigue and false confidence.
EOF
  fi
}

main "$@"
