#!/usr/bin/env bash
# =============================================================================
# bg-backup - db: detect database containers and dump them consistently
# =============================================================================
# The dispatcher. Engine specifics live in share/db/<engine>.sh, one file per
# engine, so adding support for a new one is a new file and a line in
# BGB_DB_ENGINES_KNOWN - never an edit to the orchestration.
#
# THE CENTRAL RULE, and the reason this file exists at all:
#
#     restic backup --stdin-from-command -- docker exec -i <c> <dump>
#
# `--stdin-from-command` makes restic fail the whole backup when the dump
# command exits non-zero. The obvious alternative,
#
#     docker exec ... pg_dumpall | restic backup --stdin
#
# stores whatever bytes arrived before the failure as a perfectly valid snapshot
# and reports success. A backup system that can silently record a truncated
# database dump as healthy is worse than no backup system, because it also
# removes the pressure to have one.
#
# Second rule: dumps are NEVER pre-compressed. restic compresses already
# (repository format v2), and a plain SQL stream deduplicates across days at
# content-defined chunk boundaries, while a gzip stream changes wholesale after
# the first differing byte.
# =============================================================================

[ -n "${_BGB_DB_SOURCED:-}" ] && return 0
_BGB_DB_SOURCED=1

# Order matters: the first engine whose detector matches wins, so a more
# specific engine must come before a more general one. MariaDB and Percona are
# NOT listed separately - share/db/mysql.sh handles all three and declares them
# through db_mysql_aliases.
#
# sqlite is last on purpose: it is detected by finding database FILES, which is
# a weaker signal than an image name plus an exposed port, and a container
# running Postgres may also happen to contain a stray .sqlite file.
readonly BGB_DB_ENGINES_KNOWN="postgres mysql mongodb redis influxdb clickhouse elasticsearch mssql sqlite"

# The result protocol every engine module speaks. Set by the engine, read here.
#   BGB_DB_RESULT         ok | degraded | failed | skipped
#   BGB_DB_RESULT_REASON  free text, shown to the operator and put into state
#   BGB_DB_LAST_LOG       path to the engine's own log for this attempt
#   BGB_DB_LAST_SNAPSHOT  the restic snapshot the dump landed in
BGB_DB_RESULT=""
BGB_DB_RESULT_REASON=""
BGB_DB_LAST_LOG=""
BGB_DB_LAST_SNAPSHOT=""

db_result_reset() {
  BGB_DB_RESULT=""
  BGB_DB_RESULT_REASON=""
  BGB_DB_LAST_LOG=""
  BGB_DB_LAST_SNAPSHOT=""
}

# Container label namespace for operator overrides.
readonly BGB_DB_LABEL_NS="backup.bauer-group.com"

_BGB_DB_LOADED_ENGINES=()

db_load_engine() {
  local engine="$1" f e
  for e in "${_BGB_DB_LOADED_ENGINES[@]:-}"; do
    [ "${e}" = "${engine}" ] && return 0
  done

  local file
  file="$(db_engine_module "${engine}")"
  f="${BGB_SHARE_DIR}/db/${file}.sh"
  [ -r "${f}" ] || {
    debug "No engine module for '${engine}' at ${f}"
    return 1
  }
  # shellcheck source=/dev/null
  . "${f}"
  _BGB_DB_LOADED_ENGINES+=("${engine}")
  return 0
}

# db_engine_canonical <name> - the engine an alias refers to.
#
# EVERY alias any module advertises must appear here. This table used to hold
# only mariadb/percona and opensearch, while the modules declared thirteen more
# through their db_<engine>_aliases() functions. The consequence was not a
# missing feature but a silent one: a container carrying the documented
# `backup.bauer-group.com/engine=postgresql` label loaded postgres.sh correctly
# (the module lookup happened to be forgiving) and then looked for a function
# called db_postgresql_dump, which does not exist. The target was skipped with a
# warning, counted as neither attempted nor failed, and the run finished green
# with that database absent from the backup.
#
# The module file is named after the canonical engine, so this is also the
# module lookup. tests/unit/regressions.bats asserts that every alias every
# module declares canonicalises back to that module - the table cannot drift
# away from the modules without a test failing.
db_engine_canonical() {
  case "$1" in
    postgresql | pgsql | timescaledb) printf 'postgres' ;;
    mariadb | percona) printf 'mysql' ;;
    mongo) printf 'mongodb' ;;
    valkey | keydb) printf 'redis' ;;
    influx | influxdb2) printf 'influxdb' ;;
    ch | clickhouse-server) printf 'clickhouse' ;;
    opensearch | elastic | es) printf 'elasticsearch' ;;
    sqlserver | mssqlserver) printf 'mssql' ;;
    sqlite3) printf 'sqlite' ;;
    *) printf '%s' "$1" ;;
  esac
}

