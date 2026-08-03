#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: MySQL and MariaDB
# =============================================================================
# One file for both because they share a wire protocol, a dump format and every
# trap worth documenting. The differences that matter are handled at runtime:
#
#   * MariaDB 11 deprecated the mysqldump/mysql symlinks and will eventually
#     drop them. mariadb-dump and mariadb are preferred whenever they exist, so
#     the job does not start failing on a routine image bump.
#   * --set-gtid-purged and --column-statistics exist only on MySQL's client.
#     Passing either to mariadb-dump is a fatal "unknown option", so both are
#     probed with --help before use rather than guessed from the version string.
#
# THE CAVEAT THIS FILE EXISTS FOR:
#
#   --single-transaction gives a consistent dump for InnoDB ONLY. It opens one
#   REPEATABLE READ transaction and dumps everything inside it - which does
#   nothing whatsoever for MyISAM, Aria, MEMORY, CSV or ARCHIVE tables, because
#   those engines are not transactional. Those tables are read one at a time,
#   whenever the dump happens to reach them, with writes landing in between. The
#   result is a dump that is internally inconsistent and looks completely
#   healthy.
#
#   The alternative - --lock-all-tables - takes a global read lock for the whole
#   dump, which on a production server means an outage measured in minutes.
#
#   bg-backup therefore does neither silently: it detects non-transactional
#   tables, still takes the --single-transaction dump, and reports the run as
#   DEGRADED with the offending table names. An operator can then convert them
#   to InnoDB, or accept the risk knowingly. What must never happen is a tool
#   claiming consistency it did not achieve.
# =============================================================================

[ -n "${_BGB_DB_MYSQL_SOURCED:-}" ] && return 0
_BGB_DB_MYSQL_SOURCED=1

db_mysql_aliases() { printf 'mariadb\npercona\n'; }

# -----------------------------------------------------------------------------
# Container scripts
# -----------------------------------------------------------------------------
# The root password is read by the CONTAINER's shell from the container's own
# environment and written into a 0600 defaults-extra-file inside the container.
# It never reaches bg-backup, never reaches argv (so not /proc/<pid>/cmdline)
# and is removed by an EXIT trap. MYSQL_PWD would also keep it out of argv but
# is documented as deprecated and prints a warning onto the dump's stderr on
# some builds, which pollutes the very stream we are watching for errors.

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MY_CREDS_SH <<'EOS' || true
pw="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-${MARIADB_PASSWORD:-${MYSQL_PASSWORD:-}}}}"
user="${MARIADB_ROOT_USER:-${MYSQL_ROOT_USER:-root}}"
umask 077
cnf=$(mktemp)
trap 'rm -f "$cnf"' EXIT INT TERM
# Option files are not shell: a password containing " or \ must be escaped, and
# one containing # would otherwise be truncated at the comment marker. That
# truncation presents as "access denied" on a password the operator can see is
# correct.
esc=$(printf '%s' "$pw" | sed 's/\\/\\\\/g; s/"/\\"/g')
{
  echo '[client]'
  printf 'user=%s\n' "$user"
  printf 'password="%s"\n' "$esc"
} >"$cnf"
if command -v mariadb-dump >/dev/null 2>&1; then DUMP=mariadb-dump; else DUMP=mysqldump; fi
if command -v mariadb      >/dev/null 2>&1; then CLI=mariadb;       else CLI=mysql;      fi
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MY_DUMP_SH <<'EOS' || true
set -e
__CREDS__
opts=""
# Probe, do not guess. --set-gtid-purged=COMMENTED keeps a GTID-enabled MySQL
# dump loadable into a server that already has its own GTID history; without it
# the restore aborts with ERROR 3546. --column-statistics=0 is required when a
# MySQL 8 client dumps anything older, otherwise the dump dies immediately on
# "Unknown table 'COLUMN_STATISTICS' in information_schema".
if "$DUMP" --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then
  opts="$opts --set-gtid-purged=COMMENTED"
fi
if "$DUMP" --help 2>/dev/null | grep -q -- '--column-statistics'; then
  opts="$opts --column-statistics=0"
fi

