#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: Redis, Valkey and KeyDB
# =============================================================================
# BGSAVE, wait for it to actually finish, then stream the resulting RDB file.
#
# WHY THE WAIT IS NOT OPTIONAL, AND WHY "not in progress" IS NOT ENOUGH.
#
#   BGSAVE returns immediately: it forks a child and answers "Background saving
#   started". Copying dump.rdb straight afterwards copies the PREVIOUS save -
#   possibly hours old, possibly from before the incident you are backing up
#   against - and nothing about the file says so. The backup looks perfect.
#
#   Polling only rdb_bgsave_in_progress until it reads 0 is still wrong twice
#   over: it reads 0 in the instant before the fork has been counted, and it
#   also reads 0 after a save that FAILED (out of memory is the usual cause,
#   because the fork needs headroom for copy-on-write). Both leave the stale
#   file in place.
#
#   The only reliable completion signal is the triple: bgsave no longer in
#   progress, AND rdb_last_save_time strictly greater than the value captured
#   before BGSAVE was issued, AND rdb_last_bgsave_status = ok.
#
# WHY A PURE CACHE IS SKIPPED RATHER THAN BACKED UP.
#
#   An instance with no `save` points and appendonly no is, by its operator's
#   explicit configuration, a cache. Forcing a BGSAVE on it writes a file that
#   nothing will ever restore, doubles its resident memory for the duration of
#   the fork, and adds a meaningless artefact to the repository that will be
#   dutifully retained for months. bg-backup logs why it skipped and moves on.
#
# WHY THE AOF CHANGES THE RESTORE, NOT THE BACKUP.
#
#   When appendonly yes, Redis loads the AOF at startup and IGNORES dump.rdb
#   entirely. The RDB is still a complete, valid snapshot - but dropping it into
#   place and restarting appears to do nothing at all. db_redis_restore handles
#   this explicitly; db_redis_notes says it out loud.
# =============================================================================

[ -n "${_BGB_DB_REDIS_SOURCED:-}" ] && return 0
_BGB_DB_REDIS_SOURCED=1

db_redis_aliases() { printf 'valkey\nkeydb\n'; }

# -----------------------------------------------------------------------------
# Container scripts
# -----------------------------------------------------------------------------
# REDISCLI_AUTH keeps the password out of argv (redis-cli 6+, valkey-cli and
# keydb-cli all honour it). `redis-cli -a <pw>` would put it in
# /proc/<pid>/cmdline and print a warning into the middle of the output we are
# parsing.

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_RD_CLI_SH <<'EOS' || true
set -e
if   command -v redis-cli  >/dev/null 2>&1; then CLI=redis-cli
elif command -v valkey-cli >/dev/null 2>&1; then CLI=valkey-cli
elif command -v keydb-cli  >/dev/null 2>&1; then CLI=keydb-cli
else
  echo "bg-backup: no redis-cli/valkey-cli/keydb-cli inside the container" >&2
  exit 127
fi
pw="${REDIS_PASSWORD:-${REDISCLI_AUTH:-${VALKEY_PASSWORD:-${KEYDB_PASSWORD:-}}}}"
if [ -n "$pw" ]; then REDISCLI_AUTH="$pw"; export REDISCLI_AUTH; fi
exec "$CLI" "$@"
EOS

# _db_redis_cli <container> <redis-cli args...>
_db_redis_cli() {
  local c="$1"
  shift
  docker exec -i "${c}" sh -c "${_DB_RD_CLI_SH}" _ "$@" 2>/dev/null
}

# _db_redis_config <container> <parameter> - the value half of CONFIG GET.
# CONFIG GET replies with two lines (name, value); an empty reply means the
# command was renamed away or the parameter does not exist on this build.
_db_redis_config() {
  local c="$1" key="$2"
  _db_redis_cli "${c}" CONFIG GET "${key}" | tr -d '\r' | sed -n '2p'
}

# _db_redis_info_field <container> <section> <field>
_db_redis_info_field() {
  local c="$1" section="$2" field="$3"
  _db_redis_cli "${c}" INFO "${section}" | tr -d '\r' \
    | awk -F: -v f="${field}" '$1==f {print $2; exit}'
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
db_redis_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  case "${image}" in
    *exporter* | *redisinsight* | *commander* | *sentinel*) return 1 ;;
  esac
  case "${image}" in
    *redis* | *valkey* | *keydb* | *dragonfly*) : ;;
    *) return 1 ;;
  esac

  if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
    | cut -d= -f1 \
    | grep -qxE 'REDIS_PASSWORD|REDIS_ARGS|REDIS_AOF_ENABLED|REDISCLI_AUTH|VALKEY_PASSWORD|KEYDB_PASSWORD|ALLOW_EMPTY_PASSWORD'; then
    return 0
  fi
  if docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
    | grep -qxE '6379/tcp|6380/tcp'; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Streaming into restic