db_engine_module() { db_engine_canonical "$1"; }

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
# db_container_label <container> <key>
db_container_label() {
  docker inspect "$1" 2>/dev/null \
    | jq -r --arg k "${BGB_DB_LABEL_NS}/$2" '.[0].Config.Labels[$k] // empty' 2>/dev/null || true
}

# db_detect <container> - echo the engine name, or nothing.
#
# Precedence:
#   1. an explicit container label      - the operator always wins
#   2. the engine modules' own detectors - image name, then env/port confirmation
#
# Never guess from the container NAME. A container called "postgres-backup"
# running alpine is not a database, and treating it as one produces a failing
# dump every night that somebody eventually silences.
db_detect() {
  local c="$1" engine

  engine="$(db_container_label "${c}" engine)"
  if [ -n "${engine}" ]; then
    printf '%s' "${engine}"
    return 0
  fi

  for engine in ${BGB_DB_ENGINES_KNOWN}; do
    db_load_engine "${engine}" || continue
    local fn="db_${engine}_detect"
    declare -F "${fn}" >/dev/null 2>&1 || continue
    if "${fn}" "${c}" 2>/dev/null; then
      printf '%s' "${engine}"
      return 0
    fi
  done
  return 1
}

# db_engine_enabled <engine> - is this engine in the job's JOB_DB_ENGINES list?
db_engine_enabled() {
  local engine="$1" e
  # Compare CANONICAL names on both sides. This used to special-case exactly one
  # pair, mysql/mariadb, so an operator who wrote JOB_DB_ENGINES=( postgresql )
  # or labelled a container engine=valkey had that target silently dropped from
  # the plan - the same alias blindness as the dispatch, one step earlier.
  local want
  want="$(db_engine_canonical "${engine}")"
  for e in "${JOB_DB_ENGINES[@]:-}"; do
    [ -n "${e}" ] || continue
    [ "$(db_engine_canonical "${e}")" = "${want}" ] && return 0
  done
  return 1
}

db_container_excluded() {
  local c="$1" name x
  name="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Name // ""' | sed 's|^/||')"
  [ "$(db_container_label "${c}" skip)" = "true" ] && return 0
  for x in "${JOB_DB_EXCLUDE_CONTAINERS[@]:-}"; do
    [ "${x}" = "${name}" ] && return 0
    [ "${x}" = "${c:0:12}" ] && return 0
  done
  return 1
}

db_container_name() {
  docker inspect "$1" 2>/dev/null | jq -r '.[0].Name // ""' 2>/dev/null | sed 's|^/||'
}

db_container_tier() {
  local t
  t="$(db_container_label "$1" tier)"
  printf '%s' "${t:-standard}"
}

