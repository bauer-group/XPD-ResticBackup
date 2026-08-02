#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: PostgreSQL
# =============================================================================
# Produces, per container:
#
#   /db/postgres/<container>/globals.sql   pg_dumpall --globals-only
#   /db/postgres/<container>/<db>.dump     pg_dump --format=custom, one per DB
#
# WHY BOTH. A dump of every database without the cluster globals restores into a
# cluster that nobody can log into: roles, role memberships, role passwords,
# tablespaces and ALTER ROLE ... SET settings all live outside any single
# database. The failure is silent at backup time and total at restore time -
# every GRANT in the per-database dumps refers to a role that no longer exists,
# so pg_restore emits thousands of "role does not exist" errors and the
# application cannot authenticate. globals.sql is therefore not optional and is
# restored FIRST.
#
# WHY --compress=0 ON A CUSTOM-FORMAT DUMP. pg_dump -Fc compresses with zlib at
# level 6 by default. restic already compresses (repository format v2), and -
# far more importantly - a compressed stream changes wholesale after the first
# differing byte, which destroys content-defined chunking. Yesterday's 8 GiB
# dump and today's 8 GiB dump deduplicate to almost nothing when compressed and
# to a few megabytes of delta when they are plain. Turning compression off makes
# the repository smaller, not larger.
#
# WHY THE EXPORTED SNAPSHOT. Row counts taken with a second connection are taken
# at a different instant than the dump, so a busy database produces counts that
# never matched any state pg_dump saw. `verify` would then compare a restored
# database against numbers that were wrong when they were written. The dump
# therefore opens a REPEATABLE READ transaction, exports its snapshot with
# pg_export_snapshot(), and both the counting query and pg_dump --snapshot=...
# read that exact same snapshot.
# =============================================================================

[ -n "${_BGB_DB_POSTGRES_SOURCED:-}" ] && return 0
_BGB_DB_POSTGRES_SOURCED=1

# Sidecar written inside the container by the dump and consumed by _counts.
# Deliberately a fixed path: the dump and the counts call are two separate
# `docker exec` invocations, so there is nowhere else to hand the file over.
_DB_POSTGRES_COUNTS_PATH='/tmp/.bg-backup-pg-counts.psv'

db_postgres_aliases() { printf 'postgresql\npgsql\ntimescaledb\n'; }

# -----------------------------------------------------------------------------
# Container scripts
# -----------------------------------------------------------------------------
# Every script below runs inside the container with `sh -c "<script>" _ <args>`.
#
# The credentials are resolved by the CONTAINER's own shell from the container's
# own environment. bg-backup never reads POSTGRES_PASSWORD, never stores it and
# never passes it as an argument - so it appears in no configuration file, no
# log line and no /proc/<pid>/cmdline. That is the whole reason these are shell
# scripts instead of neatly built argv arrays on the host.

# shellcheck disable=SC2016  # $-expansions are for the container shell, not us
IFS= read -r -d '' _DB_PG_CREDS_SH <<'EOS' || true
# Resolve the superuser credentials from whichever convention this image uses:
# official (POSTGRES_*), bitnami (POSTGRESQL_*), or an already-exported PG*.
: "${PGUSER:=${POSTGRES_USER:-${POSTGRESQL_USERNAME:-postgres}}}"
: "${PGPASSWORD:=${POSTGRES_PASSWORD:-${POSTGRESQL_PASSWORD:-${POSTGRES_POSTGRES_PASSWORD:-}}}}"
export PGUSER PGPASSWORD
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_PG_LIST_SH <<'EOS' || true
set -e
__CREDS__
exec psql -X -Atq -w -d postgres \
  -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_PG_GLOBALS_SH <<'EOS' || true
set -e
__CREDS__
# NOT --no-role-passwords. That flag exists for dumps that will be published, and
# using it here produces a cluster whose every role has an empty password: the
# restore "succeeds" and then no application can authenticate. The dump is
# already stored in an encrypted repository; the hashes belong in it.
exec pg_dumpall --globals-only --no-password
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_PG_DUMP_SH <<'EOS' || true
set -e
db="$1"; counts="$2"
__CREDS__
umask 077
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT INT TERM
mkfifo "$d/ctl"

