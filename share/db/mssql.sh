#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: Microsoft SQL Server
# =============================================================================
# SQL Server cannot write a backup to stdout: `BACKUP DATABASE ... TO DISK` only
# targets a file the server process itself can reach. So the sequence is
#
#   BACKUP DATABASE ... TO DISK WITH CHECKSUM, COMPRESSION
#   cat the .bak into restic
#   remove the .bak
#
# all inside ONE `sh -c` with `set -e`, so any failing step propagates and
# --stdin-from-command discards the snapshot rather than storing a partial file.
#
# WITH CHECKSUM is not optional here. It makes the server verify page checksums
# while writing, which turns "the backup file exists" into "the backup file is
# internally consistent" - and it is what makes RESTORE VERIFYONLY meaningful
# during `bg-backup verify`.
# =============================================================================

[ -n "${_BGB_DB_MSSQL_SOURCED:-}" ] && return 0
_BGB_DB_MSSQL_SOURCED=1

db_mssql_aliases() { printf 'sqlserver\nmssqlserver\n'; }

: "${BGB_MSSQL_BACKUP_DIR:=/var/opt/mssql/backup}"

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
db_mssql_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  case "${image}" in *exporter*|*tools*) return 1 ;; esac
  case "${image}" in
    *mssql*|*sqlserver*|*sql-server*) : ;;
    *) return 1 ;;
  esac

  # ACCEPT_EULA is effectively mandatory for the official image, so it is a
  # reliable confirmation that this is a server and not a client container.
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
    | cut -d= -f1 | grep -qxE 'ACCEPT_EULA|MSSQL_SA_PASSWORD|SA_PASSWORD' && return 0
  docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
    | grep -qx '1433/tcp' && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Client access
# -----------------------------------------------------------------------------
# The SA password is read by the CONTAINER's shell from its own environment and
# passed to sqlcmd via -P inside that shell. It never reaches bg-backup and never
# appears in the host's process list.
#
# sqlcmd moved from /opt/mssql-tools/bin to /opt/mssql-tools18/bin, and the 18
# build defaults to encrypted connections with strict certificate validation -
# which fails against the self-signed certificate the container generates. Hence
# the -C (trust server certificate) when the 18 binary is in use.
# shellcheck disable=SC2016
_DB_MSSQL_SQLCMD_SH='
pw="${MSSQL_SA_PASSWORD:-${SA_PASSWORD:-}}"
user="${MSSQL_SA_USER:-sa}"
if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then
  bin=/opt/mssql-tools18/bin/sqlcmd; extra="-C"
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then
  bin=/opt/mssql-tools/bin/sqlcmd; extra=""
elif command -v sqlcmd >/dev/null 2>&1; then
  bin=sqlcmd; extra="-C"
else
  echo "sqlcmd not found in the container" >&2; exit 127
fi
# shellcheck disable=SC2086
exec "$bin" $extra -S localhost -U "$user" -P "$pw" -b "$@"
'

_db_mssql_query() {
  local c="$1" q="$2"
  docker exec -i "${c}" sh -c "${_DB_MSSQL_SQLCMD_SH}" _ -h -1 -W -Q "SET NOCOUNT ON; ${q}" 2>/dev/null
}

