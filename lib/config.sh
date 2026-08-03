#!/usr/bin/env bash
# =============================================================================
# bg-backup - config: lint first, source second
# =============================================================================
# Configuration is shell-sourced KEY=VALUE plus bash arrays. That buys exact
# argv construction for restic (the only safe way to carry paths containing
# spaces) and zero parser dependencies in the disaster-recovery path, where a
# missing `yq` would be a genuinely bad thing to discover.
#
# The cost is that sourcing a file is executing it as root. Three controls make
# that acceptable, and all three run BEFORE the file is sourced:
#
#   1. ownership and mode gate  - root-owned, not group/world writable
#   2. key whitelist            - a typo like JOB_KEEP_DIALY is an error, not a
#                                 silently disabled retention policy
#   3. no command substitution  - $(...) and backticks are rejected outright
#
# =============================================================================

[ -n "${_BGB_CONFIG_SOURCED:-}" ] && return 0
_BGB_CONFIG_SOURCED=1

# -----------------------------------------------------------------------------
# The key whitelist
# -----------------------------------------------------------------------------
# This is an EXPLICIT list, not a prefix pattern, and that distinction is the
# whole point. A pattern like ^JOB_[A-Z0-9_]+$ accepts JOB_KEEP_DIALY, which is
# exactly the typo it was supposed to catch: the misspelled key is set, the real
# JOB_KEEP_DAILY stays at its default, and retention silently does something
# other than what the file says. Nothing errors, and nobody finds out until a
# snapshot they expected to still exist has been forgotten.
#
# Adding a setting therefore means adding it here too. That is deliberate
# friction on a file whose typos are silent.
readonly BGB_CONFIG_KEYS_GLOBAL="
BGB_HOSTNAME BGB_REPO_ENV BGB_REPO_ROLE BGB_SECONDARY_REPO_ENV
BGB_RESTIC_BIN BGB_RESTIC_MIN_VERSION BGB_COMPRESSION BGB_PACK_SIZE_MIB
BGB_READ_CONCURRENCY BGB_LIMIT_UPLOAD_KIB BGB_LIMIT_DOWNLOAD_KIB
BGB_CACHE_DIR BGB_TMP_DIR BGB_STATE_DIR BGB_LOG_DIR BGB_LOCK_ROOT BGB_RUNTIME_DIR
BGB_LOG_LEVEL BGB_UMASK BGB_LOCK_WAIT_SECONDS BGB_PARALLEL_JOBS
BGB_NICE BGB_IONICE_CLASS BGB_IONICE_LEVEL
BGB_RETRY_ATTEMPTS BGB_RETRY_DELAY_SECONDS
BGB_DEFAULT_KEEP_LAST BGB_DEFAULT_KEEP_DAILY BGB_DEFAULT_KEEP_WEEKLY
BGB_DEFAULT_KEEP_MONTHLY BGB_DEFAULT_KEEP_YEARLY BGB_DEFAULT_KEEP_WITHIN
BGB_KEEP_TAG BGB_FORGET_MIN_SNAPSHOTS BGB_FORGET_MAX_DELETE_PERCENT
BGB_PRUNE_MAX_UNUSED
BGB_DEFAULT_EXCLUDE_FILE BGB_DEFAULT_EXCLUDE_CACHES BGB_DEFAULT_ONE_FILE_SYSTEM
BGB_DEFAULT_ALERT_MAX_AGE_HOURS
BGB_MONITOR_ON BGB_NOTIFIERS BGB_MONITOR_TIMEOUT_SECONDS
BGB_MONITOR_KUMA_PUSH_URL BGB_MONITOR_KUMA_MAINTENANCE BGB_MONITOR_KUMA_API_URL
BGB_MONITOR_KUMA_MAINTENANCE_ID
BGB_MONITOR_MAIL_TO BGB_MONITOR_MAIL_FROM BGB_MONITOR_TEAMS_WEBHOOK_URL
BGB_MONITOR_WEBHOOK_URL BGB_METRICS_TEXTFILE BGB_NOTIFY_INCLUDE_PATHS
BGB_MONITOR_HEALTHCHECKS_BASE
BGB_CHECK_SCHEDULE BGB_CHECK_READ_DATA_SUBSET BGB_PRUNE_SCHEDULE
BGB_VERIFY_SCHEDULE BGB_COPY_SCHEDULE BGB_MAINT_RANDOM_DELAY
BGB_ESCROW_URLS BGB_ESCROW_LOCAL BGB_ESCROW_RECIPIENTS_FILE BGB_ESCROW_MAX_AGE_DAYS
BGB_UPDATE_CHANNEL BGB_UPDATE_SCHEDULE
"

