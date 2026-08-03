#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: Elasticsearch / OpenSearch
# =============================================================================
# THE THING TO UNDERSTAND FIRST: copying the data directory does not work.
#
# Lucene keeps segment files mmap'd and writes them lazily; a file-level copy of
# a live data directory produces an index that either refuses to open or opens
# with silent data loss. Stopping the node makes the copy consistent but still
# ties it to the exact Lucene version. Neither is a backup you can rely on.
#
# The only supported mechanism is the snapshot API, and it requires a registered
# repository - which for a filesystem repository requires `path.repo` in the
# node configuration. That is a COMPOSE CHANGE AND A RESTART, and it must happen
# BEFORE the first correct backup can ever be taken.
#
# So when path.repo is missing this module fails loudly with the exact change
# needed. It does not fall back to copying files: a backup that cannot restore
# is worse than a visibly missing one, because it stops anyone from looking.
# =============================================================================

[ -n "${_BGB_DB_ELASTICSEARCH_SOURCED:-}" ] && return 0
_BGB_DB_ELASTICSEARCH_SOURCED=1

db_elasticsearch_aliases() { printf 'opensearch\nelastic\nes\n'; }

: "${BGB_ES_REPO_NAME:=bg-backup}"

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
db_elasticsearch_detect() {
  local c="${1:-}" image
  [ -n "${c}" ] || return 1
  have docker || return 1

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1

  # Kibana, Logstash, Beats and the exporters all carry "elastic" in the name
  # and none of them hold the data.
  case "${image}" in
    *kibana* | *logstash* | *beat* | *exporter* | *apm* | *dashboards* | *enterprise-search*) return 1 ;;
  esac
  case "${image}" in
    *elasticsearch* | *opensearch*) : ;;
    *) return 1 ;;
  esac

  docker inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "${c}" 2>/dev/null \
    | grep -qx '9200/tcp' && return 0
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${c}" 2>/dev/null \
    | cut -d= -f1 | grep -qxE 'discovery.type|cluster.name|ES_JAVA_OPTS|OPENSEARCH_JAVA_OPTS' && return 0
  return 1
}

# -----------------------------------------------------------------------------
# Cluster access
# -----------------------------------------------------------------------------
# _db_es_curl <container> <method> <path> [body]
# Runs inside the container so no port has to be published and no credential
# leaves it. Security-enabled clusters get the elastic user from the container's
# own environment.
_db_es_curl() {
  local c="$1" method="$2" path="$3" body="${4:-}"
  local script='
    set -e
    scheme=http
    [ "${xpack_security_http_ssl_enabled:-${XPACK_SECURITY_HTTP_SSL_ENABLED:-false}}" = "true" ] && scheme=https
    auth=""
    pw="${ELASTIC_PASSWORD:-${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}}"
    if [ -n "$pw" ]; then
      user="${ELASTIC_USERNAME:-elastic}"
      [ -n "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}" ] && user="admin"
      auth="-u $user:$pw"
    fi
    # $1/$2/$3, NOT $2/$3/$4. `sh -c "$script" _ a b c` makes `_` the shell NAME
    # ($0) and a/b/c the positional parameters $1/$2/$3. Reading them one place
    # to the right sent the PATH as the HTTP method and the BODY as the path, so
    # every Elasticsearch/OpenSearch call this module made was malformed - and
    # the invocation discards stderr, so the snapshot API simply never answered.
    # shellcheck disable=SC2086
    if [ -n "$3" ]; then
      curl -sS -k $auth -X "$1" -H "Content-Type: application/json" -d "$3" "$scheme://localhost:9200$2"
    else
      curl -sS -k $auth -X "$1" "$scheme://localhost:9200$2"
    fi
  '
  docker exec -i "${c}" sh -c "${script}" _ "${method}" "${path}" "${body}" 2>/dev/null
}

