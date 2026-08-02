#!/usr/bin/env bash
# =============================================================================
# bg-backup - core: exit codes, logging, traps, temp files, small helpers
# =============================================================================
# Sourced by bin/bg-backup.sh before anything else. Defines no behaviour on its
# own beyond setting defaults - sourcing this file must never have a side effect
# that a --help invocation would have to pay for.
#
# Every other lib/*.sh may assume this file is already sourced.
# =============================================================================

# Guard against double sourcing (lib modules source each other freely).
[ -n "${_BGB_CORE_SOURCED:-}" ] && return 0
_BGB_CORE_SOURCED=1

# -----------------------------------------------------------------------------
# Exit codes - the scheduling interface
# -----------------------------------------------------------------------------
# Honoured by every command and asserted by tests/unit/exit_codes.bats. Anything
# consuming bg-backup (systemd, Ansible, a monitoring probe) keys off these, so
# they are API: adding is allowed, renumbering is a breaking change.
#
# EX_PARTIAL is deliberately NOT collapsed into success or failure. It is the
# difference between "some files were unreadable" and "no backup exists", and a
# tool that loses that distinction teaches its operators to ignore both.
readonly EX_OK=0        # success
readonly EX_FAIL=1      # generic fatal error
readonly EX_USAGE=2     # unknown flag, missing argument
readonly EX_PARTIAL=3   # snapshot created, some sources unreadable (restic 3)
readonly EX_PRECOND=4   # not root, missing dependency, invalid config
readonly EX_LOCKED=5    # another instance holds the lock
readonly EX_REPO=6      # repository unreachable / uninitialised / wrong key
readonly EX_VERIFY=7    # check or verify found damage
readonly EX_HOOK=8      # a pre/post hook failed
readonly EX_SAFETY=9    # a safety rail refused a destructive operation
readonly EX_INTERRUPT=130

# -----------------------------------------------------------------------------
# Runtime defaults (overridable by config, environment, then flags)
# -----------------------------------------------------------------------------
: "${BGB_LOG_LEVEL:=info}"        # error|warn|info|debug
: "${BGB_QUIET:=0}"
: "${BGB_JSON:=0}"
: "${BGB_DRY_RUN:=0}"
: "${BGB_YES:=0}"
: "${BGB_COLOR:=auto}"            # auto|always|never
: "${BGB_LOG_DIR:=/var/log/bg-backup}"
: "${BGB_TMP_DIR:=/var/lib/bg-backup/tmp}"
: "${BGB_COMMAND:=}"
: "${BGB_JOB:=}"

# Populated by log_open(); until then every message goes to stderr only.
_BGB_LOGFILE=""

# -----------------------------------------------------------------------------
# Colour
# -----------------------------------------------------------------------------
_bgb_init_colour() {
  local use=0
  case "${BGB_COLOR}" in
    always) use=1 ;;
    never) use=0 ;;
    # NO_COLOR is honoured regardless of TTY (https://no-color.org).
    *) [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && use=1 ;;
  esac
  if [ "${use}" -eq 1 ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_BOLD=""; C_RESET=""
  fi
}
_bgb_init_colour

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# Contract, relied on by --json consumers: every human-readable message goes to
# STDERR. STDOUT carries payload only. Breaking this makes `bg-backup snapshots
# --json | jq` fail in a way that is tedious to trace back here.
#
# Everything routed through _bgb_emit passes redact() when lib/redact.sh is
# loaded, so a credential can never reach a log file or a notifier payload.

_bgb_level_num() {
  case "$1" in
    error) echo 0 ;; warn) echo 1 ;; info) echo 2 ;; debug) echo 3 ;; *) echo 2 ;;
  esac
}

_bgb_emit() {
  local level="$1" prefix="$2" msg="$3"
  local want cur
  want="$(_bgb_level_num "${BGB_LOG_LEVEL}")"
  cur="$(_bgb_level_num "${level}")"

  # redact() is defined by lib/redact.sh. During very early startup it may not
  # be loaded yet; those messages cannot contain secrets (no config is parsed).
  if declare -F redact >/dev/null 2>&1; then
    msg="$(redact "${msg}")"
  fi

  # The log file always receives everything, independent of the console level -
  # a debug run should never be needed to reconstruct what happened.
  if [ -n "${_BGB_LOGFILE}" ]; then
    printf '%s [%s] %s%s\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${level}" \
      "${BGB_JOB:+${BGB_JOB}: }" "${msg}" >>"${_BGB_LOGFILE}" 2>/dev/null || true
  fi

  [ "${cur}" -gt "${want}" ] && return 0
  [ "${BGB_QUIET}" = "1" ] && [ "${cur}" -ge 2 ] && return 0
  printf '%s %s\n' "${prefix}" "${msg}" >&2
}