readonly BGB_CONFIG_KEYS_JOB="
JOB_ENABLED JOB_DESCRIPTION JOB_MODE
JOB_PATHS JOB_EXTRA_PATHS JOB_ONE_FILE_SYSTEM
JOB_EXCLUDE_FILE JOB_EXCLUDES JOB_EXCLUDE_CACHES JOB_EXCLUDE_LARGER_THAN
JOB_EXCLUDE_IF_PRESENT
JOB_QUIESCE JOB_QUIESCE_UNITS JOB_QUIESCE_SCOPE JOB_QUIESCE_MAX_SECONDS
JOB_SNAPSHOT_SIZE
JOB_TAGS JOB_SCHEDULE JOB_RANDOM_DELAY JOB_TIMEOUT JOB_PRIORITY
JOB_KEEP_LAST JOB_KEEP_DAILY JOB_KEEP_WEEKLY JOB_KEEP_MONTHLY JOB_KEEP_YEARLY
JOB_KEEP_WITHIN JOB_FORGET_AFTER_BACKUP JOB_PRUNE_AFTER_BACKUP
JOB_PRE_HOOKS JOB_POST_HOOKS JOB_HOOK_FAILURE
JOB_ALERT_MAX_AGE_HOURS JOB_PARTIAL_IS_FAILURE
JOB_COPY_TO_SECONDARY JOB_VERIFY_SAMPLE
JOB_DOCKER_DISCOVER JOB_DOCKER_PROJECTS JOB_DOCKER_EXCLUDE_PROJECTS
JOB_DOCKER_INCLUDE_COMPOSE_FILES JOB_DOCKER_INCLUDE_ENV_FILES
JOB_DOCKER_INCLUDE_NAMED_VOLUMES JOB_DOCKER_INCLUDE_BIND_MOUNTS
JOB_DOCKER_IMAGE_MANIFEST JOB_DOCKER_NETWORK_MANIFEST JOB_DOCKER_EXPORT_IMAGES
JOB_DOCKER_INCLUDE_OVERLAY2 JOB_DOCKER_EXTRA_PATHS
JOB_DB_DUMP JOB_DB_ENGINES JOB_DB_EXCLUDE_CONTAINERS JOB_DB_DUMP_TIMEOUT
JOB_DB_DUMP_COMPRESS JOB_DB_RECORD_COUNTS
JOB_CONFIG_PATHS JOB_STDIN_COMMAND JOB_STDIN_FILENAME
"

# Backend credential variables are matched by PREFIX on purpose: restic and the
# cloud SDKs own those namespaces, and enumerating every provider's variables
# here would break the day restic supports a new backend.
readonly BGB_CONFIG_KEY_PREFIX_RE='^(RESTIC_[A-Z0-9_]+|AWS_[A-Z0-9_]+|B2_[A-Z0-9_]+|AZURE_[A-Z0-9_]+|GOOGLE_[A-Z0-9_]+|GS_[A-Z0-9_]+|OS_[A-Z0-9_]+|SWIFT_[A-Z0-9_]+|ST_[A-Z0-9_]+|RCLONE_[A-Z0-9_]+)$'

# config_key_known <key>
config_key_known() {
  local key="$1" k
  for k in ${BGB_CONFIG_KEYS_GLOBAL} ${BGB_CONFIG_KEYS_JOB}; do
    [ "${k}" = "${key}" ] && return 0
  done
  [[ "${key}" =~ ${BGB_CONFIG_KEY_PREFIX_RE} ]] && return 0
  return 1
}

# config_key_suggest <key> - the nearest known key, for the error message.
# A bare "unknown key" makes an operator re-read the whole reference; "did you
# mean JOB_KEEP_DAILY?" ends it immediately.
config_key_suggest() {
  local key="$1" k best="" best_score=0 score
  local prefix="${key%%_*}"
  for k in ${BGB_CONFIG_KEYS_GLOBAL} ${BGB_CONFIG_KEYS_JOB}; do
    case "${k}" in "${prefix}"_*) ;; *) continue ;; esac
    # Cheap similarity: shared leading characters. Enough to catch a
    # transposition or a single wrong letter, which is what typos actually are.
    score=0
    local i n
    n="${#key}"
    [ "${#k}" -lt "${n}" ] && n="${#k}"
    for ((i = 0; i < n; i++)); do
      [ "${key:i:1}" = "${k:i:1}" ] || break
      score=$((score + 1))
    done
    if [ "${score}" -gt "${best_score}" ]; then
      best_score="${score}"
      best="${k}"
    fi
  done
  [ "${best_score}" -ge 4 ] && printf '%s' "${best}"

  # No near match is the ORDINARY case, not an error - and the caller assigns
  # this in `hint="$(config_key_suggest ...)"`, so returning 1 would abort the
  # linter under `set -e` at exactly the moment it had something to report. The
  # unknown key would then never be printed. Same shape as the bug that killed
  # restore_parse_common(); see tests/unit/regressions.bats.
  return 0
}

# -----------------------------------------------------------------------------
# Gates
# -----------------------------------------------------------------------------