# -----------------------------------------------------------------------------
_db_redis_argv() {
  local job="$1" run="$2" name="$3" tag="$4"
  restic_global_args
  printf 'backup\n'
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--json\n'
  printf -- '--stdin-from-command\n'
  printf -- '--stdin-filename\n%s\n' "${name}"
  restic_tag_args "${job}" "${run}" "kind=dbdump" "db=redis" "${tag}" "${JOB_TAGS[@]:-}"
  printf -- '--\n'
}

# See postgres.sh for why --stdin-from-command, timeout(1) and no `-t`.
# `-t` would be especially fatal here: an RDB file is binary and a pty would
# rewrite every 0x0a byte in it.
_db_redis_run() {
  local job="$1" run="$2" name="$3" tag="$4"
  shift 4
  [ "${1:-}" = "--" ] && shift

  local log rc=0
  log="$(tmp_file "db-redis-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(_db_redis_argv "${job}" "${run}" "${name}" "${tag}")
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$((${BGB_RUN_DB_DUMPS:-0} + 1))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$((${BGB_RUN_DB_DUMPS_FAILED:-0} + 1))
    err "redis: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi

  BGB_DB_LAST_SNAPSHOT=""
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "redis: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

_db_redis_degrade() {
  local why="$1"
  warn "${why}"
  if [ -n "${BGB_RUN_DEGRADED_REASON:-}" ]; then
    BGB_RUN_DEGRADED_REASON="${BGB_RUN_DEGRADED_REASON}; ${why}"
  else
    BGB_RUN_DEGRADED_REASON="${why}"
  fi
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
db_redis_dump() {
  local c="$1" job="$2" run="$3"
  local ping save aof dir file before after inprog status waited=0 rc=0

  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  ping="$(_db_redis_cli "${c}" PING | tr -d '\r' | head -n1 || true)"
  case "${ping}" in
    PONG) : ;;
    *NOAUTH* | *WRONGPASS*)
      BGB_DB_RESULT="refused"
      BGB_DB_RESULT_REASON="authentication required and no password in the container environment"
      err "redis: ${c}: the server requires authentication but no REDIS_PASSWORD is set in its environment"
      err "redis: the password is presumably in the command line (--requirepass) or a config file."
      err "redis: add REDIS_PASSWORD=<same value> to the container environment so bg-backup can read it"
      err "redis: from inside the container without ever storing it itself."
      return "${EX_PRECOND}"
      ;;
    *)
      BGB_DB_RESULT="failed"
      BGB_DB_RESULT_REASON="server did not answer PING"
      err "redis: ${c}: no PONG (got '${ping:-<nothing>}')"
      return "${EX_FAIL}"
      ;;
  esac

  # --- Is this a cache or a database? ----------------------------------------
  save="$(_db_redis_config "${c}" save || true)"
  aof="$(_db_redis_config "${c}" appendonly || true)"

  # `appendonly` always has a value ("yes" or "no") on a healthy server, so an
  # empty answer means CONFIG itself is unavailable - renamed away by
  # rename-command, or disabled by an ACL. Treating that as "no persistence"
  # would skip a real database silently, which is the one outcome this whole
  # file exists to prevent.
  if [ -z "${aof}" ]; then
    BGB_DB_RESULT="refused"
    BGB_DB_RESULT_REASON="CONFIG GET is unavailable - cannot determine persistence or locate the RDB"
    err "redis: ${c}: CONFIG GET returned nothing (renamed by rename-command, or denied by an ACL)"
    err "redis: grant the backup user access to CONFIG, or exclude this container via JOB_DB_EXCLUDE_CONTAINERS"
    return "${EX_PRECOND}"
  fi

  if [ -z "${save//[[:space:]]/}" ] && [ "${aof}" != "yes" ]; then
    BGB_DB_RESULT="skipped"
    BGB_DB_RESULT_REASON="no persistence configured - treated as a cache"
    log "redis: ${c}: no save points and appendonly no - this is a cache, not a database; skipping"
    log "redis: if it does hold state, configure persistence (save/appendonly) and it will be backed up"
    return "${EX_OK}"
  fi

  # --- BGSAVE and wait for the real completion signal ------------------------
  before="$(_db_redis_cli "${c}" LASTSAVE | tr -d '\r' | head -n1 || true)"
  case "${before}" in '' | *[!0-9]*) before=0 ;; esac

  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] redis: BGSAVE on ${c}"
  else
    local bg
    bg="$(_db_redis_cli "${c}" BGSAVE | tr -d '\r' | head -n1 || true)"
    case "${bg}" in
      *"Background saving started"* | *"scheduled"*) debug "redis: ${bg}" ;;
      *"already in progress"*) debug "redis: a save was already running - waiting for it" ;;
      *)
        BGB_DB_RESULT="failed"
        BGB_DB_RESULT_REASON="BGSAVE was refused"
        err "redis: ${c}: BGSAVE refused: ${bg:-<no reply>}"
        return "${EX_FAIL}"
        ;;
    esac

    while :; do
      inprog="$(_db_redis_info_field "${c}" persistence rdb_bgsave_in_progress || true)"
      after="$(_db_redis_cli "${c}" LASTSAVE | tr -d '\r' | head -n1 || true)"
      status="$(_db_redis_info_field "${c}" persistence rdb_last_bgsave_status || true)"
      case "${after}" in '' | *[!0-9]*) after=0 ;; esac

      if [ "${inprog}" = "0" ] && [ "${after}" -gt "${before}" ]; then
        if [ "${status}" = "ok" ]; then break; fi
        BGB_DB_RESULT="failed"
        BGB_DB_RESULT_REASON="rdb_last_bgsave_status=${status:-unknown}"
        err "redis: ${c}: the background save finished but reported '${status:-unknown}'"
        err "redis: the usual cause is too little free memory for the fork's copy-on-write pages"
        return "${EX_FAIL}"
      fi

      waited=$((waited + 2))
      if [ "${waited}" -ge "${BGB_DB_REDIS_SAVE_TIMEOUT:-900}" ]; then
        BGB_DB_RESULT="failed"
        BGB_DB_RESULT_REASON="BGSAVE did not complete within ${waited}s"
        err "redis: ${c}: BGSAVE still had not completed after ${waited}s - refusing to store a stale RDB"
        return "${EX_FAIL}"
      fi
      sleep 2
    done
    debug "redis: BGSAVE completed, rdb_last_save_time ${before} -> ${after}"
  fi

  # --- Stream the file we just proved is fresh -------------------------------
  dir="$(_db_redis_config "${c}" dir || true)"
  file="$(_db_redis_config "${c}" dbfilename || true)"
  if [ -z "${dir}" ] || [ -z "${file}" ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="CONFIG GET dir/dbfilename returned nothing"
    err "redis: ${c}: cannot locate the RDB (is CONFIG renamed or disabled?)"
    return "${EX_FAIL}"
  fi

  _db_redis_run "${job}" "${run}" "/db/redis/${c}/${file}" "aof=${aof:-no}" \
    -- docker exec -i "${c}" sh -c 'exec cat "$1"' _ "${dir%/}/${file}" || rc=$?

  if [ "${rc}" -ne 0 ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="could not read ${dir%/}/${file}"
    return "${rc}"
  fi

  if [ "${aof}" = "yes" ]; then
    log "redis: ${c}: appendonly is on - on restore, Redis loads the AOF and ignores this RDB"
    log "redis: see 'bg-backup dr plan' or db_redis_notes for the two-step restore"
  fi
  return "${EX_OK}"
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
# Per-database key counts from INFO keyspace. exact=false on purpose: these are
# read after the fork, so any write between the fork and this call is counted
# here but is not in the RDB. Marking them exact would make `verify` fail runs
# that were entirely correct.
db_redis_counts() {
  local c="${1:-}" raw line dbname keys first=1
  [ -n "${c}" ] || return 0
  have docker || return 0
  [ "${JOB_DB_RECORD_COUNTS:-1}" = "1" ] || return 0

  raw="$(_db_redis_cli "${c}" INFO keyspace | tr -d '\r' || true)"
  [ -n "${raw}" ] || return 0

  printf '{'
  json_kv engine redis
  printf ','
  json_kv container "${c}"
  printf ','
  json_kv taken "$(now_iso)"
  printf ','
  json_kv source "info-keyspace"
  printf ','
  json_kvraw exact false
  printf ','
  printf '"objects":{'
  while IFS= read -r line; do
    case "${line}" in db[0-9]*:keys=*) : ;; *) continue ;; esac
    dbname="${line%%:*}"
    keys="${line#*keys=}"
    keys="${keys%%,*}"
    [ "${first}" -eq 0 ] && printf ','
    json_kvraw "${dbname}" "$(json_num "${keys}")"
    first=0
  done <<<"${raw}"
  printf '}}\n'
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
# db_redis_restore <container> <rdb-file|->
#
# There is no online path for this. Redis writes its own RDB on shutdown and
# reads it at startup, so anything dropped in while the server is running is
# overwritten seconds later - which is why a naive "docker exec cp" restore
# appears to work and then silently reverts. The container is stopped, the file
# is placed with `docker cp` (which works on a stopped container), and it is
# started again.
db_redis_restore() {
  local c="${1:-}" src="${2:--}" rc=0
  [ -n "${c}" ] || die "${EX_USAGE}" "db_redis_restore: container is required"
  require_cmd docker

  local dir file aof
  dir="$(_db_redis_config "${c}" dir || true)"
  file="$(_db_redis_config "${c}" dbfilename || true)"
  aof="$(_db_redis_config "${c}" appendonly || true)"
  [ -n "${dir}" ] || dir="/data"
  [ -n "${file}" ] || file="dump.rdb"

  if [ "${aof}" = "yes" ]; then
    warn "redis: ${c} runs with appendonly yes - it will load the AOF and IGNORE the RDB you are restoring."
    warn "redis: after this completes, either remove ${dir%/}/appendonlydir (Redis 7+) or ${dir%/}/appendonly.aof*,"
    warn "redis: or start the container once with --appendonly no and then run BGREWRITEAOF."
  fi

  confirm "Stop ${c}, replace ${dir%/}/${file} and start it again?" || return "${EX_SAFETY}"

  local spool="${src}"
  if [ "${src}" = "-" ]; then
    spool="$(tmp_file "redis-rdb-XXXXXX")"
    cat >"${spool}"
  fi

  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] redis: docker stop ${c}; docker cp ${spool} ${c}:${dir%/}/${file}; docker start ${c}"
    return 0
  fi

  docker stop "${c}" >/dev/null || {
    err "redis: could not stop ${c}"
    return "${EX_FAIL}"
  }
  docker cp "${spool}" "${c}:${dir%/}/${file}" || rc=$?
  docker start "${c}" >/dev/null || rc=$?

  [ "${rc}" -eq 0 ] || err "redis: restore failed (rc=${rc})"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Health probe
# -----------------------------------------------------------------------------
db_redis_verify_cmd() {
  local c="${1:-}"
  printf 'docker\nexec\n%s\nsh\n-c\n' "${c}"
  printf '%s\n' 'if command -v redis-cli >/dev/null 2>&1; then C=redis-cli; elif command -v valkey-cli >/dev/null 2>&1; then C=valkey-cli; else C=keydb-cli; fi; pw="${REDIS_PASSWORD:-${VALKEY_PASSWORD:-${KEYDB_PASSWORD:-}}}"; if [ -n "$pw" ]; then REDISCLI_AUTH="$pw"; export REDISCLI_AUTH; fi; test "$("$C" PING)" = PONG'
}

# -----------------------------------------------------------------------------
# Operator notes
# -----------------------------------------------------------------------------
db_redis_notes() {
  cat <<'EOF'
Redis (and Valkey and KeyDB) are backed up by asking the server to write a fresh
RDB and then streaming that file. BGSAVE returns immediately, so bg-backup waits
for the real completion signal - bgsave no longer in progress, rdb_last_save_time
strictly newer than before the call, and rdb_last_bgsave_status ok - before it
reads anything. Skipping that wait, or trusting only "not in progress", copies
the previous save and stores an arbitrarily old dataset that looks perfectly
healthy. A failed BGSAVE (almost always too little free memory for the fork's
copy-on-write pages) is reported as a failure rather than silently backing up
the stale file. An instance with no save points and appendonly no is treated as
a cache and skipped with an explanation, because storing a meaningless RDB for
six months of retention helps nobody. THE RESTORE TRAP: when appendonly is yes,
Redis loads the AOF at startup and ignores dump.rdb entirely, so placing the RDB
and restarting appears to do nothing - remove appendonlydir (Redis 7+) or
appendonly.aof*, or start once with --appendonly no and then BGREWRITEAOF. The
restore stops the container before replacing the file, because a running Redis
rewrites its own RDB on shutdown and would overwrite whatever you put there. Key
counts come from INFO keyspace and are reported as inexact: they are read after
the fork, so writes made in between are counted but are not in the RDB.
EOF
}