# --defaults-extra-file MUST be the first option or the client refuses it.
# $opts is intentionally unquoted: it is a list of options, not one argument.
# shellcheck disable=SC2086
"$DUMP" --defaults-extra-file="$cnf" $opts \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  --events \
  --hex-blob \
  --all-databases \
  --default-character-set=utf8mb4
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MY_QUERY_SH <<'EOS' || true
set -e
sql="$1"
__CREDS__
exec "$CLI" --defaults-extra-file="$cnf" --batch --skip-column-names --raw -e "$sql"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MY_RESTORE_SH <<'EOS' || true
set -e
__CREDS__
# --binary-mode stops the client from mangling 0x1a and bare \r inside the
# --hex-blob output and BLOB literals. Without it a restore of binary data
# succeeds and silently corrupts rows.
exec "$CLI" --defaults-extra-file="$cnf" --binary-mode
EOS

_db_mysql_script() {
  # str_replace_all, NOT ${1//__CREDS__/...}: bash processes backslashes in a
  # substitution's replacement, which halved every backslash run in the spliced
  # preamble and turned its `sed 's/\\/\\\\/g; s/"/\\"/g'` into an expression
  # sed refuses. Every MySQL and MariaDB dump failed on it.
  str_replace_all "$1" '__CREDS__' "${_DB_MY_CREDS_SH}"
}

# _db_mysql_query <container> <sql> - stdout is tab-separated, no headers.
_db_mysql_query() {
  local c="$1" sql="$2"
  docker exec -i "${c}" sh -c "$(_db_mysql_script "${_DB_MY_QUERY_SH}")" _ "${sql}" 2>/dev/null
}

_db_mysql_degrade() {
  local why="$1"
  warn "${why}"
  if [ -n "${BGB_RUN_DEGRADED_REASON:-}" ]; then
    BGB_RUN_DEGRADED_REASON="${BGB_RUN_DEGRADED_REASON}; ${why}"
  else
    BGB_RUN_DEGRADED_REASON="${why}"
  fi
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
# Image first, then proof. `prom/mysqld-exporter` and `bitnami/mysqld-exporter`
# match every name-based heuristic and cannot be dumped; ProxySQL answers on
# 6033 and speaks the protocol but owns no data.
db_mysql_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  case "${image}" in
    *exporter* | *proxysql* | *maxscale* | *phpmyadmin* | *adminer* | *orchestrator*) return 1 ;;
  esac
  case "${image}" in
    *mysql* | *mariadb* | *percona* | *mytop*) : ;;
    *) return 1 ;;
  esac

  if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
    | cut -d= -f1 \
    | grep -qxE 'MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD|MYSQL_DATABASE|MARIADB_DATABASE|MYSQL_ALLOW_EMPTY_PASSWORD|MARIADB_ALLOW_EMPTY_ROOT_PASSWORD|MYSQL_RANDOM_ROOT_PASSWORD'; then
    return 0
  fi
  if docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
    | grep -qx '3306/tcp'; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Streaming into restic
# -----------------------------------------------------------------------------
_db_mysql_argv() {
  local job="$1" run="$2" name="$3" tag="$4"
  restic_global_args
  printf 'backup\n'
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--json\n'
  printf -- '--stdin-from-command\n'
  printf -- '--stdin-filename\n%s\n' "${name}"
  restic_tag_args "${job}" "${run}" "kind=dbdump" "db=mysql" "${tag}" "${JOB_TAGS[@]:-}"
  printf -- '--\n'
}