# config_require_perms <file> <max-octal-mode>
config_require_perms() {
  local f="$1" want="$2" mode uid
  [ -f "${f}" ] || die "${EX_PRECOND}" "Missing configuration file: ${f}"
  uid="$(stat -c '%u' "${f}")"
  mode="$(stat -c '%a' "${f}")"

  [ "${uid}" = "0" ] || die "${EX_PRECOND}" "${f}: must be owned by root (currently uid ${uid})"

  # Refuse anything more permissive than the maximum. A warning here gets
  # ignored; a refusal gets fixed.
  if [ $((8#${mode} & ~8#${want})) -ne 0 ]; then
    err "${f}: mode ${mode} is more permissive than ${want}"
    die "${EX_PRECOND}" "Fix it with: chmod ${want} ${f}"
  fi
}

# _config_strip_comment <line> - drop a trailing # comment, quote-aware.
#
# Needed because the command-substitution check would otherwise fire on
# backticks inside an ordinary trailing comment:
#
#     JOB_VERIFY_SAMPLE=5   # files restored and hashed by `verify`
#
# which is a natural way to write a comment and has no security meaning. The
# shipped example configuration hit exactly this and was rejected by our own
# linter - a fresh install would have failed on it.
#
# Conservative by construction: if a quote is left open, the whole line is
# returned unchanged, so the caller inspects MORE text rather than less. A bad
# parse can only cause a false rejection, never a missed substitution.
_config_strip_comment() {
  local line="$1" out="" i c q=""
  for ((i = 0; i < ${#line}; i++)); do
    c="${line:i:1}"
    if [ -n "${q}" ]; then
      out+="${c}"
      [ "${c}" = "${q}" ] && q=""
      continue
    fi
    case "${c}" in
      "'" | '"')
        q="${c}"
        out+="${c}"
        ;;
      '#')
        printf '%s' "${out}"
        return 0
        ;;
      *) out+="${c}" ;;
    esac
  done
  # No comment found, or an unterminated quote: hand back everything.
  printf '%s' "${line}"
}

# config_lint <file> - validate WITHOUT executing.
config_lint() {
  local f="$1" line code key n=0 in_array=0
  [ -r "${f}" ] || die "${EX_PRECOND}" "Cannot read ${f}"

  while IFS= read -r line || [ -n "${line}" ]; do
    n=$((n + 1))

    # Inside a multi-line array we only look for the closing parenthesis.
    if [ "${in_array}" -eq 1 ]; then
      code="$(_config_strip_comment "${line}")"
      case "${code}" in
        *'$('* | *'`'*) die "${EX_PRECOND}" "${f}:${n}: command substitution is not allowed" ;;
      esac
      case "${line}" in *')'*) in_array=0 ;; esac
      continue
    fi

    # Blank and comment lines.
    case "${line}" in
      '' | [[:space:]]*'#'* | '#'*) continue ;;
    esac
    [ -z "${line//[[:space:]]/}" ] && continue

    if [[ ! "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      die "${EX_PRECOND}" "${f}:${n}: not a KEY=VALUE assignment: ${line}"
    fi
    key="${BASH_REMATCH[2]}"

    if ! config_key_known "${key}"; then
      err "${f}:${n}: unknown configuration key '${key}'"
      local hint
      hint="$(config_key_suggest "${key}")"
      [ -n "${hint}" ] && err "  did you mean '${hint}'?"
      die "${EX_PRECOND}" "See docs/configuration.md for the full key list."
    fi

    code="$(_config_strip_comment "${line}")"
    case "${code}" in
      *'$('* | *'`'*)
        die "${EX_PRECOND}" "${f}:${n}: command substitution is not allowed in configuration"
        ;;
    esac

    # Detect the start of a multi-line array: KEY=( ... without a closing ).
    case "${code}" in
      *'=('*)
        case "${code}" in *')'*) : ;; *) in_array=1 ;; esac
        ;;
    esac
  done <"${f}"

  [ "${in_array}" -eq 0 ] || die "${EX_PRECOND}" "${f}: unterminated array assignment"
  return 0
}

# config_source_checked <file> <max-mode>
config_source_checked() {
  local f="$1" mode="${2:-0640}"
  config_require_perms "${f}" "${mode}"
  config_lint "${f}"
  # shellcheck source=/dev/null
  . "${f}"
}

# -----------------------------------------------------------------------------
# Main configuration
# -----------------------------------------------------------------------------
BGB_CONFIG_LOADED=0

config_load() {
  local f="${BGB_CONFIG_FILE:-${BGB_CONFDIR}/bg-backup.conf}"
  [ "${BGB_CONFIG_LOADED}" = "1" ] && return 0

  config_defaults

  if [ -f "${f}" ]; then
    config_source_checked "${f}" 0640
    BGB_MAIN_CONFIG="${f}"
  else
    debug "No main configuration at ${f} - using built-in defaults"
    BGB_MAIN_CONFIG=""
  fi

  [ -z "${BGB_HOSTNAME}" ] && BGB_HOSTNAME="$(fqdn)"
  umask "${BGB_UMASK}"
  BGB_CONFIG_LOADED=1
}

