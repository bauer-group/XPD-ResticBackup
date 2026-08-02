#!/usr/bin/env bash
# =============================================================================
# bg-backup - restic-based backup and disaster recovery for Ubuntu servers
# =============================================================================
# BAUER GROUP | https://github.com/bauer-group/XPD-ResticBackup
#
# Installed as /usr/local/sbin/bg-backup -> /opt/bg-backup/current/bin/bg-backup.sh
#
# The file keeps its .sh suffix on disk because the shared ShellCheck workflow
# only globs *.sh; the operator-facing name is the symlink.
# =============================================================================

set -euo pipefail
# inherit_errexit makes `local x; x=$(failing)` propagate inside command
# substitution in a subshell. Available since bash 4.4, so safe on 22.04 (5.1).
shopt -s inherit_errexit 2>/dev/null || true

# -----------------------------------------------------------------------------
# Locate the installation
# -----------------------------------------------------------------------------
_bgb_resolve_self() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "${src}" ]; do
    dir="$(cd -P "$(dirname "${src}")" && pwd)"
    src="$(readlink "${src}")"
    [[ "${src}" != /* ]] && src="${dir}/${src}"
  done
  cd -P "$(dirname "${src}")" && pwd
}

BGB_BIN_DIR="$(_bgb_resolve_self)"
BGB_ROOT="$(cd "${BGB_BIN_DIR}/.." && pwd)"
BGB_LIB_DIR="${BGB_ROOT}/lib"
BGB_SHARE_DIR="${BGB_ROOT}/share"
export BGB_ROOT BGB_LIB_DIR BGB_SHARE_DIR

BGB_VERSION="$(cat "${BGB_ROOT}/VERSION" 2>/dev/null || echo "0.0.0-dev")"
export BGB_VERSION

# Configuration root. Overridable for tests and for `--config`.
: "${BGB_CONFDIR:=/etc/bg-backup}"
: "${BGB_STATE_DIR:=/var/lib/bg-backup/state}"
export BGB_CONFDIR BGB_STATE_DIR

# -----------------------------------------------------------------------------
# Core modules (always loaded; everything else is lazy)
# -----------------------------------------------------------------------------
# shellcheck source=../lib/core.sh
. "${BGB_LIB_DIR}/core.sh"
# shellcheck source=../lib/redact.sh
. "${BGB_LIB_DIR}/redact.sh"
# shellcheck source=../lib/json.sh
. "${BGB_LIB_DIR}/json.sh"
# shellcheck source=../lib/usage.sh
. "${BGB_LIB_DIR}/usage.sh"

# -----------------------------------------------------------------------------
# Global flag parsing
# -----------------------------------------------------------------------------
# Manual while/case, no getopts - house convention, and getopts cannot handle the
# long flags this CLI needs. Global flags are accepted both before and after the
# command name, because operators type them both ways under pressure.
BGB_CONFIG_FILE=""
BGB_LOCK_WAIT=""
BGB_NO_LOCK=0
BGB_JOB_FILTER=()
_BGB_ARGS=()

# Sets _BGB_CONSUMED to the number of argv entries the flag used, 0 if the flag
# is not a global one.
#
# The result is deliberately NOT echoed and captured with $(...): command
# substitution runs in a subshell, so every assignment below would be made in a
# child process and silently discarded. That bug presents as "--json is
# accepted but ignored", which is tedious to track down precisely because the
# flag parses without error.
_BGB_CONSUMED=0
# BGB_LOCK_WAIT and BGB_NO_LOCK are read by lib/lock.sh, which is sourced at
# dispatch time and therefore invisible to the linter here.
# shellcheck disable=SC2034
_bgb_parse_global() {
  _BGB_CONSUMED=1
  case "$1" in
    --config)      _bgb_need_arg "$@"; BGB_CONFIG_FILE="$2"; _BGB_CONSUMED=2 ;;
    --config=*)    BGB_CONFIG_FILE="${1#*=}" ;;
    --job)         _bgb_need_arg "$@"; BGB_JOB_FILTER+=("$2"); _BGB_CONSUMED=2 ;;
    --job=*)       BGB_JOB_FILTER+=("${1#*=}") ;;
    --json)        BGB_JSON=1 ;;
    --quiet|-q)    BGB_QUIET=1 ;;
    --verbose|-v)  BGB_LOG_LEVEL="debug" ;;
    --dry-run|-n)  BGB_DRY_RUN=1 ;;
    --yes|-y)      BGB_YES=1 ;;
    --no-color)    BGB_COLOR="never"; _bgb_init_colour ;;
    --color=*)     BGB_COLOR="${1#*=}"; _bgb_init_colour ;;
    --lock-wait)   _bgb_need_arg "$@"; BGB_LOCK_WAIT="$2"; _BGB_CONSUMED=2 ;;
    --lock-wait=*) BGB_LOCK_WAIT="${1#*=}" ;;
    --no-lock)     BGB_NO_LOCK=1 ;;
    *)             _BGB_CONSUMED=0 ;;
  esac
}

_bgb_need_arg() {
  [ $# -ge 2 ] && [ -n "${2:-}" ] || die "${EX_USAGE}" "Flag $1 requires an argument"
}

main() {
  local cmd="" arg

  # Pass 1: global flags up to the command word.
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        printf 'bg-backup %s\n' "${BGB_VERSION}"; exit "${EX_OK}" ;;
      --help|-h)
        usage_main; exit "${EX_OK}" ;;
      --) shift; break ;;
      -*)
        _bgb_parse_global "$@"
        if [ "${_BGB_CONSUMED}" -eq 0 ]; then
          err "Unknown global flag: $1"
          usage_main
          exit "${EX_USAGE}"
        fi
        shift "${_BGB_CONSUMED}"
        ;;
      *)
        cmd="$1"; shift; break ;;
    esac
  done

  # Pass 2: keep global flags working after the command word too. Anything not
  # recognised here is passed through to the command's own parser.
  while [ $# -gt 0 ]; do
    arg="$1"
    case "${arg}" in
      --help|-h) usage_for "${cmd}"; exit "${EX_OK}" ;;
      -*)
        _bgb_parse_global "$@"
        if [ "${_BGB_CONSUMED}" -eq 0 ]; then
          _BGB_ARGS+=("${arg}"); shift
        else
          shift "${_BGB_CONSUMED}"
        fi
        ;;
      *) _BGB_ARGS+=("${arg}"); shift ;;
    esac
  done

  [ -z "${cmd}" ] && { usage_main; exit "${EX_USAGE}"; }

  BGB_COMMAND="${cmd}"
  export BGB_COMMAND
  install_traps
  umask 0077

  # `--config` may point at a whole config root or at the main file.
  if [ -n "${BGB_CONFIG_FILE}" ] && [ -d "${BGB_CONFIG_FILE}" ]; then
    BGB_CONFDIR="${BGB_CONFIG_FILE}"
    BGB_CONFIG_FILE="${BGB_CONFDIR}/bg-backup.conf"
  fi

  dispatch "${cmd}" "${_BGB_ARGS[@]:-}"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
# Modules are sourced on demand. `bg-backup --help` and `bg-backup version` must
# stay instant and must not require a readable /etc/bg-backup.
dispatch() {
  local cmd="$1"; shift
  local -a args=()
  local a
  # Drop the empty placeholder produced by "${_BGB_ARGS[@]:-}" when no arguments
  # were given (bash 5.1 has no cleaner way to expand a possibly-unset array).
  # Written as if/then rather than `[ -n "$a" ] && args+=(...)`: under `set -e`
  # the && form makes the whole for loop exit non-zero when the last element is
  # empty, which would abort the dispatcher before it ran anything.
  for a in "$@"; do
    if [ -n "${a}" ]; then args+=("${a}"); fi
  done

  case "${cmd}" in
    version)
      cmd_version "${args[@]:-}" ;;
    help)
      usage_for "${args[0]:-}" ;;
    completion)
      cmd_completion "${args[@]:-}" ;;

    init|discover|doctor)
      lib_source config.sh; lib_source restic.sh
      lib_source "${cmd}.sh"; "cmd_${cmd}" "${args[@]:-}" ;;

    backup)
      lib_source config.sh; lib_source lock.sh; lib_source restic.sh
      lib_source state.sh; lib_source quiesce.sh; lib_source metrics.sh
      lib_source monitor.sh; lib_source retention.sh; lib_source backup.sh
      cmd_backup "${args[@]:-}" ;;

    restore|dump)
      lib_source config.sh; lib_source restic.sh; lib_source restore.sh
      "cmd_${cmd}" "${args[@]:-}" ;;

    snapshots|ls|find|diff|mount|stats|unlock|runs)
      lib_source config.sh; lib_source restic.sh; lib_source query.sh
      "cmd_${cmd}" "${args[@]:-}" ;;

    check|verify)
      lib_source config.sh; lib_source restic.sh; lib_source state.sh
      lib_source metrics.sh; lib_source monitor.sh; lib_source verify.sh
      "cmd_${cmd}" "${args[@]:-}" ;;

    forget|prune|copy)
      lib_source config.sh; lib_source lock.sh; lib_source restic.sh
      lib_source state.sh; lib_source retention.sh
      "cmd_${cmd}" "${args[@]:-}" ;;

    status|logs)
      lib_source config.sh; lib_source state.sh; lib_source status.sh
      "cmd_${cmd}" "${args[@]:-}" ;;

    schedule)
      lib_source config.sh; lib_source systemd.sh
      cmd_schedule "${args[@]:-}" ;;

    config|secrets)
      lib_source config.sh; lib_source restic.sh; lib_source secrets.sh
      "cmd_${cmd}" "${args[@]:-}" ;;

    dr)
      lib_source config.sh; lib_source restic.sh; lib_source facts.sh
      lib_source restore.sh; lib_source secrets.sh; lib_source dr.sh
      cmd_dr "${args[@]:-}" ;;

    self-update|uninstall)
      lib_source config.sh; lib_source systemd.sh; lib_source selfupdate.sh
      "cmd_${cmd//-/_}" "${args[@]:-}" ;;

    internal)
      # Not documented for humans. Entry point for systemd ExecStopPost= and
      # OnFailure= units, which must work even when the main process was killed.
      lib_source config.sh; lib_source state.sh; lib_source quiesce.sh
      lib_source monitor.sh; lib_source internal.sh
      cmd_internal "${args[@]:-}" ;;

    *)
      err "Unknown command: ${cmd}"
      usage_main
      exit "${EX_USAGE}" ;;
  esac
}

# -----------------------------------------------------------------------------
# Built-in commands that need no module
# -----------------------------------------------------------------------------
cmd_version() {
  local restic_ver="not installed"
  if have restic; then
    restic_ver="$(restic version 2>/dev/null | awk '{print $2; exit}')"
  fi

  if [ "${BGB_JSON}" = "1" ]; then
    json_envelope ok "$(
      json_kv version "${BGB_VERSION}"; printf ','
      json_kv restic_version "${restic_ver}"; printf ','
      json_kv config_dir "${BGB_CONFDIR}"; printf ','
      json_kvraw json_schema "${BGB_JSON_SCHEMA}"
    )"
    return 0
  fi

  printf 'bg-backup   %s\n' "${BGB_VERSION}"
  printf 'restic      %s\n' "${restic_ver}"
  printf 'install     %s\n' "${BGB_ROOT}"
  printf 'config      %s\n' "${BGB_CONFDIR}"
  printf 'json schema %s\n' "${BGB_JSON_SCHEMA}"
}

cmd_completion() {
  local shell="${1:-bash}"
  case "${shell}" in
    bash)
      local f="${BGB_SHARE_DIR}/completion/bg-backup.bash"
      [ -r "${f}" ] || die "${EX_PRECOND}" "Completion script not found: ${f}"
      cat "${f}" ;;
    *)
      die "${EX_USAGE}" "Unsupported shell for completion: ${shell} (only bash)" ;;
  esac
}

main "$@"
