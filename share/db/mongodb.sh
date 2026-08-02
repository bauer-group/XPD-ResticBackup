#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: MongoDB
# =============================================================================
# mongodump --archive --oplog, streamed straight into restic.
#
# WHY --oplog, AND WHY IT IS NOT ALWAYS AVAILABLE.
#
#   mongodump without --oplog walks the collections one at a time. On a busy
#   server, writes that happen while it is walking land in some collections and
#   not in others: the archive contains an order that never existed. A document
#   can reference a parent that is missing, a two-phase commit can be half
#   applied, and nothing about the archive looks wrong.
#
#   --oplog fixes that by recording the oplog entries generated during the dump
#   and replaying them at restore, producing a true point-in-time snapshot. It
#   requires the oplog, and the oplog only exists on a replica set.
#
#   A standalone mongod has no oplog. mongodump --oplog against one fails
#   outright ("Mongodump only supports the --oplog option when running against a
#   replica set member"). bg-backup therefore detects the topology, drops the
#   flag on a standalone, and reports the run as DEGRADED - because the archive
#   it produced is genuinely weaker than the one it produces elsewhere, and the
#   operator deserves to know before they need it.
#
#   The fix for a single-node deployment is one line of compose
#   (`command: ["--replSet","rs0"]` plus a one-off rs.initiate()), which turns a
#   crash-inconsistent dump into a point-in-time one. That is worth saying out
#   loud in the alert, so db_mongodb_notes says it.
#
# CREDENTIALS: mongodump has no password environment variable, so the password
# would end up in argv - readable in /proc/<pid>/cmdline by every user on the
# host. Instead the container's own shell writes a 0600 YAML file containing
# only `password:` and passes it with --config; the mongo shell reads the same
# credentials back out of a 0600 file with cat(), so nothing is interpolated
# into JavaScript either.
# =============================================================================

[ -n "${_BGB_DB_MONGODB_SOURCED:-}" ] && return 0
_BGB_DB_MONGODB_SOURCED=1

db_mongodb_aliases() { printf 'mongo\n'; }

# -----------------------------------------------------------------------------
# Container scripts
# -----------------------------------------------------------------------------

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MG_CREDS_SH <<'EOS' || true
MG_USER="${MONGO_INITDB_ROOT_USERNAME:-${MONGODB_ROOT_USER:-${MONGODB_USERNAME:-}}}"
MG_PASS="${MONGO_INITDB_ROOT_PASSWORD:-${MONGODB_ROOT_PASSWORD:-${MONGODB_PASSWORD:-}}}"
MG_AUTHDB="${BGB_MONGO_AUTH_DB:-admin}"
umask 077
MG_DIR=$(mktemp -d)
trap 'rm -rf "$MG_DIR"' EXIT INT TERM
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MG_DUMP_SH <<'EOS' || true
set -e
oplog="$1"
__CREDS__
set -- --archive
if [ -n "$oplog" ]; then set -- "$@" --oplog; fi
if [ -n "$MG_PASS" ]; then
  printf 'password: %s\n' "$MG_PASS" >"$MG_DIR/mongodump.yaml"
  set -- "$@" --username "$MG_USER" --authenticationDatabase "$MG_AUTHDB" --config "$MG_DIR/mongodump.yaml"
fi
# --archive with no value writes the archive to stdout; progress goes to stderr.
mongodump "$@"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MG_EVAL_SH <<'EOS' || true
set -e
js="$1"
__CREDS__
if command -v mongosh >/dev/null 2>&1; then CLI=mongosh; else CLI=mongo; fi
pre=""
if [ -n "$MG_PASS" ]; then
  # Credentials go into a file and are read back with cat() inside the shell.
  # Interpolating them into the --eval string would put them in argv, and
  # escaping them into a JavaScript literal is a quoting bug waiting to happen.
  printf '%s\n%s\n' "$MG_USER" "$MG_PASS" >"$MG_DIR/c"
  pre="var _c=cat('$MG_DIR/c').split('\n'); db.getSiblingDB('$MG_AUTHDB').auth(_c[0],_c[1]);"
fi
exec "$CLI" --quiet --eval "$pre $js" "127.0.0.1:27017/$MG_AUTHDB"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_MG_RESTORE_SH <<'EOS' || true
set -e
oplog="$1"; drop="$2"
__CREDS__
set -- --archive
if [ -n "$oplog" ]; then set -- "$@" --oplogReplay; fi
if [ -n "$drop" ];  then set -- "$@" --drop; fi
if [ -n "$MG_PASS" ]; then
  printf 'password: %s\n' "$MG_PASS" >"$MG_DIR/mongorestore.yaml"
  set -- "$@" --username "$MG_USER" --authenticationDatabase "$MG_AUTHDB" --config "$MG_DIR/mongorestore.yaml"