# See postgres.sh for the full reasoning behind --stdin-from-command, the
# timeout(1) prefix and the deliberate absence of `docker exec -t`.
_db_mysql_run() {
  local job="$1" run="$2" name="$3" tag="$4"
  shift 4
  [ "${1:-}" = "--" ] && shift

  local log rc=0
  log="$(tmp_file "db-mysql-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(_db_mysql_argv "${job}" "${run}" "${name}" "${tag}")
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$((${BGB_RUN_DB_DUMPS:-0} + 1))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$((${BGB_RUN_DB_DUMPS_FAILED:-0} + 1))
    err "mysql: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi

  BGB_DB_LAST_SNAPSHOT=""
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "mysql: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
db_mysql_dump() {
  local c="$1" job="$2" run="$3"
  local flavour="mysql" version="" nontx=""

  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  version="$(_db_mysql_query "${c}" 'SELECT VERSION()' | head -n1 || true)"
  case "${version}" in
    *MariaDB* | *mariadb*) flavour="mariadb" ;;
  esac
  debug "mysql: ${c} reports version '${version:-unknown}' (${flavour})"

  # The consistency check runs BEFORE the dump so that its verdict is already
  # recorded if the dump itself then fails.
  nontx="$(_db_mysql_query "${c}" "$(_db_mysql_nontx_sql)" | head -n 25 || true)"

  local name="/db/mysql/${c}/all-databases.sql"
  local rc=0
  _db_mysql_run "${job}" "${run}" "${name}" "flavour=${flavour}" \
    -- docker exec -i "${c}" sh -c "$(_db_mysql_script "${_DB_MY_DUMP_SH}")" _ || rc=$?

  if [ "${rc}" -ne 0 ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="mysqldump/mariadb-dump failed"
    return "${rc}"
  fi

  if [ -n "${nontx}" ]; then
    local list count
    list="$(printf '%s' "${nontx}" | tr '\n' ' ')"
    count="$(printf '%s\n' "${nontx}" | grep -c '^' || true)"
    BGB_DB_RESULT="degraded"
    BGB_DB_RESULT_REASON="non-transactional tables dumped without a consistent snapshot"
    _db_mysql_degrade "mysql/${c}: ${count} non-transactional table(s) - --single-transaction does NOT make these consistent: ${list}"
    log "mysql: convert them with ALTER TABLE <t> ENGINE=InnoDB, or accept the risk knowingly"
    return "${EX_OK}"
  fi

  return "${EX_OK}"
}

# Excludes the server's own schemas. The `mysql` schema is MyISAM/Aria by design
# on MariaDB and there is nothing an operator can do about it, so listing it
# would turn every single run into a DEGRADED run and train people to ignore the
# flag. Its contents (grants) are still dumped - just not transactionally.
_db_mysql_nontx_sql() {
  cat <<'SQL'
SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '[', ENGINE, ']')
  FROM information_schema.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE'
   AND ENGINE IN ('MyISAM','Aria','MEMORY','CSV','ARCHIVE','MRG_MyISAM','BLACKHOLE')
   AND TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
 ORDER BY 1
SQL
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
# Exact COUNT(*) per table, taken inside START TRANSACTION WITH CONSISTENT
# SNAPSHOT so all of them describe one instant.
#
# HONEST LIMITATION, unlike PostgreSQL: mysqldump owns its own connection and
# offers no way to join an existing transaction, so these counts are taken
# immediately before the dump rather than inside it. They are consistent with
# each other but not necessarily identical to the dump. That is why the document
# reports source="adjacent-transaction" - a verify comparing a restored server
# against them on a write-heavy database should expect drift.
#
# information_schema.TABLE_ROWS is NOT used: for InnoDB it is a sampled estimate
# that can be off by an order of magnitude, which would make every assertion
# meaningless.
db_mysql_counts() {
  local c="${1:-}" raw
  [ -n "${c}" ] || return 0
  have docker || return 0
  [ "${JOB_DB_RECORD_COUNTS:-1}" = "1" ] || return 0

  raw="$(_db_mysql_query "${c}" "$(_db_mysql_counts_sql)" || true)"
  [ -n "${raw}" ] || return 0

  local key val first=1
  printf '{'
  json_kv engine mysql
  printf ','
  json_kv container "${c}"
  printf ','
  json_kv taken "$(now_iso)"
  printf ','
  json_kv source "adjacent-transaction"
  printf ','
  json_kvraw exact true
  printf ','
  printf '"objects":{'
  while IFS=$'\t' read -r key val; do
    [ -n "${key}" ] || continue
    case "${key}" in NULL) continue ;; esac
    [ "${first}" -eq 0 ] && printf ','
    json_kvraw "${key}" "$(json_num "${val}")"
    first=0
  done <<<"${raw}"
  printf '}}\n'
}

