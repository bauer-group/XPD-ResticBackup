#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: InfluxDB
# =============================================================================
# Three incompatible generations share one name, and picking the wrong tool
# produces an archive that restores into nothing:
#
#   1.x   `influxd backup -portable`   writes a DIRECTORY, not a stream
#   2.x   `influx backup`              writes a DIRECTORY, needs an auth token
#   3.x   no logical dump exists at all
#
# Neither 1.x nor 2.x can write to stdout, so the dump is created inside the
# container and then tarred to stdout in one command - the tar is what restic
# receives, and a failure anywhere in the chain still fails the command, which
# is what --stdin-from-command needs.
#
# For 3.x this module REFUSES rather than storing something that looks like a
# backup. Pretending is worse than an honest error: an operator who is told
# "unsupported" makes a decision, one who sees a green backup makes none.
# =============================================================================

[ -n "${_BGB_DB_INFLUXDB_SOURCED:-}" ] && return 0
_BGB_DB_INFLUXDB_SOURCED=1

db_influxdb_aliases() { printf 'influx\ninfluxdb2\n'; }

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
db_influxdb_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  # Telegraf ships in the same family and is not a database.
  case "${image}" in
    *telegraf*|*chronograf*|*kapacitor*|*exporter*) return 1 ;;
  esac
  case "${image}" in *influx*) : ;; *) return 1 ;; esac

  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
    | cut -d= -f1 | grep -qxE 'INFLUXDB_DB|INFLUXD_.*|DOCKER_INFLUXDB_INIT_MODE|INFLUX_TOKEN' && return 0
  docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
    | grep -qxE '8086/tcp|8181/tcp' && return 0
  return 1
}