fi
mongorestore "$@"
EOS

_db_mongodb_script() {
  # See _db_mysql_script: a substitution's replacement is backslash-processed,
  # so splicing shell code through it silently corrupts every escape in it.
  str_replace_all "$1" '__CREDS__' "${_DB_MG_CREDS_SH}"
}

# _db_mongodb_eval <container> <javascript>
_db_mongodb_eval() {
  local c="$1" js="$2"
  docker exec -i "${c}" sh -c "$(_db_mongodb_script "${_DB_MG_EVAL_SH}")" _ "${js}" 2>/dev/null
}

_db_mongodb_degrade() {
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
db_mongodb_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  case "${image}" in
    *exporter*|*mongo-express*|*mongoexpress*|*mongos*|*compass*) return 1 ;;
  esac
  case "${image}" in
    *mongo*|*documentdb*|*ferretdb*) : ;;
    *) return 1 ;;
  esac

  if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
     | cut -d= -f1 \
     | grep -qxE 'MONGO_INITDB_ROOT_USERNAME|MONGO_INITDB_ROOT_PASSWORD|MONGO_INITDB_DATABASE|MONGODB_ROOT_PASSWORD|MONGODB_REPLICA_SET_NAME'; then
    return 0
  fi
  if docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
     | grep -qx '27017/tcp'; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Streaming into restic
# -----------------------------------------------------------------------------
_db_mongodb_argv() {
  local job="$1" run="$2" name="$3" tag="$4"
  restic_global_args
  printf 'backup\n'
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--json\n'
  printf -- '--stdin-from-command\n'
  printf -- '--stdin-filename\n%s\n' "${name}"
  restic_tag_args "${job}" "${run}" "kind=dbdump" "db=mongodb" "${tag}" "${JOB_TAGS[@]:-}"
  printf -- '--\n'
}

