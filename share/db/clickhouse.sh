#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: ClickHouse
# =============================================================================
# ClickHouse has no `pg_dump`. Two mechanisms exist and they are not equivalent:
#
#   BACKUP DATABASE ... TO Disk('backups', ...)   native, consistent, needs a
#                                                 backup disk configured
#   SELECT ... INTO OUTFILE / FORMAT Native       per-table, no server config,
#                                                 but NOT a consistent point in
#                                                 time across tables
#
# The native BACKUP statement is used whenever a backup disk is configured. When
# it is not, this module falls back to per-table Native dumps and reports the
# result as DEGRADED - because tables are then dumped one after another and a
# write between two of them leaves the set internally inconsistent. That is
# usable for a single-table analytics store and not usable for anything with
# referential expectations, and the operator is the one who knows which it is.
# =============================================================================

[ -n "${_BGB_DB_CLICKHOUSE_SOURCED:-}" ] && return 0
_BGB_DB_CLICKHOUSE_SOURCED=1

db_clickhouse_aliases() { printf 'ch\nclickhouse-server\n'; }

: "${BGB_CH_DISK_NAME:=backups}"

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
db_clickhouse_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  case "${image}" in *exporter* | *keeper* | *tabix*) return 1 ;; esac
  case "${image}" in *clickhouse*) : ;; *) return 1 ;; esac

  docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
    | grep -qxE '8123/tcp|9000/tcp' && return 0
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
    | cut -d= -f1 | grep -qxE 'CLICKHOUSE_DB|CLICKHOUSE_USER|CLICKHOUSE_PASSWORD' && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Client access
# -----------------------------------------------------------------------------
# Credentials come from the container's own environment, never from bg-backup's
# configuration and never through argv.
# shellcheck disable=SC2016
_DB_CH_CLIENT_SH='
u="${CLICKHOUSE_USER:-default}"
p="${CLICKHOUSE_PASSWORD:-}"
if [ -n "$p" ]; then
  exec clickhouse-client --user "$u" --password "$p" "$@"
else
  exec clickhouse-client --user "$u" "$@"
fi
'

_db_ch_query() {
  local c="$1" q="$2"
  docker exec -i "${c}" sh -c "${_DB_CH_CLIENT_SH}" _ --query "${q}" 2>/dev/null
}

# _db_ch_has_backup_disk <container>
_db_ch_has_backup_disk() {
  local c="$1" out
  out="$(_db_ch_query "${c}" "SELECT name FROM system.disks WHERE name = '${BGB_CH_DISK_NAME}'")"
  [ -n "${out}" ]
}