# _db_es_path_repo <container> - the configured path.repo, empty when unset.
_db_es_path_repo() {
  local c="$1" out
  out="$(_db_es_curl "${c}" GET "/_nodes/settings?filter_path=nodes.*.settings.path.repo")"
  [ -n "${out}" ] || return 1
  have jq || return 1
  printf '%s' "${out}" | jq -r '[.nodes[]?.settings.path.repo // empty] | flatten | .[0] // empty' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
db_elasticsearch_dump() {
  local c="$1" job="$2" run="$3"
  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker
  require_jq

  local repo_path
  repo_path="$(_db_es_path_repo "${c}" || true)"

  if [ -z "${repo_path}" ]; then
    err "elasticsearch: ${c} has no path.repo configured."
    err ""
    err "  A file copy of the data directory is NOT a usable backup: Lucene keeps"
    err "  segments mmap'd, so the copy opens with silent data loss or not at all."
    err "  The snapshot API is the only supported mechanism, and it needs a"
    err "  registered repository."
    err ""
    err "  Add to the service in the compose file, then restart it:"
    err "      environment:"
    err "        - path.repo=/usr/share/elasticsearch/backup"
    err "      volumes:"
    err "        - es_backup:/usr/share/elasticsearch/backup"
    err ""
    err "  Until then this container has NO working backup."
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="path.repo is not configured - the snapshot API is unavailable"
    return "${EX_FAIL}"
  fi

  # 1. Register the repository (idempotent).
  local body
  body="$(printf '{"type":"fs","settings":{"location":"%s","compress":true}}' "${repo_path}")"
  if ! _db_es_curl "${c}" PUT "/_snapshot/${BGB_ES_REPO_NAME}" "${body}" | grep -q '"acknowledged":true'; then
    err "elasticsearch: could not register the snapshot repository at ${repo_path}"
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="snapshot repository registration failed"
    return "${EX_FAIL}"
  fi

  # 2. Take a snapshot and WAIT for completion. wait_for_completion is what makes
  #    the next step meaningful - without it we would tar a directory that is
  #    still being written into.
  # LOWERCASE, and this is not cosmetic. Elasticsearch rejects any snapshot name
  # containing an upper-case letter:
  #     invalid_snapshot_name_exception ... must be lowercase
  # and a bg-backup run id is a UTC timestamp - 20260803T191947Z-abc123 - so it
  # always contains T and Z. Every Elasticsearch dump this tool has ever
  # attempted failed on that, and the failure surfaced as the far less obvious
  # "snapshot did not succeed (state=unknown)" because the error document has no
  # .snapshot.state at all.
  local snap_name
  snap_name="bgb-$(printf '%s' "${run}" | tr '[:upper:]' '[:lower:]')"
  local resp
  resp="$(_db_es_curl "${c}" PUT \
    "/_snapshot/${BGB_ES_REPO_NAME}/${snap_name}?wait_for_completion=true" \
    '{"indices":"*","include_global_state":true,"partial":false}')"

  local state
  state="$(printf '%s' "${resp}" | jq -r '.snapshot.state // empty' 2>/dev/null)"
  case "${state}" in
    SUCCESS) : ;;
    PARTIAL)
      # PARTIAL means some shards were unavailable. The snapshot exists and is
      # restorable, but it is not the whole cluster - reported, not hidden.
      db_mark_degraded "elasticsearch/${c}: snapshot state PARTIAL (some shards were unavailable)"
      BGB_DB_RESULT="degraded"
      BGB_DB_RESULT_REASON="snapshot state PARTIAL"
      ;;
    *)
      # No .snapshot.state means the response was an ERROR DOCUMENT, not a
      # snapshot. Printing "state=unknown" threw away the one thing that
      # explains the failure - Elasticsearch always says why in .error.reason.
      local es_err
      es_err="$(printf '%s' "${resp}" | jq -r '.error.reason // empty' 2>/dev/null)"
      if [ -n "${es_err}" ]; then
        err "elasticsearch: ${es_err}"
        BGB_DB_RESULT_REASON="snapshot rejected: ${es_err}"
      else
        err "elasticsearch: snapshot did not succeed (state=${state:-unknown})"
        BGB_DB_RESULT_REASON="snapshot state ${state:-unknown}"
      fi
      BGB_DB_RESULT="failed"
      return "${EX_FAIL}"
      ;;
  esac

  # 3. Stream the repository directory into restic.
  local log rc=0
  log="$(tmp_file "db-es-XXXXXX")"
  local -a argv=()
  mapfile -t argv < <(
    restic_global_args
    printf 'backup\n'
    printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
    printf -- '--json\n'
    printf -- '--stdin-from-command\n'
    printf -- '--stdin-filename\n/db/elasticsearch/%s/snapshot-repo.tar\n' "${c}"
    restic_tag_args "${job}" "${run}" "kind=dbdump" "db=elasticsearch" \
      "es_snapshot=${snap_name}" "${JOB_TAGS[@]:-}"
    printf -- '--\n'
  )
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}"
    docker exec -i "${c}" tar -C "${repo_path}" -cf - .)

  BGB_RUN_DB_DUMPS=$((${BGB_RUN_DB_DUMPS:-0} + 1))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$((${BGB_RUN_DB_DUMPS_FAILED:-0} + 1))
    err "elasticsearch: storing the snapshot repository failed (rc=${rc})"
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="restic backup of the snapshot repository failed"
    return "${EX_FAIL}"
  fi

  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi

  # 4. Keep the in-cluster snapshot count bounded. The repository directory is
  #    incremental, so old snapshots cost space in every restic run too.
  _db_es_prune_snapshots "${c}"

  log "elasticsearch: stored snapshot ${snap_name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return "${EX_OK}"
}