_db_mssql_databases() {
  local c="$1"
  # Exclude the system databases: master/model/msdb are rebuilt by the engine and
  # tempdb cannot be backed up at all.
  _db_mssql_query "${c}" \
    "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE';" \
    | sed '/^$/d' | tr -d '\r'
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
# shellcheck disable=SC2016
_DB_MSSQL_BACKUP_SH='
set -e
db="$1"; dir="$2"
mkdir -p "$dir"
f="$dir/$db.bak"
rm -f "$f"
trap "rm -f \"$f\"" EXIT
pw="${MSSQL_SA_PASSWORD:-${SA_PASSWORD:-}}"
user="${MSSQL_SA_USER:-sa}"
if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then bin=/opt/mssql-tools18/bin/sqlcmd; extra="-C"
elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then bin=/opt/mssql-tools/bin/sqlcmd; extra=""
else bin=sqlcmd; extra="-C"; fi
# -b makes sqlcmd exit non-zero on a T-SQL error; without it a failed BACKUP
# still exits 0 and an empty file would be stored as a healthy snapshot.
"$bin" $extra -S localhost -U "$user" -P "$pw" -b -Q \
  "BACKUP DATABASE [$db] TO DISK = N'"'"'$f'"'"' WITH INIT, CHECKSUM, COMPRESSION, STATS = 0;" >/dev/null
[ -s "$f" ]
cat "$f"
'

db_mssql_dump() {
  local c="$1" job="$2" run="$3"
  local rc=0 worst=0 db
  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  local -a dbs=()
  mapfile -t dbs < <(_db_mssql_databases "${c}")

  if [ "${#dbs[@]}" -eq 0 ]; then
    warn "mssql: ${c}: no user databases found (or sqlcmd is unavailable)"
    BGB_DB_RESULT="skipped"
    BGB_DB_RESULT_REASON="no user databases"
    return "${EX_OK}"
  fi

  for db in "${dbs[@]}"; do
    [ -n "${db}" ] || continue
    local safe="${db//[^A-Za-z0-9._-]/_}"
    rc=0
    _db_mssql_run "${job}" "${run}" "/db/mssql/${c}/${safe}.bak" "database=${safe}" \
      -- docker exec -i "${c}" sh -c "${_DB_MSSQL_BACKUP_SH}" _ "${db}" "${BGB_MSSQL_BACKUP_DIR}" || rc=$?
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  if [ "${worst}" -ne 0 ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="at least one database backup failed"
    return "${worst}"
  fi
  return "${EX_OK}"
}

_db_mssql_run() {
  local job="$1" run="$2" name="$3" tag="$4"; shift 4
  [ "${1:-}" = "--" ] && shift
  local log rc=0
  log="$(tmp_file "db-mssql-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(
    restic_global_args
    printf 'backup\n'
    printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
    printf -- '--json\n'
    printf -- '--stdin-from-command\n'
    printf -- '--stdin-filename\n%s\n' "${name}"
    restic_tag_args "${job}" "${run}" "kind=dbdump" "db=mssql" "${tag}" "${JOB_TAGS[@]:-}"
    printf -- '--\n'
  )
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$(( ${BGB_RUN_DB_DUMPS:-0} + 1 ))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"
  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$(( ${BGB_RUN_DB_DUMPS_FAILED:-0} + 1 ))
    err "mssql: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "mssql: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
db_mssql_counts() {
  local c="$1" db out
  local -a dbs=()
  mapfile -t dbs < <(_db_mssql_databases "${c}")
  [ "${#dbs[@]}" -gt 0 ] || return 0

  printf '{'
  local first=1
  for db in "${dbs[@]}"; do
    [ -n "${db}" ] || continue
    # sys.dm_db_partition_stats is an approximation maintained by the engine;
    # exact per-table COUNT(*) across every database would be far too expensive
    # to take on every backup.
    out="$(_db_mssql_query "${c}" \
      "USE [${db}]; SELECT o.name + '|' + CAST(SUM(p.row_count) AS VARCHAR(32))
       FROM sys.dm_db_partition_stats p JOIN sys.objects o ON o.object_id = p.object_id
       WHERE p.index_id IN (0,1) AND o.type = 'U' GROUP BY o.name;" | tr -d '\r')"
    local line name n
    while IFS='|' read -r name n; do
      [ -n "${name}" ] || continue
      [ "${first}" -eq 0 ] && printf ','
      first=0
      printf '%s:%s' "$(json_str "${db}.${name}")" "$(json_num "${n}")"
    done <<<"${out}"
  done
  printf '}'
}

# -----------------------------------------------------------------------------
# Restore / verify
# -----------------------------------------------------------------------------
db_mssql_restore() {
  local c="$1" db="${2:-}"
  require_cmd docker
  [ -n "${db}" ] || { err "mssql: restore needs a database name"; return "${EX_PRECOND}"; }

  # WITH MOVE is required whenever the target's data paths differ from the
  # source's, which they usually do after a rebuild. The file list is read from
  # the backup itself rather than assumed.
  docker exec -i "${c}" sh -c '
    set -e
    db="$1"; dir="$2"
    mkdir -p "$dir"
    f="$dir/restore-$db.bak"
    trap "rm -f \"$f\"" EXIT
    cat > "$f"
    pw="${MSSQL_SA_PASSWORD:-${SA_PASSWORD:-}}"; user="${MSSQL_SA_USER:-sa}"
    if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then bin=/opt/mssql-tools18/bin/sqlcmd; extra="-C"
    elif [ -x /opt/mssql-tools/bin/sqlcmd ]; then bin=/opt/mssql-tools/bin/sqlcmd; extra=""
    else bin=sqlcmd; extra="-C"; fi
    "$bin" $extra -S localhost -U "$user" -P "$pw" -b -Q \
      "RESTORE VERIFYONLY FROM DISK = N'"'"'$f'"'"' WITH CHECKSUM;" >/dev/null
    "$bin" $extra -S localhost -U "$user" -P "$pw" -b -Q \
      "RESTORE DATABASE [$db] FROM DISK = N'"'"'$f'"'"' WITH REPLACE, CHECKSUM;" >/dev/null
  ' _ "${db}" "${BGB_MSSQL_BACKUP_DIR}"
}

db_mssql_verify_cmd() {
  local c="$1"
  _db_mssql_query "${c}" "SELECT 1;" | tr -d '\r ' | grep -q '^1$'
}

db_mssql_notes() {
  cat <<'EOF'
BACKUP DATABASE ... TO DISK WITH CHECKSUM, COMPRESSION per user database, then
the .bak is streamed into restic and removed. WITH CHECKSUM is what makes
RESTORE VERIFYONLY meaningful during verify. System databases are skipped.
EOF
}