log()   { _bgb_emit info  "${C_GREEN}[bg-backup]${C_RESET}"       "$*"; }
warn()  { _bgb_emit warn  "${C_YELLOW}[bg-backup WARN]${C_RESET}" "$*"; }
err()   { _bgb_emit error "${C_RED}[bg-backup ERROR]${C_RESET}"   "$*"; }
debug() { _bgb_emit debug "${C_DIM}[bg-backup debug]${C_RESET}"   "$*"; }

# Status markers for `doctor` and other check-style output (house style, see
# IAC-Cloud/scripts/doctor.sh).
ok_mark()   { printf '  %s✓%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*" >&2; }
warn_mark() { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
bad_mark()  { printf '  %s✗%s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; }

# die <exit-code> <message...>
die() {
  local code="$1"; shift
  err "$*"
  exit "${code}"
}

# log_open <path> - start appending to a log file as well as stderr.
log_open() {
  local f="$1" d
  d="$(dirname "${f}")"
  mkdir -p "${d}" 2>/dev/null || return 0
  : >>"${f}" 2>/dev/null || return 0
  chmod 0640 "${f}" 2>/dev/null || true
  _BGB_LOGFILE="${f}"
}

# -----------------------------------------------------------------------------
# Cleanup registry
# -----------------------------------------------------------------------------
# A single EXIT trap with a registry, rather than each module installing its own
# trap and silently replacing the previous one. Handlers run in REVERSE
# registration order, so teardown mirrors setup.
#
# Ordering here is load-bearing: quiesce must be reversed before locks are
# released, otherwise a waiting job could start while Docker is still stopped.
_BGB_CLEANUP_HANDLERS=()

on_cleanup() { _BGB_CLEANUP_HANDLERS+=("$1"); }

_bgb_run_cleanup() {
  local i handler
  for (( i=${#_BGB_CLEANUP_HANDLERS[@]}-1; i>=0; i-- )); do
    handler="${_BGB_CLEANUP_HANDLERS[i]}"
    # Never let a failing handler abort the remaining ones, and never let it
    # change the exit code we are on our way to returning.
    "${handler}" || true
  done
  _BGB_CLEANUP_HANDLERS=()
}

_bgb_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  _bgb_run_cleanup
  exit "${rc}"
}

_bgb_on_signal() {
  local sig="$1"
  trap - EXIT INT TERM
  warn "Interrupted (SIG${sig}) - undoing any quiesce and releasing locks"
  _bgb_run_cleanup
  exit "${EX_INTERRUPT}"
}

install_traps() {
  trap _bgb_on_exit EXIT
  trap '_bgb_on_signal INT'  INT
  trap '_bgb_on_signal TERM' TERM
}

# -----------------------------------------------------------------------------
# Temp files
# -----------------------------------------------------------------------------
_BGB_TMP_ROOT=""

# tmp_root - lazily create a private scratch directory, removed on exit.
tmp_root() {
  if [ -z "${_BGB_TMP_ROOT}" ]; then
    mkdir -p "${BGB_TMP_DIR}" 2>/dev/null || BGB_TMP_DIR="${TMPDIR:-/tmp}"
    _BGB_TMP_ROOT="$(mktemp -d "${BGB_TMP_DIR}/bgb.XXXXXXXX")"
    chmod 0700 "${_BGB_TMP_ROOT}"
    on_cleanup _bgb_tmp_cleanup
  fi
  printf '%s' "${_BGB_TMP_ROOT}"
}

tmp_file() {
  local name="${1:-f.XXXXXX}"
  mktemp "$(tmp_root)/${name}"
}

_bgb_tmp_cleanup() {
  [ -n "${_BGB_TMP_ROOT}" ] && [ -d "${_BGB_TMP_ROOT}" ] || return 0
  rm -rf "${_BGB_TMP_ROOT}"
  _BGB_TMP_ROOT=""
}

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "${EX_PRECOND}" "This command must be run as root (try: sudo bg-backup ${BGB_COMMAND})"
}

# require_cmd <cmd> [hint]
require_cmd() {
  have "$1" && return 0
  die "${EX_PRECOND}" "Required command not found: $1${2:+ (${2})}"
}

# require_jq - jq is a hard dependency for JSON output and for anything that
# parses restic or docker output, but NOT for a plain backup or restore. That
# separation is deliberate: disaster recovery must never block on a missing
# package. We refuse explicitly rather than hand-parsing JSON with sed.
require_jq() {
  have jq && return 0
  die "${EX_PRECOND}" "jq is required for this command (apt-get install -y jq)"
}

# -----------------------------------------------------------------------------
# Execution helpers
# -----------------------------------------------------------------------------

# retry <attempts> <delay-seconds> -- <command...>
# For transient conditions only (network, S3 5xx). Never wrap a database dump or
# a hook in this: retrying a failed dump hides the failure it was meant to
# surface, and retrying a partially-applied hook is worse than not retrying.
retry() {
  local attempts="$1" delay="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local n=1 rc=0
  while :; do
    rc=0
    "$@" || rc=$?
    [ "${rc}" -eq 0 ] && return 0
    if [ "${n}" -ge "${attempts}" ]; then
      debug "retry: giving up after ${n} attempt(s), rc=${rc}"
      return "${rc}"
    fi
    warn "Attempt ${n}/${attempts} failed (rc=${rc}), retrying in ${delay}s"
    sleep "${delay}"
    n=$(( n + 1 ))
  done
}

# run_logged <logfile> <command...>
# Runs a command, mirroring output to a log file, and returns the COMMAND's exit
# status - not tee's. $? after a pipeline is the last element's status, which is
# the single most common way a shell wrapper reports a failed backup as success.
run_logged() {
  local logfile="$1"; shift
  local rc=0
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] $*"
    return 0
  fi
  set +e
  "$@" 2>&1 | tee -a "${logfile}"
  rc="${PIPESTATUS[0]}"
  set -e
  return "${rc}"
}

# confirm <prompt> - interactive y/N gate, auto-yes with --yes, refuses when not
# attached to a terminal (an unattended run must never hang on a prompt).
confirm() {
  local prompt="$1" reply=""
  [ "${BGB_YES}" = "1" ] && return 0
  if [ ! -t 0 ]; then
    err "Refusing to proceed: ${prompt}"
    err "Not attached to a terminal - re-run with --yes to confirm non-interactively."
    return 1
  fi
  printf '%s%s [y/N]%s ' "${C_BOLD}" "${prompt}" "${C_RESET}" >&2
  read -r reply
  case "${reply}" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# -----------------------------------------------------------------------------
# Small utilities
# -----------------------------------------------------------------------------
now_iso()  { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date -u '+%s'; }

fqdn() {
  local h
  h="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  printf '%s' "${h}"
}

# atomic_write <target> - reads stdin, writes it into place atomically.
# Consumers of these files (node_exporter's textfile collector, a sourcing
# shell) can read at any moment; a half-written file is a parse error for the
# whole file, not just the truncated line.
atomic_write() {
  local target="$1" mode="${2:-0640}" tmp
  tmp="$(mktemp "${target}.XXXXXX")"
  cat >"${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${target}"
}

# human_bytes <n>
human_bytes() {
  local b="${1:-0}"
  if   [ "${b}" -ge 1099511627776 ] 2>/dev/null; then awk -v b="${b}" 'BEGIN{printf "%.2f TiB", b/1099511627776}'
  elif [ "${b}" -ge 1073741824 ]    2>/dev/null; then awk -v b="${b}" 'BEGIN{printf "%.2f GiB", b/1073741824}'
  elif [ "${b}" -ge 1048576 ]       2>/dev/null; then awk -v b="${b}" 'BEGIN{printf "%.2f MiB", b/1048576}'
  elif [ "${b}" -ge 1024 ]          2>/dev/null; then awk -v b="${b}" 'BEGIN{printf "%.2f KiB", b/1024}'
  else printf '%s B' "${b}"; fi
}

# human_duration <seconds>
human_duration() {
  local s="${1:-0}"
  printf '%dh %02dm %02ds' $(( s / 3600 )) $(( (s % 3600) / 60 )) $(( s % 60 ))
}

# worst_rc <a> <b> - fold two exit codes, keeping the more severe.
# Severity is NOT numeric order: 3 (partial) is less severe than 1 (fatal), so a
# run that produced a degraded snapshot never reports worse than one that
# produced none at all.
worst_rc() {
  local a="${1:-0}" b="${2:-0}"
  local -a rank=()
  rank[0]=0; rank[3]=1; rank[8]=2; rank[7]=3; rank[9]=3
  rank[5]=4; rank[6]=5; rank[4]=6; rank[2]=6; rank[1]=7; rank[130]=8
  local ra="${rank[a]:-7}" rb="${rank[b]:-7}"
  if [ "${ra}" -ge "${rb}" ]; then printf '%s' "${a}"; else printf '%s' "${b}"; fi
}

# lib_source <name> - source a sibling module from lib/ exactly once.
lib_source() {
  local name="$1"
  # A missing module is a broken installation, not a missing feature. Left to
  # bash it surfaces as a bare "lib/x.sh: No such file or directory" attributed
  # to core.sh, with no mention of which command died or that it died at all -
  # which is how a dispatcher entry referencing a module that was never written
  # went unnoticed until an end-to-end run.
  [ -r "${BGB_LIB_DIR}/${name}" ] || die "${EX_PRECOND}" \
    "Installation incomplete: ${BGB_LIB_DIR}/${name} is missing (command: ${BGB_COMMAND:-?})"
  # shellcheck source=/dev/null
  . "${BGB_LIB_DIR}/${name}"
}