# See postgres.sh for why --stdin-from-command, timeout(1) and no `-t`.
_db_mongodb_run() {
  local job="$1" run="$2" name="$3" tag="$4"; shift 4
  [ "${1:-}" = "--" ] && shift

  local log rc=0
  log="$(tmp_file "db-mongodb-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(_db_mongodb_argv "${job}" "${run}" "${name}" "${tag}")
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$(( ${BGB_RUN_DB_DUMPS:-0} + 1 ))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$(( ${BGB_RUN_DB_DUMPS_FAILED:-0} + 1 ))
    err "mongodb: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi

  BGB_DB_LAST_SNAPSHOT=""
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "mongodb: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

# -----------------------------------------------------------------------------
# Topology
# -----------------------------------------------------------------------------
# db_mongodb_replset <container> - the replica set name, empty when standalone.
db_mongodb_replset() {
  local c="$1" out
  out="$(_db_mongodb_eval "${c}" 'print(db.hello().setName || "")' | tr -d '\r' | tail -n1 || true)"
  case "${out}" in
    *Error*|*error*|undefined|null) out="" ;;
  esac
  printf '%s' "${out}"
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
db_mongodb_dump() {
  local c="$1" job="$2" run="$3"
  local rs oplog="" rc=0

  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  rs="$(db_mongodb_replset "${c}")"
  if [ -n "${rs}" ]; then
    oplog="1"
    debug "mongodb: ${c} is a member of replica set '${rs}' - dumping with --oplog"
  fi

  _db_mongodb_run "${job}" "${run}" "/db/mongodb/${c}/all.archive" \
    "oplog=${oplog:-0}" \
    -- docker exec -i "${c}" sh -c "$(_db_mongodb_script "${_DB_MG_DUMP_SH}")" _ "${oplog}" || rc=$?

  if [ "${rc}" -ne 0 ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="mongodump failed"
    return "${rc}"
  fi

  if [ -z "${oplog}" ]; then
    BGB_DB_RESULT="degraded"
    BGB_DB_RESULT_REASON="standalone mongod: no oplog, dump is not point-in-time"
    _db_mongodb_degrade "mongodb/${c}: standalone deployment - --oplog is unavailable, so the archive is crash-inconsistent across collections"
    log "mongodb: convert to a single-node replica set (command: --replSet rs0, then rs.initiate()) to get point-in-time dumps"
  fi
  return "${EX_OK}"
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
# countDocuments() rather than estimatedDocumentCount(): the estimate comes from
# collection metadata that is not updated transactionally and is routinely wrong
# after an unclean shutdown - which is exactly the situation a restore follows.
db_mongodb_counts() {
  local c="${1:-}" raw compact
  [ -n "${c}" ] || return 0
  have docker || return 0
  [ "${JOB_DB_RECORD_COUNTS:-1}" = "1" ] || return 0

  raw="$(_db_mongodb_eval "${c}" "$(_db_mongodb_counts_js)" | tr -d '\r' | tail -n1 || true)"
  [ -n "${raw}" ] || return 0

  # The mongo shell emits real JSON here, so it is parsed with jq and only with
  # jq - never with a regex. jq -c also validates it before it is embedded.
  require_jq
  compact="$(printf '%s' "${raw}" | jq -c '.' 2>/dev/null || true)"
  [ -n "${compact}" ] || { warn "mongodb: ${c}: count output was not valid JSON - skipping"; return 0; }

  printf '{'
  json_kv engine mongodb; printf ','
  json_kv container "${c}"; printf ','
  json_kv taken "$(now_iso)"; printf ','
  json_kv source "live"; printf ','
  json_kvraw exact true; printf ','
  json_kvraw objects "${compact}"
  printf '}\n'
}

_db_mongodb_counts_js() {
  cat <<'JS'
var out = {};
db.getMongo().getDBNames().forEach(function (n) {
  if (n === 'admin' || n === 'local' || n === 'config') { return; }
  var d = db.getSiblingDB(n);
  d.getCollectionNames().forEach(function (cn) {
    try { out[n + '.' + cn] = d.getCollection(cn).countDocuments({}); } catch (e) { }
  });
});
print(JSON.stringify(out));
JS
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
# db_mongodb_restore <container> <archive-file|->
#
# --oplogReplay is passed only when the archive was taken with --oplog;
# mongorestore refuses the flag otherwise, and passing it blindly turns a
# recoverable restore into an error at the worst possible moment.
db_mongodb_restore() {
  local c="${1:-}" src="${2:--}" rc=0
  [ -n "${c}" ] || die "${EX_USAGE}" "db_mongodb_restore: container is required"
  require_cmd docker

  local oplog="" drop="${BGB_DB_RESTORE_DROP:-1}"
  if [ -n "$(db_mongodb_replset "${c}")" ]; then oplog="1"; fi
  if [ "${drop}" != "1" ]; then drop=""; fi

  log "mongodb: mongorestore into ${c}${oplog:+ with --oplogReplay}${drop:+ --drop}"
  local script
  script="$(_db_mongodb_script "${_DB_MG_RESTORE_SH}")"
  if [ "${src}" = "-" ]; then
    docker exec -i "${c}" sh -c "${script}" _ "${oplog}" "${drop}" || rc=$?
  else
    docker exec -i "${c}" sh -c "${script}" _ "${oplog}" "${drop}" <"${src}" || rc=$?
  fi

  [ "${rc}" -eq 0 ] || err "mongodb: restore failed (rc=${rc})"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Health probe
# -----------------------------------------------------------------------------
db_mongodb_verify_cmd() {
  local c="${1:-}"
  printf 'docker\nexec\n%s\nsh\n-c\n' "${c}"
  printf '%s\n' 'if command -v mongosh >/dev/null 2>&1; then exec mongosh --quiet --eval "quit(db.adminCommand({ping:1}).ok===1?0:1)"; else exec mongo --quiet --eval "quit(db.adminCommand({ping:1}).ok===1?0:1)"; fi'
}

# -----------------------------------------------------------------------------
# Operator notes
# -----------------------------------------------------------------------------
db_mongodb_notes() {
  cat <<'EOF'
MongoDB is dumped with mongodump --archive, streamed into restic through
--stdin-from-command so a dump that dies mid-collection fails the backup instead
of being stored. --oplog is added whenever the container is a replica set
member: it records the oplog entries produced during the dump and makes the
archive a true point-in-time snapshot. A standalone mongod has no oplog at all,
so the flag is dropped and the run is reported DEGRADED - the archive is still
usable, but writes that happened during the dump landed in some collections and
not others. The fix is small and permanent: start mongod with --replSet rs0 and
run rs.initiate() once, even for a single node. Credentials never appear in
argv; mongodump reads them from a 0600 --config file written inside the
container, and the shell reads them back with cat(). Row counts use
countDocuments() rather than the metadata estimate, because the estimate is
routinely wrong after the unclean shutdown that precedes most restores. Restore
replays the oplog with --oplogReplay only when the archive carries one. Not
covered: sharded clusters (dump each shard's config server and shards
separately, or use a coordinated backup tool), and users/roles stored outside
the admin database of the member being dumped.
EOF
}