# Built-in defaults. Kept in code, not only in the example file, so a host with
# a minimal hand-written config still behaves predictably.
config_defaults() {
  : "${BGB_HOSTNAME:=}"
  : "${BGB_REPO_ENV:=${BGB_CONFDIR}/credentials/repo.env}"
  : "${BGB_REPO_ROLE:=primary}"
  : "${BGB_SECONDARY_REPO_ENV:=}"

  : "${BGB_RESTIC_BIN:=/usr/local/bin/restic}"
  : "${BGB_RESTIC_MIN_VERSION:=0.17.0}"
  : "${BGB_COMPRESSION:=auto}"
  : "${BGB_PACK_SIZE_MIB:=}"
  : "${BGB_READ_CONCURRENCY:=}"
  : "${BGB_LIMIT_UPLOAD_KIB:=0}"
  : "${BGB_LIMIT_DOWNLOAD_KIB:=0}"

  : "${BGB_CACHE_DIR:=/var/lib/bg-backup/cache}"
  : "${BGB_TMP_DIR:=/var/lib/bg-backup/tmp}"
  : "${BGB_STATE_DIR:=/var/lib/bg-backup/state}"
  : "${BGB_LOG_DIR:=/var/log/bg-backup}"

  : "${BGB_UMASK:=0077}"
  : "${BGB_LOCK_WAIT_SECONDS:=1800}"
  : "${BGB_PARALLEL_JOBS:=0}"
  : "${BGB_NICE:=10}"
  : "${BGB_IONICE_CLASS:=2}"
  : "${BGB_IONICE_LEVEL:=7}"
  : "${BGB_RETRY_ATTEMPTS:=3}"
  : "${BGB_RETRY_DELAY_SECONDS:=60}"

  : "${BGB_DEFAULT_KEEP_LAST:=3}"
  : "${BGB_DEFAULT_KEEP_DAILY:=30}"
  : "${BGB_DEFAULT_KEEP_WEEKLY:=8}"
  : "${BGB_DEFAULT_KEEP_MONTHLY:=6}"
  : "${BGB_DEFAULT_KEEP_YEARLY:=0}"
  : "${BGB_DEFAULT_KEEP_WITHIN:=}"
  : "${BGB_KEEP_TAG:=keep-forever}"

  : "${BGB_FORGET_MIN_SNAPSHOTS:=5}"
  : "${BGB_FORGET_MAX_DELETE_PERCENT:=50}"
  : "${BGB_PRUNE_MAX_UNUSED:=5%}"

  : "${BGB_DEFAULT_EXCLUDE_FILE:=${BGB_CONFDIR}/excludes/system.exclude}"
  : "${BGB_DEFAULT_EXCLUDE_CACHES:=1}"
  : "${BGB_DEFAULT_ONE_FILE_SYSTEM:=1}"
  : "${BGB_DEFAULT_ALERT_MAX_AGE_HOURS:=30}"

  : "${BGB_MONITOR_ON:=failure}"
  : "${BGB_NOTIFIERS:=uptime-kuma prometheus email teams}"
  : "${BGB_MONITOR_TIMEOUT_SECONDS:=15}"
  : "${BGB_MONITOR_KUMA_PUSH_URL:=}"
  : "${BGB_MONITOR_KUMA_MAINTENANCE:=0}"
  : "${BGB_MONITOR_KUMA_API_URL:=}"
  : "${BGB_MONITOR_KUMA_MAINTENANCE_ID:=}"
  : "${BGB_MONITOR_MAIL_TO:=}"
  : "${BGB_MONITOR_MAIL_FROM:=}"
  : "${BGB_MONITOR_TEAMS_WEBHOOK_URL:=}"
  : "${BGB_MONITOR_WEBHOOK_URL:=}"
  : "${BGB_METRICS_TEXTFILE:=}"
  : "${BGB_NOTIFY_INCLUDE_PATHS:=0}"

  : "${BGB_CHECK_SCHEDULE:=Wed *-*-* 05:00:00}"
  : "${BGB_CHECK_READ_DATA_SUBSET:=2%}"
  : "${BGB_PRUNE_SCHEDULE:=Sun *-*-* 06:00:00}"
  : "${BGB_VERIFY_SCHEDULE:=*-*-01 07:00:00}"
  : "${BGB_COPY_SCHEDULE:=}"
  : "${BGB_MAINT_RANDOM_DELAY:=1800}"

  : "${BGB_ESCROW_URLS:=}"
  : "${BGB_ESCROW_LOCAL:=/var/lib/bg-backup/export/bg-backup-config.tar.age}"
  : "${BGB_ESCROW_RECIPIENTS_FILE:=${BGB_CONFDIR}/credentials/recovery-recipients.txt}"
  : "${BGB_ESCROW_MAX_AGE_DAYS:=90}"

  : "${BGB_UPDATE_CHANNEL:=stable}"
  : "${BGB_UPDATE_SCHEDULE:=}"
}

# -----------------------------------------------------------------------------
# Jobs
# -----------------------------------------------------------------------------