# A psql session fed from a FIFO. Keeping file descriptor 3 open on the write
# end is what keeps the session - and therefore the exported transaction
# snapshot - alive while pg_dump runs in a different connection. Close it and
# PostgreSQL discards the snapshot, after which pg_dump --snapshot fails with
# "invalid snapshot identifier".
psql -X -q -w -v ON_ERROR_STOP=1 -d "$db" -f "$d/ctl" >/dev/null 2>"$d/err" &
exec 3>"$d/ctl"

# \o <file> ... \o is not cosmetic: psql block-buffers stdout when it is not a
# terminal, so a bare SELECT would sit in a 4 KiB buffer and never reach us -
# the loop below would spin until it timed out. Closing the \o file flushes it.
printf '\\o %s/snap\nBEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT pg_export_snapshot();\n\\o\n' "$d" >&3

i=0
while [ ! -s "$d/snap" ]; do
  i=$((i + 1))
  if [ "$i" -gt 300 ]; then
    echo "bg-backup: pg_export_snapshot() produced no result within 60s" >&2
    cat "$d/err" >&2 2>/dev/null || true
    exit 1
  fi
  sleep 0.2 2>/dev/null || sleep 1
done
snap=$(tr -d '[:space:]' < "$d/snap")
if [ -z "$snap" ]; then
  echo "bg-backup: empty exported snapshot id" >&2
  cat "$d/err" >&2 2>/dev/null || true
  exit 1
fi

if [ -n "$counts" ]; then
  # SET TRANSACTION SNAPSHOT joins the exporting transaction's view of the
  # database. query_to_xml() is the only way to run count(*) against a table
  # named by a catalogue row inside a single statement, and a single statement
  # is what keeps every count in the same snapshot.
  #
  # Partitioned parents (relkind 'p') are counted once and their leaves are
  # skipped, otherwise every partitioned row would be counted twice.
  psql -X -Atq -w -d "$db" -c "
    BEGIN ISOLATION LEVEL REPEATABLE READ;
    SET TRANSACTION SNAPSHOT '$snap';
    SELECT '$db' || '.' || n.nspname || '.' || c.relname || '|' ||
           (xpath('/row/c/text()', query_to_xml(
              format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
              false, true, '')))[1]::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE (c.relkind = 'p' OR (c.relkind = 'r' AND NOT c.relispartition))
       AND c.relpersistence = 'p'
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND n.nspname NOT LIKE 'pg_toast%'
     ORDER BY 1;" >>"$counts" 2>/dev/null || true
fi

# --compress=0: see the file header. Anything above 0 costs repository space.
pg_dump --format=custom --compress=0 --no-password --snapshot="$snap" -d "$db"
EOS

_db_postgres_script() {
  local body="$1"
  # Splice the credential preamble in. Done here rather than by concatenating at
  # call sites so there is exactly one definition of how credentials are found.
  printf '%s' "${body//__CREDS__/${_DB_PG_CREDS_SH}}"
}

# _db_postgres_sh <container> <script> [args...]
_db_postgres_sh() {
  local c="$1" script="$2"; shift 2
  docker exec -i "${c}" sh -c "${script}" _ "$@"
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
# Two stages, and the second is the one that matters. `prometheuscommunity/
# postgres-exporter` and `bitnami/pgbouncer` both look like PostgreSQL by name;
# neither can be dumped, and asking them to would fail the whole backup. The
# image match narrows the candidate set, the env/port match proves it is a
# server.
db_postgres_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  case "${image}" in
    *exporter*|*pgbouncer*|*pgpool*|*pgcat*|*pgadmin*|*backrest*|*barman*) return 1 ;;
  esac
  case "${image}" in
    *postgres*|*postgis*|*timescale*|*pgvector*|*pgvecto*|*citus*|*paradedb*|*cloudnative-pg*|*supabase*) : ;;
    *) return 1 ;;
  esac

  # Env names only - the values are never assigned to a shell variable, so a
  # password cannot end up in a bg-backup stack trace or an `xtrace` log.
  if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
     | cut -d= -f1 | grep -qxE 'POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_DB|PGDATA|POSTGRESQL_PASSWORD'; then
    return 0
  fi
  if docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
     | grep -qx '5432/tcp'; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Streaming into restic