# db_influxdb_major <container> - 1, 2, 3, or empty when undetermined.
db_influxdb_major() {
  local c="$1" v
  # `influx version` speaks for the client, `influxd version` for the server.
  v="$(docker exec "${c}" sh -c 'influxd version 2>/dev/null || influx version 2>/dev/null' 2>/dev/null | head -n1)"
  case "${v}" in
    *' 1.'*|*'v1.'*) printf '1' ; return 0 ;;
    *' 2.'*|*'v2.'*) printf '2' ; return 0 ;;
    *' 3.'*|*'v3.'*) printf '3' ; return 0 ;;
  esac
  # Fall back to the image tag, which is right often enough to be useful and is
  # reported to the operator either way.
  local image
  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  case "${image}" in
    *:1*|*1.[0-9]*) printf '1' ;;
    *:2*|*2.[0-9]*) printf '2' ;;
    *:3*|*3.[0-9]*) printf '3' ;;
    *) printf '' ;;
  esac
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
_db_influxdb_run() {
  local job="$1" run="$2" name="$3" tag="$4"; shift 4
  [ "${1:-}" = "--" ] && shift

  local log rc=0
  log="$(tmp_file "db-influxdb-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(
    restic_global_args
    printf 'backup\n'
    printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
    printf -- '--json\n'
    printf -- '--stdin-from-command\n'
    printf -- '--stdin-filename\n%s\n' "${name}"
    restic_tag_args "${job}" "${run}" "kind=dbdump" "db=influxdb" "${tag}" "${JOB_TAGS[@]:-}"
    printf -- '--\n'
  )
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$(( ${BGB_RUN_DB_DUMPS:-0} + 1 ))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$(( ${BGB_RUN_DB_DUMPS_FAILED:-0} + 1 ))
    err "influxdb: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi
  BGB_DB_LAST_SNAPSHOT=""
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "influxdb: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

# The dump runs entirely inside the container: create a temp directory, write
# the backup into it, tar it to stdout, and remove it on exit. `set -e` inside
# means any failing step aborts the pipeline, so restic sees a non-zero exit and
# discards the snapshot instead of storing a partial tar.
# shellcheck disable=SC2016
_DB_INFLUX_V1_SH='
set -e
d=$(mktemp -d)
trap "rm -rf \"$d\"" EXIT
influxd backup -portable "$d" >/dev/null 2>&1
tar -C "$d" -cf - .
'

# shellcheck disable=SC2016
_DB_INFLUX_V2_SH='
set -e
d=$(mktemp -d)
trap "rm -rf \"$d\"" EXIT
token="${DOCKER_INFLUXDB_INIT_ADMIN_TOKEN:-${INFLUX_TOKEN:-}}"
if [ -n "$token" ]; then
  influx backup "$d" --token "$token" >/dev/null 2>&1
else
  influx backup "$d" >/dev/null 2>&1
fi
tar -C "$d" -cf - .
'

db_influxdb_dump() {
  local c="$1" job="$2" run="$3"
  local major
  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  major="$(db_influxdb_major "${c}")"

  case "${major}" in
    1)
      _db_influxdb_run "${job}" "${run}" "/db/influxdb/${c}/backup-v1.tar" "influx_major=1" \
        -- docker exec -i "${c}" sh -c "${_DB_INFLUX_V1_SH}" || {
          BGB_DB_RESULT="failed"
          BGB_DB_RESULT_REASON="influxd backup -portable failed"
          return "${EX_FAIL}"
        } ;;
    2)
      _db_influxdb_run "${job}" "${run}" "/db/influxdb/${c}/backup-v2.tar" "influx_major=2" \
        -- docker exec -i "${c}" sh -c "${_DB_INFLUX_V2_SH}" || {
          BGB_DB_RESULT="failed"
          BGB_DB_RESULT_REASON="influx backup failed (is the admin token available in the container?)"
          return "${EX_FAIL}"
        } ;;
    3)
      # Deliberate refusal. InfluxDB 3 stores Parquet in object storage and has
      # no logical dump; the correct backup is a snapshot of that object store,
      # which is not this tool's job to fake.
      err "influxdb: ${c} is InfluxDB 3.x, which has no logical dump command."
      err "  Back up its object store directly, or move the workload."
      err "  Set the label ${BGB_DB_LABEL_NS}/skip=true once that is arranged."
      BGB_DB_RESULT="failed"
      BGB_DB_RESULT_REASON="InfluxDB 3.x has no logical dump - back up the object store instead"
      return "${EX_FAIL}" ;;
    *)
      err "influxdb: could not determine the major version of ${c}"
      BGB_DB_RESULT="failed"
      BGB_DB_RESULT_REASON="version detection failed"
      return "${EX_FAIL}" ;;
  esac
  return "${EX_OK}"
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
# Series cardinality is the closest thing to a row count InfluxDB offers that is
# cheap enough to take on every backup.
db_influxdb_counts() {
  local c="$1" major out
  major="$(db_influxdb_major "${c}")"
  case "${major}" in
    1)
      out="$(docker exec -i "${c}" sh -c \
        'influx -execute "SHOW DATABASES" -format csv 2>/dev/null | tail -n +2 | cut -d, -f2' 2>/dev/null || true)"
      [ -n "${out}" ] || return 0
      printf '{'
      local first=1 db
      while IFS= read -r db; do
        [ -n "${db}" ] || continue
        [ "${first}" -eq 0 ] && printf ','
        first=0
        printf '%s:1' "$(json_str "${db}")"
      done <<<"${out}"
      printf '}' ;;
    2)
      out="$(docker exec -i "${c}" sh -c \
        'influx bucket list --hide-headers 2>/dev/null | wc -l' 2>/dev/null || true)"
      [ -n "${out}" ] || return 0
      printf '{"buckets":%s}' "$(json_num "${out}")" ;;
    *) return 0 ;;
  esac
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
# Reads the tar on stdin, unpacks it inside the container, and restores from it.
db_influxdb_restore() {
  local c="$1"
  require_cmd docker
  local major; major="$(db_influxdb_major "${c}")"
  case "${major}" in
    1)  docker exec -i "${c}" sh -c '
          set -e
          d=$(mktemp -d); trap "rm -rf \"$d\"" EXIT
          tar -C "$d" -xf -
          influxd restore -portable "$d"
        ' ;;
    2)  docker exec -i "${c}" sh -c '
          set -e
          d=$(mktemp -d); trap "rm -rf \"$d\"" EXIT
          tar -C "$d" -xf -
          token="${DOCKER_INFLUXDB_INIT_ADMIN_TOKEN:-${INFLUX_TOKEN:-}}"
          if [ -n "$token" ]; then influx restore "$d" --full --token "$token"
          else influx restore "$d" --full; fi
        ' ;;
    *)  err "influxdb: cannot restore into major version '${major:-unknown}'"
        return "${EX_PRECOND}" ;;
  esac
}

db_influxdb_verify_cmd() {
  local c="$1"
  docker exec "${c}" sh -c \
    'influx ping >/dev/null 2>&1 || curl -sf http://localhost:8086/health >/dev/null 2>&1' \
    >/dev/null 2>&1
}

db_influxdb_notes() {
  cat <<'EOF'
1.x: influxd backup -portable, tarred to stdout. 2.x: influx backup, needs the
admin token from the container's own environment. 3.x is refused - it has no
logical dump; back up its object store instead.
EOF
}