# config_list_jobs - names of every job defined in conf.d, sorted by file name
# so the numeric prefix controls execution order under `backup --all`.
config_list_jobs() {
  local f base
  [ -d "${BGB_CONFDIR}/conf.d" ] || return 0
  for f in "${BGB_CONFDIR}"/conf.d/*.conf; do
    [ -e "${f}" ] || continue
    base="$(basename "${f}" .conf)"
    printf '%s\n' "${base#[0-9][0-9]-}"
  done
}

# config_job_file <job> - resolve a job name to its file, with or without the
# numeric prefix.
config_job_file() {
  local job="$1" f
  for f in "${BGB_CONFDIR}"/conf.d/*.conf; do
    [ -e "${f}" ] || continue
    local base
    base="$(basename "${f}" .conf)"
    if [ "${base}" = "${job}" ] || [ "${base#[0-9][0-9]-}" = "${job}" ]; then
      printf '%s' "${f}"
      return 0
    fi
  done
  return 1
}

# job_defaults_reset - every JOB_* back to its inherited value. Called before
# each job is sourced so settings never leak between jobs in a --all run.
#
# Every variable here is consumed by a module that is sourced dynamically at
# dispatch time (backup.sh, docker.sh, retention.sh, ...), which ShellCheck
# cannot follow - so it reports all of them as unused. Disabled for this
# function only, deliberately, rather than globally: outside this block SC2034
# still catches a genuine typo.
# shellcheck disable=SC2034
job_defaults_reset() {
  JOB_ENABLED=1
  JOB_DESCRIPTION=""
  JOB_MODE="files"
  JOB_PATHS=()
  JOB_EXTRA_PATHS=()
  JOB_ONE_FILE_SYSTEM="${BGB_DEFAULT_ONE_FILE_SYSTEM:-1}"
  JOB_EXCLUDE_FILE="${BGB_DEFAULT_EXCLUDE_FILE:-}"
  JOB_EXCLUDES=()
  JOB_EXCLUDE_CACHES="${BGB_DEFAULT_EXCLUDE_CACHES:-1}"
  JOB_EXCLUDE_LARGER_THAN=""
  JOB_EXCLUDE_IF_PRESENT=""
  JOB_QUIESCE="none"
  JOB_QUIESCE_UNITS=()
  JOB_QUIESCE_SCOPE="project"
  JOB_QUIESCE_MAX_SECONDS=300
  JOB_SNAPSHOT_SIZE="10G"
  JOB_TAGS=()
  JOB_SCHEDULE=""
  JOB_RANDOM_DELAY="900"
  JOB_TIMEOUT="12h"
  JOB_PRIORITY="low"
  JOB_KEEP_LAST=""
  JOB_KEEP_DAILY=""
  JOB_KEEP_WEEKLY=""
  JOB_KEEP_MONTHLY=""
  JOB_KEEP_YEARLY=""
  JOB_KEEP_WITHIN=""
  JOB_FORGET_AFTER_BACKUP=1
  JOB_PRUNE_AFTER_BACKUP=0
  JOB_PRE_HOOKS=()
  JOB_POST_HOOKS=()
  JOB_HOOK_FAILURE="abort"
  JOB_ALERT_MAX_AGE_HOURS="${BGB_DEFAULT_ALERT_MAX_AGE_HOURS:-30}"
  JOB_PARTIAL_IS_FAILURE=0
  JOB_COPY_TO_SECONDARY=0
  JOB_VERIFY_SAMPLE=3

  # docker mode
  JOB_DOCKER_DISCOVER=1
  JOB_DOCKER_PROJECTS=()
  JOB_DOCKER_EXCLUDE_PROJECTS=()
  JOB_DOCKER_INCLUDE_COMPOSE_FILES=1
  JOB_DOCKER_INCLUDE_ENV_FILES=1
  JOB_DOCKER_INCLUDE_NAMED_VOLUMES=1
  JOB_DOCKER_INCLUDE_BIND_MOUNTS=1
  JOB_DOCKER_IMAGE_MANIFEST=1
  JOB_DOCKER_NETWORK_MANIFEST=1
  JOB_DOCKER_EXPORT_IMAGES="missing"
  JOB_DOCKER_INCLUDE_OVERLAY2=0
  JOB_DOCKER_EXTRA_PATHS=()
  JOB_DB_DUMP=1
  JOB_DB_ENGINES=(postgres mysql mariadb mongodb redis)
  JOB_DB_EXCLUDE_CONTAINERS=()
  JOB_DB_DUMP_TIMEOUT="3600"
  JOB_DB_DUMP_COMPRESS=0
  JOB_DB_RECORD_COUNTS=1

  # config mode
  # Defaulted rather than bare: this function must be callable before the
  # dispatcher has exported anything, or `set -u` turns a missing export into
  # "unbound variable" pointing at this file instead of at the real cause.
  JOB_CONFIG_PATHS=("${BGB_CONFDIR:-/etc/bg-backup}" "/var/lib/bg-backup/facts")
}

# config_load_job <job>
config_load_job() {
  local job="$1" f
  config_load
  f="$(config_job_file "${job}")" \
    || die "${EX_PRECOND}" "Unknown job: ${job} (see: bg-backup config show)"

  job_defaults_reset
  config_source_checked "${f}" 0640

  BGB_JOB="${job}"
  BGB_JOB_FILE="${f}"
  config_validate_job
}

# config_validate_job - semantic checks on the values themselves.
config_validate_job() {
  local p

  case "${JOB_MODE}" in
    files | docker | stdin | config) : ;;
    *) die "${EX_PRECOND}" "${BGB_JOB}: invalid JOB_MODE '${JOB_MODE}' (files|docker|stdin|config)" ;;
  esac

  case "${JOB_QUIESCE}" in
    none | docker-pause | docker-stop | service-stop | lvm | btrfs | zfs) : ;;
    *) die "${EX_PRECOND}" "${BGB_JOB}: invalid JOB_QUIESCE '${JOB_QUIESCE}'" ;;
  esac

  case "${JOB_PRIORITY}" in
    low | normal | high) : ;;
    *) die "${EX_PRECOND}" "${BGB_JOB}: invalid JOB_PRIORITY '${JOB_PRIORITY}' (low|normal|high)" ;;
  esac

  case "${JOB_HOOK_FAILURE}" in
    abort | warn) : ;;
    *) die "${EX_PRECOND}" "${BGB_JOB}: invalid JOB_HOOK_FAILURE '${JOB_HOOK_FAILURE}' (abort|warn)" ;;
  esac

  if [ "${JOB_MODE}" = "files" ] && [ "${#JOB_PATHS[@]}" -eq 0 ]; then
    die "${EX_PRECOND}" "${BGB_JOB}: JOB_MODE=files requires at least one JOB_PATHS entry"
  fi

  for p in "${JOB_PATHS[@]:-}" "${JOB_EXTRA_PATHS[@]:-}"; do
    [ -z "${p}" ] && continue
    case "${p}" in
      /*) ;;
      *) die "${EX_PRECOND}" "${BGB_JOB}: source paths must be absolute: ${p}" ;;
    esac
    # A missing path is a warning, not an error: a mount can legitimately appear
    # later, and refusing to start would turn a transient into an outage.
    [ -e "${p}" ] || warn "${BGB_JOB}: source path does not exist (yet): ${p}"
  done

  if [ -n "${JOB_EXCLUDE_FILE}" ] && [ ! -r "${JOB_EXCLUDE_FILE}" ]; then
    warn "${BGB_JOB}: exclude file not readable: ${JOB_EXCLUDE_FILE}"
  fi

  # Validate the calendar expression with systemd itself rather than a regex -
  # a schedule systemd rejects means the timer silently never fires.
  if [ -n "${JOB_SCHEDULE}" ] && have systemd-analyze; then
    systemd-analyze calendar "${JOB_SCHEDULE}" >/dev/null 2>&1 \
      || die "${EX_PRECOND}" "${BGB_JOB}: JOB_SCHEDULE is not a valid systemd OnCalendar expression: ${JOB_SCHEDULE}"
  fi
  if [ -n "${JOB_TIMEOUT}" ] && have systemd-analyze; then
    systemd-analyze timespan "${JOB_TIMEOUT}" >/dev/null 2>&1 \
      || die "${EX_PRECOND}" "${BGB_JOB}: JOB_TIMEOUT is not a valid systemd timespan: ${JOB_TIMEOUT}"
  fi

  local v
  for v in JOB_KEEP_LAST JOB_KEEP_DAILY JOB_KEEP_WEEKLY JOB_KEEP_MONTHLY JOB_KEEP_YEARLY; do
    local val="${!v}"
    [ -z "${val}" ] && continue
    case "${val}" in
      '' | *[!0-9]*) die "${EX_PRECOND}" "${BGB_JOB}: ${v} must be a number, got '${val}'" ;;
    esac
  done

  case "${JOB_QUIESCE}" in
    docker-pause | docker-stop)
      have docker || die "${EX_PRECOND}" "${BGB_JOB}: JOB_QUIESCE=${JOB_QUIESCE} but docker is not installed"
      ;;
    service-stop)
      [ "${#JOB_QUIESCE_UNITS[@]}" -gt 0 ] \
        || die "${EX_PRECOND}" "${BGB_JOB}: JOB_QUIESCE=service-stop requires JOB_QUIESCE_UNITS"
      ;;
    lvm)
      have lvcreate || die "${EX_PRECOND}" "${BGB_JOB}: JOB_QUIESCE=lvm requires lvm2"
      ;;
  esac

  local h
  for h in "${JOB_PRE_HOOKS[@]:-}" "${JOB_POST_HOOKS[@]:-}"; do
    [ -z "${h}" ] && continue
    [ -x "${h}" ] || warn "${BGB_JOB}: hook is not executable: ${h}"
  done
}

# job_retention_value <keep-name> - job value, else the global default.
job_retention_value() {
  local name="$1" jobvar defvar
  jobvar="JOB_KEEP_${name}"
  defvar="BGB_DEFAULT_KEEP_${name}"
  local v="${!jobvar:-}"
  [ -n "${v}" ] && {
    printf '%s' "${v}"
    return 0
  }
  printf '%s' "${!defvar:-}"
}

# -----------------------------------------------------------------------------
# Repository environment
# -----------------------------------------------------------------------------

# repo_env_load [env-file] - export restic's environment and register every
# credential for redaction. Everything that touches the repository calls this.
repo_env_load() {
  local f="${1:-${BGB_REPO_ENV}}"
  [ -f "${f}" ] || die "${EX_PRECOND}" "Repository environment not found: ${f} (run: bg-backup init)"

  # 0400 expected; 0600 tolerated because `config edit` and a few operators
  # legitimately leave it writable by root.
  config_require_perms "${f}" 0600
  config_lint "${f}"

  # Register the values for redaction BEFORE sourcing, so that even a failure
  # while sourcing cannot produce an unredacted error message.
  redact_register_file "${f}"

  # shellcheck source=/dev/null
  . "${f}"
  redact_register_env

  [ -n "${RESTIC_REPOSITORY:-}" ] || die "${EX_PRECOND}" "${f}: RESTIC_REPOSITORY is not set"

  if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
    [ -r "${RESTIC_PASSWORD_FILE}" ] \
      || die "${EX_PRECOND}" "Repository key file not readable: ${RESTIC_PASSWORD_FILE}"
    config_require_perms "${RESTIC_PASSWORD_FILE}" 0400
    redact_register "$(cat "${RESTIC_PASSWORD_FILE}")"
  elif [ -z "${RESTIC_PASSWORD:-}" ]; then
    die "${EX_PRECOND}" "${f}: neither RESTIC_PASSWORD_FILE nor RESTIC_PASSWORD is set"
  fi

  export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-${BGB_CACHE_DIR}}"
  BGB_REPO_LOADED=1
}

# notify_env_load - load notifier credentials (Kuma push token, Teams webhook,
# generic webhook token) and register them for redaction.
#
# Two sources, in order:
#   1. $CREDENTIALS_DIRECTORY/notify.env   - under systemd, via LoadCredential=
#   2. the file itself                     - a manual run, where there is no
#                                            credentials directory
#
# NOT an EnvironmentFile=. That would merge these values into the unit's
# environment block, which `systemctl show -p Environment` renders for any local
# user - a push token and a Teams webhook are credentials, and anyone holding
# the webhook can post as the bot. See docs/adr/0003.
#
# Missing is fine and silent: a host with no notifiers configured must still be
# able to run a backup.
_BGB_NOTIFY_ENV_LOADED=0
notify_env_load() {
  [ "${_BGB_NOTIFY_ENV_LOADED}" = "1" ] && return 0
  _BGB_NOTIFY_ENV_LOADED=1

  local f=""
  if [ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "${CREDENTIALS_DIRECTORY}/notify.env" ]; then
    f="${CREDENTIALS_DIRECTORY}/notify.env"
  elif [ -r "${BGB_CONFDIR}/credentials/notify.env" ]; then
    f="${BGB_CONFDIR}/credentials/notify.env"
  else
    return 0
  fi

  config_require_perms "${f}" 0600
  config_lint "${f}"
  redact_register_file "${f}"
  # shellcheck source=/dev/null
  . "${f}"
  debug "Loaded notifier credentials from ${f}"
  return 0
}

# repo_prefix - the trailing path component of the repository URL. Used as the
# non-secret `repo` label on metrics and as the doctor FQDN check.
repo_prefix() {
  local r="${RESTIC_REPOSITORY:-}"
  r="${r%/}"
  printf '%s' "${r##*/}"
}