_db_ch_databases() {
  local c="$1"
  _db_ch_query "${c}" \
    "SELECT name FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA','information_schema')"
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
_db_ch_run() {
  local job="$1" run="$2" name="$3" tag="$4"
  shift 4
  [ "${1:-}" = "--" ] && shift
  local log rc=0
  log="$(tmp_file "db-clickhouse-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(
    restic_global_args
    printf 'backup\n'
    printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
    printf -- '--json\n'
    printf -- '--stdin-from-command\n'
    printf -- '--stdin-filename\n%s\n' "${name}"
    restic_tag_args "${job}" "${run}" "kind=dbdump" "db=clickhouse" "${tag}" "${JOB_TAGS[@]:-}"
    printf -- '--\n'
  )
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$((${BGB_RUN_DB_DUMPS:-0} + 1))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"
  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$((${BGB_RUN_DB_DUMPS_FAILED:-0} + 1))
    err "clickhouse: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "clickhouse: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

db_clickhouse_dump() {
  local c="$1" job="$2" run="$3"
  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  if _db_ch_has_backup_disk "${c}"; then
    _db_ch_dump_native "${c}" "${job}" "${run}"
  else
    _db_ch_dump_tables "${c}" "${job}" "${run}"
  fi
}

# Native BACKUP: consistent across the whole database.
_db_ch_dump_native() {
  local c="$1" job="$2" run="$3" db rc=0 worst=0
  local -a dbs=()
  mapfile -t dbs < <(_db_ch_databases "${c}")
  [ "${#dbs[@]}" -gt 0 ] || {
    BGB_DB_RESULT="skipped"
    BGB_DB_RESULT_REASON="no user databases"
    return "${EX_OK}"
  }

  for db in "${dbs[@]}"; do
    [ -n "${db}" ] || continue
    local name="bgb_${run}_${db}"
    # BACKUP writes into the configured disk; the archive is then streamed out.
    if ! _db_ch_query "${c}" "BACKUP DATABASE \`${db}\` TO Disk('${BGB_CH_DISK_NAME}', '${name}.zip')" >/dev/null; then
      err "clickhouse: BACKUP DATABASE ${db} failed"
      BGB_DB_RESULT="failed"
      BGB_DB_RESULT_REASON="BACKUP DATABASE ${db} failed"
      return "${EX_FAIL}"
    fi
    rc=0
    _db_ch_run "${job}" "${run}" "/db/clickhouse/${c}/${db}.zip" "database=${db}" \
      -- docker exec -i "${c}" sh -c '
        set -e
        p=$(clickhouse-client --query "SELECT path FROM system.disks WHERE name='"'"'"$1"'"'"'" 2>/dev/null | head -n1)
        [ -n "$p" ] || exit 1
        cat "$p/$2.zip"
        rm -f "$p/$2.zip"
      ' _ "${BGB_CH_DISK_NAME}" "${name}" || rc=$?
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  [ "${worst}" -eq 0 ] || {
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="storing at least one native backup failed"
  }
  return "${worst}"
}

# Fallback: per-table Native format. Reported as degraded, see the header.
_db_ch_dump_tables() {
  local c="$1" job="$2" run="$3" rc=0 worst=0

  warn "clickhouse: ${c} has no '${BGB_CH_DISK_NAME}' disk configured."
  warn "  Falling back to per-table dumps, which are NOT a consistent point in"
  warn "  time across tables. Configure a backup disk for a real backup:"
  warn "      <storage_configuration><disks><${BGB_CH_DISK_NAME}>"
  warn "        <type>local</type><path>/var/lib/clickhouse/backups/</path>"
  warn "      </${BGB_CH_DISK_NAME}></disks></storage_configuration>"
  warn "      <backups><allowed_disk>${BGB_CH_DISK_NAME}</allowed_disk></backups>"

  local -a rows=()
  mapfile -t rows < <(_db_ch_query "${c}" \
    "SELECT database || '.' || name FROM system.tables
     WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema')
       AND engine NOT LIKE '%View'")
  [ "${#rows[@]}" -gt 0 ] || {
    BGB_DB_RESULT="skipped"
    BGB_DB_RESULT_REASON="no user tables"
    return "${EX_OK}"
  }

  # Schema first: data without CREATE TABLE statements cannot be loaded back.
  rc=0
  _db_ch_run "${job}" "${run}" "/db/clickhouse/${c}/schema.sql" "kind=schema" \
    -- docker exec -i "${c}" sh -c "${_DB_CH_CLIENT_SH}" _ --query \
    "SELECT create_table_query || ';' FROM system.tables
        WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema')
        FORMAT TabSeparatedRaw" || rc=$?
  worst="$(worst_rc "${worst}" "${rc}")"

  local t
  for t in "${rows[@]}"; do
    [ -n "${t}" ] || continue
    local safe="${t//[^A-Za-z0-9._-]/_}"
    rc=0
    _db_ch_run "${job}" "${run}" "/db/clickhouse/${c}/${safe}.native" "table=${safe}" \
      -- docker exec -i "${c}" sh -c "${_DB_CH_CLIENT_SH}" _ --query \
      "SELECT * FROM ${t} FORMAT Native" || rc=$?
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  if [ "${worst}" -ne 0 ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="at least one table dump failed"
    return "${worst}"
  fi

  db_mark_degraded "clickhouse/${c}: per-table dumps are not consistent across tables (no backup disk configured)"
  BGB_DB_RESULT="degraded"
  BGB_DB_RESULT_REASON="no backup disk - per-table dumps are not cross-table consistent"
  return "${EX_OK}"
}

# -----------------------------------------------------------------------------
# Counts / restore / verify
# -----------------------------------------------------------------------------
db_clickhouse_counts() {
  local c="$1" out
  out="$(_db_ch_query "${c}" \
    "SELECT database || '.' || table, sum(rows) FROM system.parts
     WHERE active AND database NOT IN ('system','INFORMATION_SCHEMA','information_schema')
     GROUP BY database, table FORMAT TabSeparated")"
  [ -n "${out}" ] || return 0
  printf '{'
  local first=1 name n
  while IFS=$'\t' read -r name n; do
    [ -n "${name}" ] || continue
    [ "${first}" -eq 0 ] && printf ','
    first=0
    printf '%s:%s' "$(json_str "${name}")" "$(json_num "${n}")"
  done <<<"${out}"
  printf '}'
}

db_clickhouse_restore() {
  local c="$1"
  require_cmd docker
  # Only the schema/Native fallback can be replayed from a stream; a native
  # BACKUP archive must be placed on the disk and restored with RESTORE.
  docker exec -i "${c}" sh -c "${_DB_CH_CLIENT_SH}" _ --multiquery
}

db_clickhouse_verify_cmd() {
  local c="$1"
  _db_ch_query "${c}" "SELECT 1" | grep -q '^1$'
}

db_clickhouse_notes() {
  cat <<'EOF'
Native BACKUP DATABASE ... TO Disk when a backup disk is configured (consistent).
Otherwise per-table Native dumps, reported as DEGRADED because they are not a
consistent point in time across tables.
EOF
}