# -----------------------------------------------------------------------------
# _db_postgres_argv <job> <run-id> <stdin-filename> <extra-tag>
# Emits the restic argv, one entry per line, up to and including the `--`.
_db_postgres_argv() {
  local job="$1" run="$2" name="$3" tag="$4"
  restic_global_args
  printf 'backup\n'
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--json\n'
  printf -- '--stdin-from-command\n'
  printf -- '--stdin-filename\n%s\n' "${name}"
  restic_tag_args "${job}" "${run}" "kind=dbdump" "db=postgres" "${tag}" "${JOB_TAGS[@]:-}"
  printf -- '--\n'
}

# _db_postgres_run <job> <run-id> <stdin-filename> <extra-tag> -- <command...>
#
# Three deliberate choices, each preventing a specific silent corruption:
#
#   --stdin-from-command   restic runs the command itself and FAILS the backup
#                          when it exits non-zero. Piping into --stdin instead
#                          stores whatever bytes arrived before the dump died
#                          and reports success - a truncated dump indexed as a
#                          healthy snapshot, discovered only at restore.
#   timeout(1) in front    a dump blocked on a lock would otherwise run until
#                          systemd's JOB_TIMEOUT fires, long after the
#                          maintenance window closed. NOTE: `docker exec` does
#                          not forward the signal into the container, so the
#                          server-side query may survive; the backup still fails
#                          loudly, which is the point.
#   docker exec WITHOUT -t a pseudo-terminal performs newline translation and
#                          would corrupt every byte-exact dump (custom format,
#                          RDB, .bak) in a way that only surfaces at restore.
_db_postgres_run() {
  local job="$1" run="$2" name="$3" tag="$4"; shift 4
  [ "${1:-}" = "--" ] && shift

  local log rc=0
  log="$(tmp_file "db-postgres-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(_db_postgres_argv "${job}" "${run}" "${name}" "${tag}")
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$(( ${BGB_RUN_DB_DUMPS:-0} + 1 ))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  # rc=3 (some sources unreadable) is treated as a failure here on purpose:
  # there is exactly one source, and a partially read database dump is not a
  # database dump.
  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$(( ${BGB_RUN_DB_DUMPS_FAILED:-0} + 1 ))
    err "postgres: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi

  BGB_DB_LAST_SNAPSHOT=""
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "postgres: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
# db_postgres_dump <container> <job> <run-id>
db_postgres_dump() {
  local c="$1" job="$2" run="$3"
  local rc=0 worst=0 db safe counts="" script

  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  # 1. Cluster globals. First, and separately, so that a restore can replay them
  #    before any per-database dump that GRANTs to those roles.
  script="$(_db_postgres_script "${_DB_PG_GLOBALS_SH}")"
  if ! _db_postgres_run "${job}" "${run}" "/db/postgres/${c}/globals.sql" "kind=globals" \
       -- docker exec -i "${c}" sh -c "${script}" _; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="pg_dumpall --globals-only failed"
    return "${EX_FAIL}"
  fi

  # 2. Per-database dumps.
  local -a dbs=()
  script="$(_db_postgres_script "${_DB_PG_LIST_SH}")"
  mapfile -t dbs < <(_db_postgres_sh "${c}" "${script}" 2>/dev/null || true)
  if [ "${#dbs[@]}" -eq 0 ]; then
    warn "postgres: ${c}: could not list databases - only the globals were stored"
    BGB_DB_RESULT="degraded"
    BGB_DB_RESULT_REASON="database list unavailable"
    _db_postgres_degrade "postgres/${c}: database list unavailable, per-database dumps skipped"
    return "${EX_OK}"
  fi

  if [ "${JOB_DB_RECORD_COUNTS:-1}" = "1" ]; then
    counts="${_DB_POSTGRES_COUNTS_PATH}"
    # Truncate before the run, not after: a leftover file from a previous run
    # would be reported as this run's counts and quietly pass a verify that
    # should have failed.
    _db_postgres_sh "${c}" 'umask 077; : > "$1"' "${counts}" >/dev/null 2>&1 || counts=""
  fi

  script="$(_db_postgres_script "${_DB_PG_DUMP_SH}")"
  for db in "${dbs[@]}"; do
    [ -n "${db}" ] || continue
    safe="${db//[^A-Za-z0-9._-]/_}"
    rc=0
    _db_postgres_run "${job}" "${run}" "/db/postgres/${c}/${safe}.dump" "database=${safe}" \
      -- docker exec -i "${c}" sh -c "${script}" _ "${db}" "${counts}" || rc=$?
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  if [ "${worst}" -ne 0 ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="at least one per-database dump failed"
    return "${worst}"
  fi
  return "${EX_OK}"
}

_db_postgres_degrade() {
  local why="$1"
  warn "${why}"
  if [ -n "${BGB_RUN_DEGRADED_REASON:-}" ]; then
    BGB_RUN_DEGRADED_REASON="${BGB_RUN_DEGRADED_REASON}; ${why}"
  else
    BGB_RUN_DEGRADED_REASON="${why}"
  fi
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
# db_postgres_counts <container>
#
# Prefers the sidecar left behind by db_postgres_dump, because those numbers
# were taken inside the dump's own transaction snapshot and are therefore
# exactly what a restore of that snapshot must reproduce. Called standalone it
# falls back to a live pass, which is internally consistent but describes the
# database now rather than at dump time - reported as source="live" so a verify
# can decide how much to trust it.
db_postgres_counts() {
  local c="${1:-}" raw=""
  [ -n "${c}" ] || return 0
  have docker || return 0

  raw="$(_db_postgres_sh "${c}" 'cat "$1" 2>/dev/null || true; rm -f "$1" 2>/dev/null || true' \
    "${_DB_POSTGRES_COUNTS_PATH}" 2>/dev/null || true)"
  if [ -n "${raw}" ]; then
    printf '%s\n' "${raw}" | _db_postgres_counts_json "${c}" "dump-snapshot"
    return 0
  fi

  local -a dbs=() script
  script="$(_db_postgres_script "${_DB_PG_LIST_SH}")"
  mapfile -t dbs < <(_db_postgres_sh "${c}" "${script}" 2>/dev/null || true)
  [ "${#dbs[@]}" -gt 0 ] || return 0

  local db
  {
    for db in "${dbs[@]}"; do
      [ -n "${db}" ] || continue
      _db_postgres_sh "${c}" "$(_db_postgres_script "${_DB_PG_COUNTS_SH}")" "${db}" 2>/dev/null || true
    done
  } | _db_postgres_counts_json "${c}" "live"
}

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_PG_COUNTS_SH <<'EOS' || true
set -e
db="$1"
__CREDS__
psql -X -Atq -w -d "$db" -c "
  SELECT '$db' || '.' || n.nspname || '.' || c.relname || '|' ||
         (xpath('/row/c/text()', query_to_xml(
            format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
            false, true, '')))[1]::text
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE (c.relkind = 'p' OR (c.relkind = 'r' AND NOT c.relispartition))
     AND c.relpersistence = 'p'
     AND n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND n.nspname NOT LIKE 'pg_toast%'
   ORDER BY 1"
EOS

# Reads "object|count" lines on stdin and emits the counts document. Built with
# the json_* helpers rather than jq, so `verify` still works on a rescue system.
_db_postgres_counts_json() {
  local c="$1" src="$2" key val first=1
  printf '{'
  json_kv engine postgres; printf ','
  json_kv container "${c}"; printf ','
  json_kv taken "$(now_iso)"; printf ','
  json_kv source "${src}"; printf ','
  json_kvraw exact true; printf ','
  printf '"objects":{'
  while IFS='|' read -r key val; do
    [ -n "${key}" ] || continue
    [ "${first}" -eq 0 ] && printf ','
    json_kvraw "${key}" "$(json_num "${val}")"
    first=0
  done
  printf '}}\n'
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
# db_postgres_restore <container> <dump-file|-> [target-database]
#
# Format is detected from the file's magic ("PGDMP" = custom format), because
# feeding a custom-format dump to psql produces a wall of syntax errors and
# feeding plain SQL to pg_restore produces "input file does not appear to be a
# valid archive" - both after the operator has already dropped the old database.
db_postgres_restore() {
  local c="${1:-}" src="${2:--}" target="${3:-postgres}"
  [ -n "${c}" ] || die "${EX_USAGE}" "db_postgres_restore: container is required"
  require_cmd docker

  local fmt="${BGB_DB_RESTORE_FORMAT:-auto}" file="${src}"
  if [ "${src}" = "-" ] && [ "${fmt}" = "auto" ]; then
    # Peeking at a pipe is not possible without consuming it, and consuming a
    # binary header in bash is not possible at all (NUL bytes). Spooling is the
    # honest answer; set BGB_DB_RESTORE_FORMAT=sql|custom to skip it.
    file="$(tmp_file "pgrestore-XXXXXX")"
    warn "postgres: spooling the dump to ${file} to detect its format"
    cat >"${file}"
  fi

  if [ "${fmt}" = "auto" ]; then
    if [ "$(head -c 5 "${file}" 2>/dev/null || true)" = "PGDMP" ]; then fmt="custom"; else fmt="sql"; fi
  fi

  local script rc=0
  case "${fmt}" in
    custom)
      log "postgres: pg_restore into ${c}:${target}"
      # --exit-on-error is the difference between a restore that failed and a
      # restore you believe worked: without it pg_restore prints errors, skips
      # the objects it could not create, and exits 0.
      script="$(_db_postgres_script "${_DB_PG_RESTORE_CUSTOM_SH}")"
      if [ "${file}" = "-" ]; then
        docker exec -i "${c}" sh -c "${script}" _ "${target}" || rc=$?
      else
        docker exec -i "${c}" sh -c "${script}" _ "${target}" <"${file}" || rc=$?
      fi ;;
    sql)
      log "postgres: psql into ${c}:${target}"
      script="$(_db_postgres_script "${_DB_PG_RESTORE_SQL_SH}")"
      if [ "${file}" = "-" ]; then
        docker exec -i "${c}" sh -c "${script}" _ "${target}" || rc=$?
      else
        docker exec -i "${c}" sh -c "${script}" _ "${target}" <"${file}" || rc=$?
      fi ;;
    *)
      die "${EX_USAGE}" "postgres: unknown BGB_DB_RESTORE_FORMAT '${fmt}' (sql|custom|auto)" ;;
  esac

  [ "${rc}" -eq 0 ] || err "postgres: restore failed (rc=${rc})"
  return "${rc}"
}

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_PG_RESTORE_CUSTOM_SH <<'EOS' || true
set -e
db="$1"
__CREDS__
exec pg_restore --no-password --exit-on-error --clean --if-exists -d "$db"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_PG_RESTORE_SQL_SH <<'EOS' || true
set -e
db="$1"
__CREDS__
# ON_ERROR_STOP=1 for the same reason pg_restore gets --exit-on-error: psql
# defaults to reporting every error and then exiting 0.
exec psql -X -w -v ON_ERROR_STOP=1 -d "$db" -f -
EOS

# -----------------------------------------------------------------------------
# Health probe
# -----------------------------------------------------------------------------
# db_postgres_verify_cmd <container> - argv, one entry per line.
# pg_isready needs no password and no query planning; it is the cheapest proof
# that the server is up and accepting connections.
db_postgres_verify_cmd() {
  local c="${1:-}"
  printf 'docker\nexec\n%s\nsh\n-c\n' "${c}"
  printf '%s\n' 'exec pg_isready -q -U "${POSTGRES_USER:-${POSTGRESQL_USERNAME:-postgres}}"'
}

# -----------------------------------------------------------------------------
# Operator notes
# -----------------------------------------------------------------------------
db_postgres_notes() {
  cat <<'EOF'
PostgreSQL is dumped logically: one plain-SQL stream of the cluster globals
(roles, role passwords, tablespaces, per-role settings) plus one custom-format
pg_dump per database, each streamed straight into restic with
--stdin-from-command so a failing dump fails the backup instead of storing a
truncated file. Custom-format dumps are written with --compress=0 on purpose:
restic compresses anyway, and an uncompressed dump deduplicates across days
while a zlib stream does not. Row counts are taken inside the same exported
transaction snapshot that pg_dump reads, so `verify` compares a restored
database against numbers that were true at the exact instant of the dump; this
needs PostgreSQL 10 or newer. Restore order is fixed and unforgiving: globals
first (otherwise every GRANT fails and no role can log in), then each database
with pg_restore --exit-on-error. Large objects are included in the per-database
dumps. What is NOT covered: physical replication slots, WAL archives and
point-in-time recovery - if you need PITR, keep pgBackRest or WAL-G alongside
this and treat these dumps as the offsite fallback.
EOF
}