# -----------------------------------------------------------------------------
# Planning
# -----------------------------------------------------------------------------
# db_plan - one "container-id<TAB>name<TAB>engine<TAB>tier" line per target.
# Exposed separately so `discover` can show the plan without running it.
db_plan() {
  local c engine name tier
  while IFS= read -r c; do
    [ -n "${c}" ] || continue
    db_container_excluded "${c}" && {
      debug "Excluded: $(db_container_name "${c}")"
      continue
    }
    engine="$(db_detect "${c}")" || continue
    db_engine_enabled "${engine}" || {
      debug "Engine '${engine}' not enabled for this job"
      continue
    }
    name="$(db_container_name "${c}")"
    tier="$(db_container_tier "${c}")"
    printf '%s\t%s\t%s\t%s\n' "${c}" "${name}" "${engine}" "${tier}"
  done < <(docker ps -q 2>/dev/null || true)
}

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------
db_dump_all() {
  local job="$1" run_id="$2"
  local c name engine tier rc=0 worst=0 count=0 failed=0

  local -a plan=()
  mapfile -t plan < <(db_plan)

  if [ "${#plan[@]}" -eq 0 ]; then
    log "No database containers detected"
    return 0
  fi

  log "Database targets: ${#plan[@]}"

  local line
  for line in "${plan[@]}"; do
    IFS=$'\t' read -r c name engine tier <<<"${line}"
    [ -n "${c}" ] || continue

    # Canonicalise BEFORE building the function name. An alias such as
    # "postgresql" or "mariadb" - both documented as valid values of the
    # backup.bauer-group.com/engine label - loaded the right module and then
    # looked for db_postgresql_dump, which does not exist.
    local ceng
    ceng="$(db_engine_canonical "${engine}")"

    # A target we were ASKED to dump and cannot is a FAILURE, not a skip. Both
    # branches below used to `continue` before count was incremented, so the
    # container contributed to neither the attempted nor the failed tally: the
    # run reported "0 attempted, 0 failed" and exited 0 with that database
    # missing from the backup. `skipped` is for a target we deliberately do not
    # dump (a Redis used purely as a cache); this is not that.
    count=$((count + 1))

    if ! db_load_engine "${ceng}"; then
      err "No engine module for '${engine}' (container ${name}) - NOT backed up"
      failed=$((failed + 1))
      worst="$(worst_rc "${worst}" "${EX_FAIL}")"
      continue
    fi

    local fn="db_${ceng}_dump"
    if ! declare -F "${fn}" >/dev/null 2>&1; then
      err "Engine '${engine}' (module ${ceng}) provides no dump function - '${name}' was NOT backed up"
      failed=$((failed + 1))
      worst="$(worst_rc "${worst}" "${EX_FAIL}")"
      continue
    fi

    log "Dumping ${ceng} from container '${name}' (tier=${tier})"
    rc=0
    db_result_reset

    # A per-target timeout so one wedged database cannot hold the whole run -
    # and, more importantly, cannot hold a quiesce window open while it hangs.
    #
    # NOTE: the engine runs in THIS shell, not behind `timeout`, because the
    # result protocol (BGB_DB_RESULT and friends) is carried in variables and a
    # subprocess could not set them. The timeout is enforced inside the engine's
    # own restic invocation instead, and JOB_QUIESCE_MAX_SECONDS is the backstop.
    # THE NAME, not the short ID. Every engine embeds whatever it is given into
    # the dump path (/db/<engine>/<this>/<file>) and into the container= tag,
    # and dr.sh and verify.sh parse that segment back out as a container NAME.
    # Handing them the ID produced /db/postgres/d9c310526af8/shopdb.dump, so a
    # recovery looking for the dump of "shop-db-1" found nothing - and the ID
    # changes on every `compose up --force-recreate`, so yesterday's path is
    # meaningless today. `docker exec` accepts a name just as well as an ID, so
    # the engines need no change.
    #
    # Falls back to the ID only if the name could not be resolved, which means
    # docker inspect failed - better a wrong-shaped path than no dump.
    "${fn}" "${name:-${c}}" "${job}" "${run_id}" || rc=$?

    # An engine that speaks the result protocol wins over the raw exit code: it
    # can distinguish "dumped, but MyISAM tables mean this is not a consistent
    # dump" from "dumped fine", which an exit code cannot express.
    local outcome="${BGB_DB_RESULT:-}"
    if [ -z "${outcome}" ]; then
      case "${rc}" in
        0) outcome="ok" ;;
        124 | 137)
          outcome="failed"
          BGB_DB_RESULT_REASON="timed out after ${JOB_DB_DUMP_TIMEOUT}s"
          ;;
        *)
          outcome="failed"
          BGB_DB_RESULT_REASON="dump command exited ${rc}"
          ;;
      esac
    fi

    case "${outcome}" in
      ok)
        debug "Dump of '${name}' succeeded"
        [ -n "${BGB_DB_LAST_SNAPSHOT}" ] && debug "snapshot ${BGB_DB_LAST_SNAPSHOT}"
        db_record_counts "${name:-${c}}" "${ceng}" "${name}" "${job}" "${run_id}" || true
        ;;
      skipped)
        log "Skipped '${name}': ${BGB_DB_RESULT_REASON:-no reason given}"
        count=$((count - 1))
        ;;
      degraded)
        # The dump exists but its consistency is not guaranteed. Reported, never
        # swallowed: a snapshot whose consistency is unknown is exactly the
        # silent state this tool exists to eliminate.
        db_mark_degraded "${name} (${engine}): ${BGB_DB_RESULT_REASON:-consistency not guaranteed}"
        db_record_counts "${name:-${c}}" "${ceng}" "${name}" "${job}" "${run_id}" || true
        ;;
      *)
        err "Dump of '${name}' FAILED: ${BGB_DB_RESULT_REASON:-rc=${rc}}"
        [ -n "${BGB_DB_LAST_LOG}" ] && err "  see ${BGB_DB_LAST_LOG}"
        failed=$((failed + 1))
        # Critical tier or not, a failed dump fails the run. The tier only
        # changes how loudly it is reported, not whether it counts: a backup
        # that quietly lost one database is the failure mode with the longest
        # discovery time.
        if [ "${tier}" = "critical" ]; then
          err "  tier=critical - this alone fails the backup"
        else
          BGB_RUN_DEGRADED_REASON="dump failed for ${name} (${engine})"
        fi
        worst="$(worst_rc "${worst}" "${EX_FAIL}")"
        ;;
    esac
  done

  BGB_RUN_DB_DUMPS="${count}"
  BGB_RUN_DB_DUMPS_FAILED="${failed}"
  log "Database dumps: ${count} attempted, ${failed} failed"
  return "${worst}"
}