# -----------------------------------------------------------------------------
# Command: config
# -----------------------------------------------------------------------------
cmd_config() {
  local sub="${1:-show}"
  shift || true
  case "${sub}" in
    show) config_cmd_show "$@" ;;
    validate) config_cmd_validate "$@" ;;
    edit) config_cmd_edit "$@" ;;
    export) secrets_cmd_export "$@" ;;
    import) secrets_cmd_import "$@" ;;
    *)
      err "Unknown subcommand: config ${sub}"
      usage_config
      exit "${EX_USAGE}"
      ;;
  esac
}

config_cmd_validate() {
  local strict=0 perms=1 rc=0 f job
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict)
        strict=1
        shift
        ;;
      # Lint a file that is NOT the live configuration: check its syntax and its
      # keys, but not its ownership and mode.
      #
      # The ownership gate exists because config files are SOURCED AS ROOT, so a
      # file anyone can edit is a root shell for anyone. That reasoning does not
      # apply to a candidate file in a working tree - and refusing it means the
      # shipped examples can never be linted anywhere except on a configured
      # host. CI checks out as uid 1001 and every run failed with
      #     bg-backup.conf.example: must be owned by root (currently uid 1001)
      # Never use this flag on ${BGB_CONFDIR}: there the gate is the point.
      --no-perm-check)
        perms=0
        shift
        ;;
      *) shift ;;
    esac
  done

  f="${BGB_CONFIG_FILE:-${BGB_CONFDIR}/bg-backup.conf}"
  if [ -f "${f}" ]; then
    if ({ [ "${perms}" -eq 0 ] || config_require_perms "${f}" 0640; } && config_lint "${f}") 2>/dev/null; then
      ok_mark "${f}"
    else
      [ "${perms}" -eq 1 ] && { config_require_perms "${f}" 0640 || rc=1; }
      config_lint "${f}" || rc=1
      bad_mark "${f}"
    fi
  else
    [ "${strict}" -eq 1 ] && {
      bad_mark "missing: ${f}"
      rc=1
    } || warn_mark "no main configuration at ${f}"
  fi

  while IFS= read -r job; do
    [ -n "${job}" ] || continue
    if (config_load_job "${job}") >/dev/null 2>&1; then
      ok_mark "job ${job}"
    else
      bad_mark "job ${job}"
      config_load_job "${job}" >/dev/null || true
      rc=1
    fi
  done < <(config_list_jobs)

  [ "${rc}" -eq 0 ] && log "Configuration is valid" || err "Configuration has errors"
  return $((rc == 0 ? 0 : EX_PRECOND))
}