_db_es_prune_snapshots() {
  local c="$1" keep="${BGB_ES_KEEP_SNAPSHOTS:-3}" old
  have jq || return 0
  old="$(_db_es_curl "${c}" GET "/_snapshot/${BGB_ES_REPO_NAME}/_all" \
    | jq -r --argjson k "${keep}" '[.snapshots[]? | select(.snapshot | startswith("bgb-"))]
                 | sort_by(.start_time_in_millis) | .[0:-($k)] | .[].snapshot' 2>/dev/null || true)"
  local s
  while IFS= read -r s; do
    [ -n "${s}" ] || continue
    debug "elasticsearch: removing in-cluster snapshot ${s}"
    _db_es_curl "${c}" DELETE "/_snapshot/${BGB_ES_REPO_NAME}/${s}" >/dev/null 2>&1 || true
  done <<<"${old}"
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
db_elasticsearch_counts() {
  local c="$1" out
  have jq || return 0
  out="$(_db_es_curl "${c}" GET "/_cat/indices?format=json&h=index,docs.count")"
  [ -n "${out}" ] || return 0
  printf '%s' "${out}" \
    | jq -c 'map(select(.index | startswith(".") | not))
             | map({(.index): ((."docs.count" // "0") | tonumber)}) | add // {}' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
db_elasticsearch_restore() {
  local c="$1"
  require_cmd docker
  local repo_path
  repo_path="$(_db_es_path_repo "${c}" || true)"
  [ -n "${repo_path}" ] || {
    err "elasticsearch: path.repo is not configured on the target"
    return "${EX_PRECOND}"
  }

  docker exec -i "${c}" tar -C "${repo_path}" -xf - || return "${EX_FAIL}"

  local body
  body="$(printf '{"type":"fs","settings":{"location":"%s","compress":true}}' "${repo_path}")"
  _db_es_curl "${c}" PUT "/_snapshot/${BGB_ES_REPO_NAME}" "${body}" >/dev/null

  local latest
  latest="$(_db_es_curl "${c}" GET "/_snapshot/${BGB_ES_REPO_NAME}/_all" \
    | jq -r '[.snapshots[]?] | sort_by(.start_time_in_millis) | last | .snapshot // empty' 2>/dev/null)"
  [ -n "${latest}" ] || {
    err "elasticsearch: no snapshot found in the restored repository"
    return "${EX_FAIL}"
  }

  # Indices must be closed before a restore; an open index is refused.
  _db_es_curl "${c}" POST "/_all/_close" >/dev/null 2>&1 || true
  _db_es_curl "${c}" POST "/_snapshot/${BGB_ES_REPO_NAME}/${latest}/_restore?wait_for_completion=true" \
    '{"indices":"*","include_global_state":true}' | grep -q '"snapshot"' || return "${EX_FAIL}"
  return 0
}

db_elasticsearch_verify_cmd() {
  local c="$1" out
  out="$(_db_es_curl "${c}" GET "/_cluster/health")"
  printf '%s' "${out}" | grep -qE '"status":"(green|yellow)"'
}

db_elasticsearch_notes() {
  cat <<'EOF'
Snapshot API into a registered fs repository, then the repository directory is
tarred into restic. Requires path.repo in the node config - a compose change and
a restart - BEFORE any correct backup is possible. A data-directory copy is not
a usable backup: Lucene mmaps its segments.
EOF
}