# db_record_counts - capture per-object row counts next to the dump so `verify`
# can assert them after a test restore. Without these, a restore test can only
# prove "the dump loaded", not "the dump contained the data".
db_record_counts() {
  local c="$1" engine="$2" name="$3" job="$4" run_id="$5"
  [ "${JOB_DB_RECORD_COUNTS}" = "1" ] || return 0

  # Canonicalise here too: with an alias such as "postgresql" this looked for
  # db_postgresql_counts, found nothing and returned silently - so verify had no
  # row counts to compare a restored database against, and its restore test
  # degraded to "the dump loads" without anyone being told.
  local ceng fn
  ceng="$(db_engine_canonical "${engine}")"
  fn="db_${ceng}_counts"
  declare -F "${fn}" >/dev/null 2>&1 || return 0

  local counts
  counts="$("${fn}" "${c}" 2>/dev/null || true)"
  [ -n "${counts}" ] || return 0

  local out="/var/lib/bg-backup/facts/db-counts-${name}.json"
  install -d -m 0700 /var/lib/bg-backup/facts
  {
    printf '{'
    json_kv container "${name}"
    printf ','
    json_kv engine "${engine}"
    printf ','
    json_kv run_id "${run_id}"
    printf ','
    json_kv captured "$(now_iso)"
    printf ','
    json_kvraw counts "${counts}"
    printf '}\n'
  } | atomic_write "${out}" 0600
  debug "Recorded object counts for ${name}"
}

# -----------------------------------------------------------------------------
# Helper used by every engine module
# -----------------------------------------------------------------------------
# db_stream_dump <container> <job> <run-id> <engine> <filename> <command...>
#
# The single place that builds the restic invocation, so no engine module can
# accidentally use --stdin instead of --stdin-from-command.
db_stream_dump() {
  local container="$1" job="$2" run_id="$3" engine="$4" filename="$5"
  shift 5
  local name
  name="$(db_container_name "${container}")"

  local -a args=(
    backup
    --stdin-from-command
    --stdin-filename "/db/${engine}/${name}/${filename}"
    --host "${BGB_HOSTNAME}"
    --tag "bg-backup=1"
    --tag "job=${job}"
    --tag "run=${run_id}"
    --tag "kind=dbdump"
    --tag "engine=${engine}"
    --tag "container=${name}"
  )
  local t
  for t in "${JOB_TAGS[@]:-}"; do
    [ -n "${t}" ] && args+=(--tag "${t}")
  done
  args+=(--)
  args+=("$@")

  restic_exec_logged "${BGB_JOB_LOG:-/dev/null}" "${args[@]}"
}

# db_exec <container> <shell-command>
# Runs a command inside the container with `sh -c`, so the container's own
# environment (POSTGRES_USER, MYSQL_ROOT_PASSWORD, ...) can be referenced. That
# is deliberate: it means bg-backup never has to store a database credential.
db_exec() {
  local c="$1"
  shift
  docker exec -i "${c}" sh -c "$*"
}

db_exec_quiet() {
  local c="$1"
  shift
  docker exec -i "${c}" sh -c "$*" 2>/dev/null
}

# db_has_binary <container> <binary>
db_has_binary() {
  docker exec "$1" sh -c "command -v $2 >/dev/null 2>&1" >/dev/null 2>&1
}

# db_image_matches <container> <regex>
db_image_matches() {
  local c="$1" re="$2" img
  img="$(docker inspect "${c}" 2>/dev/null | jq -r '.[0].Config.Image // ""')"
  printf '%s' "${img}" | grep -qiE "${re}"
}

# db_has_env <container> <VAR>
db_has_env() {
  local c="$1" var="$2"
  docker inspect "${c}" 2>/dev/null \
    | jq -e --arg v "${var}=" '.[0].Config.Env[]? | select(startswith($v))' >/dev/null 2>&1
}

# db_mark_degraded <reason>
# Used by engine modules when a dump succeeded but cannot be called consistent -
# MyISAM tables under --single-transaction, a standalone MongoDB without an
# oplog. The run is reported as degraded rather than green, because "a snapshot
# exists but its consistency is unknown" is exactly the state that erodes trust
# in a backup system when it is discovered during a restore instead of now.
db_mark_degraded() {
  local reason="$1"
  warn "DEGRADED: ${reason}"
  if [ -n "${BGB_RUN_DEGRADED_REASON}" ]; then
    BGB_RUN_DEGRADED_REASON="${BGB_RUN_DEGRADED_REASON}; ${reason}"
  else
    BGB_RUN_DEGRADED_REASON="${reason}"
  fi
}