config_cmd_show() {
  local resolved=0 reveal=0 job=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --resolved)
        resolved=1
        shift
        ;;
      --reveal)
        reveal=1
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
      *) shift ;;
    esac
  done
  [ -z "${job}" ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ] && job="${BGB_JOB_FILTER[0]}"

  config_load
  [ -n "${job}" ] && config_load_job "${job}"

  # --reveal only outside a pipe: a transcript of `config show --reveal` in a
  # CI log or a pasted terminal session is exactly how credentials escape.
  if [ "${reveal}" = "1" ] && [ ! -t 1 ]; then
    die "${EX_PRECOND}" "--reveal requires a terminal (refusing to print secrets into a pipe)"
  fi

  if [ "${BGB_JSON}" = "1" ]; then
    local jobs_json="[]" j first=1
    jobs_json="["
    while IFS= read -r j; do
      [ -n "${j}" ] || continue
      [ "${first}" -eq 0 ] && jobs_json+=","
      jobs_json+="$(json_str "${j}")"
      first=0
    done < <(config_list_jobs)
    jobs_json+="]"
    json_envelope ok "$(
      json_kv config_dir "${BGB_CONFDIR}"
      printf ','
      json_kv main_config "${BGB_MAIN_CONFIG:-}"
      printf ','
      json_kv hostname "${BGB_HOSTNAME}"
      printf ','
      json_kv repo_role "${BGB_REPO_ROLE}"
      printf ','
      json_kvraw jobs "${jobs_json}"
    )"
    return 0
  fi

  printf '%sConfiguration%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  config dir   %s\n' "${BGB_CONFDIR}"
  printf '  main config  %s\n' "${BGB_MAIN_CONFIG:-<none, using defaults>}"
  printf '  hostname     %s\n' "${BGB_HOSTNAME}"
  printf '  repo role    %s\n' "${BGB_REPO_ROLE}"
  printf '  jobs         %s\n' "$(config_list_jobs | tr '\n' ' ')"

  if [ -n "${job}" ]; then
    printf '\n%sJob: %s%s\n' "${C_BOLD}" "${job}" "${C_RESET}"
    printf '  file         %s\n' "${BGB_JOB_FILE}"
    printf '  description  %s\n' "${JOB_DESCRIPTION}"
    printf '  mode         %s\n' "${JOB_MODE}"
    printf '  enabled      %s\n' "${JOB_ENABLED}"
    printf '  paths        %s\n' "${JOB_PATHS[*]:-}"
    printf '  extra paths  %s\n' "${JOB_EXTRA_PATHS[*]:-<none>}"
    printf '  quiesce      %s\n' "${JOB_QUIESCE}"
    printf '  schedule     %s\n' "${JOB_SCHEDULE:-<none>}"
    printf '  tags         %s\n' "${JOB_TAGS[*]:-<none>}"
    if [ "${resolved}" = "1" ]; then
      printf '  retention    last=%s daily=%s weekly=%s monthly=%s yearly=%s within=%s\n' \
        "$(job_retention_value LAST)" "$(job_retention_value DAILY)" \
        "$(job_retention_value WEEKLY)" "$(job_retention_value MONTHLY)" \
        "$(job_retention_value YEARLY)" "${JOB_KEEP_WITHIN:-${BGB_DEFAULT_KEEP_WITHIN}}"
      printf '  partial=fail %s\n' "${JOB_PARTIAL_IS_FAILURE}"
      printf '  sla hours    %s\n' "${JOB_ALERT_MAX_AGE_HOURS}"
    fi
  fi
}

config_cmd_edit() {
  local job="" target tmp
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
      *) shift ;;
    esac
  done
  require_root
  config_load

  if [ -n "${job}" ]; then
    target="$(config_job_file "${job}")" || die "${EX_PRECOND}" "Unknown job: ${job}"
  else
    target="${BGB_CONFDIR}/bg-backup.conf"
  fi

  tmp="$(tmp_file "edit.XXXXXX")"
  cp "${target}" "${tmp}"
  "${EDITOR:-vi}" "${tmp}"

  # Validate the candidate before it is installed. An invalid file in place
  # means every subsequent run refuses to start, including the one that would
  # have told you why.
  if ! (config_lint "${tmp}"); then
    err "Not installing: the edited file did not validate"
    err "Your edit is preserved at ${tmp}"
    return "${EX_PRECOND}"
  fi

  install -o root -g root -m 0640 "${tmp}" "${target}"
  log "Updated ${target}"

  if have systemctl; then
    lib_source systemd.sh
    systemd_sync || warn "schedule sync failed - run: bg-backup schedule sync"
  fi
  log "Remember: run 'bg-backup config export' so the recovery bundle matches."
}