# The table list is turned into a single UNION ALL statement and executed as a
# prepared statement. One statement inside one transaction is what makes every
# count share a snapshot; a loop of per-table queries would not.
_db_mysql_counts_sql() {
  cat <<'SQL'
SET SESSION group_concat_max_len = 1073741824;
SELECT GROUP_CONCAT(CONCAT("SELECT '", TABLE_SCHEMA, ".", TABLE_NAME,
       "' AS o, COUNT(*) AS c FROM `", TABLE_SCHEMA, "`.`", TABLE_NAME, "`")
       SEPARATOR ' UNION ALL ') INTO @q
  FROM information_schema.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE'
   AND TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys');
SET @q = IFNULL(@q, "SELECT NULL AS o, NULL AS c FROM DUAL WHERE 0");
PREPARE stmt FROM @q;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
EXECUTE stmt;
COMMIT;
DEALLOCATE PREPARE stmt;
SQL
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
# db_mysql_restore <container> <dump-file|->
db_mysql_restore() {
  local c="${1:-}" src="${2:--}" rc=0
  [ -n "${c}" ] || die "${EX_USAGE}" "db_mysql_restore: container is required"
  require_cmd docker

  log "mysql: loading dump into ${c}"
  if [ "${src}" = "-" ]; then
    docker exec -i "${c}" sh -c "$(_db_mysql_script "${_DB_MY_RESTORE_SH}")" _ || rc=$?
  else
    docker exec -i "${c}" sh -c "$(_db_mysql_script "${_DB_MY_RESTORE_SH}")" _ <"${src}" || rc=$?
  fi

  if [ "${rc}" -ne 0 ]; then
    err "mysql: restore failed (rc=${rc})"
    return "${rc}"
  fi
  # An --all-databases dump rewrites the grant tables. Until FLUSH PRIVILEGES
  # runs, the server keeps serving the in-memory copy from before the restore,
  # so a restored user appears not to exist.
  _db_mysql_query "${c}" 'FLUSH PRIVILEGES' >/dev/null 2>&1 \
    || warn "mysql: FLUSH PRIVILEGES failed - restart the container before testing logins"
  return 0
}

# -----------------------------------------------------------------------------
# Health probe
# -----------------------------------------------------------------------------
db_mysql_verify_cmd() {
  local c="${1:-}"
  printf 'docker\nexec\n%s\nsh\n-c\n' "${c}"
  printf '%s\n' 'if command -v mariadb-admin >/dev/null 2>&1; then a=mariadb-admin; else a=mysqladmin; fi; MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}" exec "$a" -u"${MARIADB_ROOT_USER:-${MYSQL_ROOT_USER:-root}}" ping'
}

# -----------------------------------------------------------------------------
# Operator notes
# -----------------------------------------------------------------------------
db_mysql_notes() {
  cat <<'EOF'
MySQL and MariaDB are dumped as one plain-SQL --all-databases stream, streamed
into restic with --stdin-from-command so a dump that dies mid-table fails the
backup instead of being stored as a healthy snapshot. The flags are
--single-transaction --quick --routines --triggers --events --hex-blob: routines,
triggers and events are excluded by default and their absence is only noticed
when the application breaks after a restore. mariadb-dump is preferred over the
deprecated mysqldump symlink, and --set-gtid-purged / --column-statistics are
probed rather than assumed. THE IMPORTANT LIMITATION: --single-transaction is
consistent for InnoDB only. Any MyISAM, Aria, MEMORY, CSV or ARCHIVE table is
read outside that transaction and can be torn; bg-backup detects those tables
and marks the run DEGRADED with their names rather than pretending otherwise.
The fix is ALTER TABLE ... ENGINE=InnoDB. The server's own `mysql` schema is
excluded from that check because it is non-transactional by design on MariaDB.
Row counts are exact COUNT(*) values taken in an adjacent consistent-snapshot
transaction, not information_schema estimates, but they are not inside the dump's
own transaction - expect small drift on a write-heavy server. After a restore,
run FLUSH PRIVILEGES (db_mysql_restore does) or restart the container. Not
covered: binary logs and point-in-time recovery.
EOF
}
