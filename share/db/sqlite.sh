#!/usr/bin/env bash
# =============================================================================
# bg-backup - database engine: SQLite
# =============================================================================
# THE ONE RULE: never copy the file.
#
#   SQLite in WAL mode - which is the default for almost every self-hosted
#   application shipped in a container - keeps recently committed transactions
#   in a separate <db>-wal file until a checkpoint folds them back in. Copying
#   only <db> gives you a database that is missing every commit since the last
#   checkpoint. Copying <db>, <db>-wal and <db>-shm as three separate files
#   gives you three files captured at three different instants, which SQLite
#   will happily open and then behave unpredictably around. And a plain copy
#   taken while a writer holds the write lock can be torn mid-page.
#
#   The failure mode is the worst kind: the file opens, most queries work, and
#   the corruption is discovered weeks later.
#
#   The supported answers are sqlite3's ".backup" (the online backup API) and
#   "VACUUM INTO". Both take a read transaction, both fold the WAL in, and both
#   produce a single self-contained file.
#
# WHY ".backup" IS PREFERRED OVER "VACUUM INTO".
#
#   VACUUM INTO rewrites the database compactly, which moves nearly every page.
#   restic would then see a completely different file each night and deduplicate
#   almost nothing. ".backup" copies page for page and preserves the layout, so
#   two consecutive nightly backups of a 4 GiB database differ by the pages that
#   actually changed. VACUUM INTO is kept only as the fallback for shells too
#   old to have one of them - it is correct, just more expensive to store.
#
# DISCOVERY. Detection by image name alone is impossible here: SQLite is a
# library, not a server, and the container is called "gitea" or "uptime-kuma".
# Three sources are used, in order: the container label bg-backup.sqlite.paths,
# the job setting JOB_DB_SQLITE_PATHS, and finally a scan of the container's
# mount points for files whose first 15 bytes are "SQLite format 3". The scan is
# a convenience; the label is what an operator should rely on.
# =============================================================================

[ -n "${_BGB_DB_SQLITE_SOURCED:-}" ] && return 0
_BGB_DB_SQLITE_SOURCED=1

db_sqlite_aliases() { printf 'sqlite3\n'; }

_DB_SQLITE_LABEL='bg-backup.sqlite.paths'

# -----------------------------------------------------------------------------
# Container scripts
# -----------------------------------------------------------------------------

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_SQ_SCAN_SH <<'EOS' || true
# Print every file under the given roots whose header says it is a SQLite
# database. The magic check matters: a *.db file is just as likely to be a
# Berkeley DB, a LevelDB manifest or an application's own format, and handing
# one of those to sqlite3 produces a confusing error at 03:00.
for root in "$@"; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth "${BGB_SQLITE_SCAN_DEPTH:-3}" -type f \
       \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null
done | while IFS= read -r f; do
  if [ "$(head -c 15 "$f" 2>/dev/null)" = "SQLite format 3" ]; then
    printf '%s\n' "$f"
  fi
done
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_SQ_DUMP_SH <<'EOS' || true
set -e
src="$1"
umask 077
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT INT TERM
out="$d/copy.sqlite"

# .timeout before anything else: without it a concurrent writer makes the backup
# fail instantly with SQLITE_BUSY instead of waiting the few milliseconds the
# writer needs.
if ! sqlite3 "$src" ".timeout 30000" ".backup '$out'" 2>"$d/err"; then
  rm -f "$out"
  # VACUUM INTO needs SQLite 3.27; it is the fallback, not the default, because
  # it rewrites every page and destroys deduplication between runs.
  if ! sqlite3 "$src" ".timeout 30000" "VACUUM INTO '$out'" 2>>"$d/err"; then
    echo "bg-backup: neither .backup nor VACUUM INTO worked on $src" >&2
    cat "$d/err" >&2 2>/dev/null || true
    exit 1
  fi
fi

# Prove the copy is a database before it is stored. An empty or truncated file
# here would be indexed as a perfectly healthy snapshot.
if [ "$(head -c 15 "$out")" != "SQLite format 3" ]; then
  echo "bg-backup: the backup of $src is not a SQLite database" >&2
  exit 1
fi
cat "$out"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_SQ_COUNTS_SH <<'EOS' || true
set -e
src="$1"
q=$(sqlite3 -readonly "$src" ".timeout 10000" "
  SELECT group_concat(
    'SELECT ''' || replace(name, '''', '''''') || ''' AS o, COUNT(*) AS c FROM \"'
    || replace(name, '\"', '\"\"') || '\"',
    ' UNION ALL ')
  FROM sqlite_master
  WHERE type = 'table' AND name NOT LIKE 'sqlite~_%' ESCAPE '~';")
[ -n "$q" ] || exit 0
# One statement, therefore one implicit read transaction, therefore every count
# describes the same instant. A loop of per-table queries would not.
exec sqlite3 -readonly -separator '|' "$src" ".timeout 10000" "$q"
EOS

# shellcheck disable=SC2016
IFS= read -r -d '' _DB_SQ_RESTORE_SH <<'EOS' || true
set -e
target="$1"
umask 077
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT INT TERM
cat >"$d/in.sqlite"
if [ "$(head -c 15 "$d/in.sqlite")" != "SQLite format 3" ]; then
  echo "bg-backup: the stream is not a SQLite database - refusing to overwrite $target" >&2
  exit 1
fi
# .restore drives the online backup API in the other direction. It replaces the
# target's contents through SQLite itself, so the WAL and any open readers are
# handled correctly - unlike `cp`, which leaves a stale -wal beside the new file
# and produces a database that mixes two eras.
exec sqlite3 "$target" ".timeout 30000" ".restore '$d/in.sqlite'"
EOS

# -----------------------------------------------------------------------------
# Where does sqlite3 live?
# -----------------------------------------------------------------------------
# Many application images do not ship the sqlite3 CLI. The host almost always
# can, and the database file is visible on the host through the mount anyway, so
# the fallback is to run the same commands there against the translated path.
# What is NOT done as a fallback is copying the file - see the file header.
_db_sqlite_has_cli() {
  docker exec -i "$1" sh -c 'command -v sqlite3 >/dev/null 2>&1' >/dev/null 2>&1
}

# _db_sqlite_hostpath <container> <container-path> - "" when not bind/volume backed.
_db_sqlite_hostpath() {
  local c="$1" path="$2" dest src line
  while IFS=$'\t' read -r dest src; do
    [ -n "${dest}" ] || continue
    case "${path}" in
      "${dest}") printf '%s' "${src}"; return 0 ;;
      "${dest%/}"/*) printf '%s%s' "${src%/}" "${path#"${dest%/}"}"; return 0 ;;
    esac
  done < <(docker inspect --format '{{range .Mounts}}{{.Destination}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}' "${c}" 2>/dev/null || true)
  printf ''
  # `line` is unused but declared so shellcheck does not flag the read pattern.
  : "${line:-}"
}

# -----------------------------------------------------------------------------
# Path discovery
# -----------------------------------------------------------------------------
# db_sqlite_paths <container> - one absolute in-container path per line.
db_sqlite_paths() {
  local c="$1" label roots=""
  have docker || return 0

  label="$(docker inspect --format "{{index .Config.Labels \"${_DB_SQLITE_LABEL}\"}}" "${c}" 2>/dev/null || true)"
  case "${label}" in ''|'<no value>') label="" ;; esac
  if [ -n "${label}" ]; then
    printf '%s\n' "${label}" | tr ',;: ' '\n\n\n\n' | while IFS= read -r p; do
      [ -n "${p}" ] && printf '%s\n' "${p}"
    done
    return 0
  fi

  local p
  for p in "${JOB_DB_SQLITE_PATHS[@]:-}"; do
    [ -n "${p}" ] || continue
    # JOB_DB_SQLITE_PATHS entries may be "container:/path" to scope them.
    case "${p}" in
      "${c}":*) printf '%s\n' "${p#*:}" ;;
      *:*) : ;;
      *) printf '%s\n' "${p}" ;;
    esac
  done
  if [ "${#JOB_DB_SQLITE_PATHS[@]:-0}" -gt 0 ]; then return 0; fi

  # Last resort: scan the container's own mount points. Only mounted paths are
  # scanned - anything inside the writable container layer is thrown away on the
  # next `compose up` and is not worth backing up.
  local -a mounts=()
  mapfile -t mounts < <(docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "${c}" 2>/dev/null || true)
  [ "${#mounts[@]}" -gt 0 ] || return 0
  roots=""
  docker exec -i "${c}" sh -c "${_DB_SQ_SCAN_SH}" _ "${mounts[@]}" 2>/dev/null || true
  : "${roots}"
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------
# A container "runs SQLite" when it has been told it does (label or job
# setting), or when its image is one of the well-known SQLite-backed
# applications AND a scan actually finds a database. The image list alone is
# never sufficient: most of these applications can be configured to use
# PostgreSQL or MySQL instead, and dumping a stale leftover .db from a migrated
# instance would quietly back up the wrong data.
db_sqlite_detect() {
  local c="${1:-}" image label
  [ -n "${c}" ] || return 1
  have docker || return 1

  label="$(docker inspect --format "{{index .Config.Labels \"${_DB_SQLITE_LABEL}\"}}" "${c}" 2>/dev/null || true)"
  case "${label}" in ''|'<no value>') label="" ;; esac
  [ -n "${label}" ] && return 0

  local p
  for p in "${JOB_DB_SQLITE_PATHS[@]:-}"; do
    case "${p}" in "${c}":*) return 0 ;; esac
  done

  image="$(docker inspect --format '{{.Config.Image}}' "${c}" 2>/dev/null || true)"
  image="$(printf '%s' "${image}" | tr '[:upper:]' '[:lower:]')"
  [ -n "${image}" ] || return 1
  case "${image}" in
    *gitea*|*forgejo*|*vaultwarden*|*uptime-kuma*|*n8n*|*grafana*|*home-assistant*|*homeassistant*|\
    *sonarr*|*radarr*|*lidarr*|*readarr*|*prowlarr*|*bazarr*|*jellyfin*|*navidrome*|*audiobookshelf*|\
    *calibre*|*linkding*|*shiori*|*photoprism*|*mealie*|*vikunja*|*changedetection*|*syncthing*|\
    *pihole*|*freshrss*|*tandoor*|*karakeep*|*hoarder*|*speedtest*) : ;;
    *) return 1 ;;
  esac

  # Proof: at least one real SQLite file must exist.
  [ -n "$(db_sqlite_paths "${c}" | head -n1)" ]
}

# -----------------------------------------------------------------------------
# Streaming into restic
# -----------------------------------------------------------------------------
_db_sqlite_argv() {
  local job="$1" run="$2" name="$3" tag="$4"
  restic_global_args
  printf 'backup\n'
  printf -- '--host\n%s\n' "${BGB_HOSTNAME}"
  printf -- '--json\n'
  printf -- '--stdin-from-command\n'
  printf -- '--stdin-filename\n%s\n' "${name}"
  restic_tag_args "${job}" "${run}" "kind=dbdump" "db=sqlite" "${tag}" "${JOB_TAGS[@]:-}"
  printf -- '--\n'
}

# See postgres.sh for why --stdin-from-command, timeout(1) and no `-t`.
_db_sqlite_run() {
  local job="$1" run="$2" name="$3" tag="$4"; shift 4
  [ "${1:-}" = "--" ] && shift

  local log rc=0
  log="$(tmp_file "db-sqlite-XXXXXX")"

  local -a argv=()
  mapfile -t argv < <(_db_sqlite_argv "${job}" "${run}" "${name}" "${tag}")
  argv+=(timeout "${JOB_DB_DUMP_TIMEOUT:-3600}" "$@")

  BGB_RUN_DB_DUMPS=$(( ${BGB_RUN_DB_DUMPS:-0} + 1 ))
  restic_exec_logged "${log}" "${argv[@]}" || rc=$?
  BGB_DB_LAST_LOG="${log}"

  if [ "${rc}" -ne 0 ]; then
    BGB_RUN_DB_DUMPS_FAILED=$(( ${BGB_RUN_DB_DUMPS_FAILED:-0} + 1 ))
    err "sqlite: ${name} failed (restic rc=${rc}: $(restic_explain_rc "${rc}"))"
    return "${EX_FAIL}"
  fi

  BGB_DB_LAST_SNAPSHOT=""
  if have jq && [ -s "${log}" ]; then
    BGB_DB_LAST_SNAPSHOT="$(jq -r 'select(.message_type=="summary") | .snapshot_id // empty' \
      "${log}" 2>/dev/null | tail -n1 || true)"
  fi
  log "sqlite: stored ${name}${BGB_DB_LAST_SNAPSHOT:+ (${BGB_DB_LAST_SNAPSHOT:0:8})}"
  return 0
}

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
db_sqlite_dump() {
  local c="$1" job="$2" run="$3"
  local -a paths=()
  local p safe hostpath rc=0 worst=0 incontainer=0

  BGB_DB_RESULT="ok"
  BGB_DB_RESULT_REASON=""
  require_cmd docker

  mapfile -t paths < <(db_sqlite_paths "${c}")
  if [ "${#paths[@]}" -eq 0 ]; then
    BGB_DB_RESULT="skipped"
    BGB_DB_RESULT_REASON="no SQLite database found"
    log "sqlite: ${c}: no SQLite database found - set the ${_DB_SQLITE_LABEL} label if that is wrong"
    return "${EX_OK}"
  fi

  _db_sqlite_has_cli "${c}" && incontainer=1
  if [ "${incontainer}" -eq 0 ] && ! have sqlite3; then
    BGB_DB_RESULT="refused"
    BGB_DB_RESULT_REASON="sqlite3 is available neither in the container nor on the host"
    err "sqlite: ${c}: the image has no sqlite3 CLI and the host has none either."
    err "sqlite: install it on the host (apt-get install -y sqlite3) - bg-backup will then run"
    err "sqlite: the online backup against the mounted path. Copying the file is NOT an option:"
    err "sqlite: WAL mode makes a plain copy silently inconsistent."
    return "${EX_PRECOND}"
  fi

  for p in "${paths[@]}"; do
    [ -n "${p}" ] || continue
    safe="${p#/}"
    safe="${safe//\//_}"
    safe="${safe//[^A-Za-z0-9._-]/_}"
    rc=0
    if [ "${incontainer}" -eq 1 ]; then
      _db_sqlite_run "${job}" "${run}" "/db/sqlite/${c}/${safe}" "path=${safe}" \
        -- docker exec -i "${c}" sh -c "${_DB_SQ_DUMP_SH}" _ "${p}" || rc=$?
    else
      hostpath="$(_db_sqlite_hostpath "${c}" "${p}")"
      if [ -z "${hostpath}" ] || [ ! -f "${hostpath}" ]; then
        warn "sqlite: ${c}: ${p} is not reachable from the host and the container has no sqlite3 - skipping"
        worst="$(worst_rc "${worst}" "${EX_PARTIAL}")"
        continue
      fi
      _db_sqlite_run "${job}" "${run}" "/db/sqlite/${c}/${safe}" "path=${safe}" \
        -- sh -c "${_DB_SQ_DUMP_SH}" _ "${hostpath}" || rc=$?
    fi
    worst="$(worst_rc "${worst}" "${rc}")"
  done

  if [ "${worst}" != "0" ]; then
    BGB_DB_RESULT="failed"
    BGB_DB_RESULT_REASON="at least one SQLite database could not be backed up"
    return "${worst}"
  fi
  return "${EX_OK}"
}

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
db_sqlite_counts() {
  local c="${1:-}"
  [ -n "${c}" ] || return 0
  have docker || return 0
  [ "${JOB_DB_RECORD_COUNTS:-1}" = "1" ] || return 0

  local -a paths=()
  mapfile -t paths < <(db_sqlite_paths "${c}")
  [ "${#paths[@]}" -gt 0 ] || return 0

  local incontainer=0
  _db_sqlite_has_cli "${c}" && incontainer=1
  [ "${incontainer}" -eq 1 ] || have sqlite3 || return 0

  local p safe hostpath key val first=1 raw
  printf '{'
  json_kv engine sqlite; printf ','
  json_kv container "${c}"; printf ','
  json_kv taken "$(now_iso)"; printf ','
  json_kv source "live"; printf ','
  json_kvraw exact true; printf ','
  printf '"objects":{'
  for p in "${paths[@]}"; do
    [ -n "${p}" ] || continue
    safe="${p##*/}"
    if [ "${incontainer}" -eq 1 ]; then
      raw="$(docker exec -i "${c}" sh -c "${_DB_SQ_COUNTS_SH}" _ "${p}" 2>/dev/null || true)"
    else
      hostpath="$(_db_sqlite_hostpath "${c}" "${p}")"
      [ -n "${hostpath}" ] && [ -f "${hostpath}" ] || continue
      raw="$(sh -c "${_DB_SQ_COUNTS_SH}" _ "${hostpath}" 2>/dev/null || true)"
    fi
    [ -n "${raw}" ] || continue
    while IFS='|' read -r key val; do
      [ -n "${key}" ] || continue
      [ "${first}" -eq 0 ] && printf ','
      json_kvraw "${safe}.${key}" "$(json_num "${val}")"
      first=0
    done <<<"${raw}"
  done
  printf '}}\n'
}

# -----------------------------------------------------------------------------
# Restore
# -----------------------------------------------------------------------------
# db_sqlite_restore <container> <dump-file|-> [target-path]
db_sqlite_restore() {
  local c="${1:-}" src="${2:--}" target="${3:-}" rc=0
  [ -n "${c}" ] || die "${EX_USAGE}" "db_sqlite_restore: container is required"
  require_cmd docker

  if [ -z "${target}" ]; then
    target="$(db_sqlite_paths "${c}" | head -n1)"
    [ -n "${target}" ] || die "${EX_USAGE}" "db_sqlite_restore: no target path given and none discoverable"
  fi

  # The application must not be writing while its database is replaced. This is
  # a hard requirement, not a nicety: .restore replaces the pages underneath a
  # live connection and the application's cached schema then no longer matches.
  warn "sqlite: stop the application that owns ${target} before restoring into it"
  confirm "Restore into ${c}:${target}?" || return "${EX_SAFETY}"

  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] sqlite: .restore into ${c}:${target}"
    return 0
  fi

  local incontainer=0 hostpath=""
  _db_sqlite_has_cli "${c}" && incontainer=1
  if [ "${incontainer}" -eq 1 ]; then
    if [ "${src}" = "-" ]; then
      docker exec -i "${c}" sh -c "${_DB_SQ_RESTORE_SH}" _ "${target}" || rc=$?
    else
      docker exec -i "${c}" sh -c "${_DB_SQ_RESTORE_SH}" _ "${target}" <"${src}" || rc=$?
    fi
  else
    require_cmd sqlite3 "install it with: apt-get install -y sqlite3"
    hostpath="$(_db_sqlite_hostpath "${c}" "${target}")"
    [ -n "${hostpath}" ] || die "${EX_PRECOND}" "sqlite: ${target} is not reachable from the host"
    if [ "${src}" = "-" ]; then
      sh -c "${_DB_SQ_RESTORE_SH}" _ "${hostpath}" || rc=$?
    else
      sh -c "${_DB_SQ_RESTORE_SH}" _ "${hostpath}" <"${src}" || rc=$?
    fi
  fi

  [ "${rc}" -eq 0 ] || err "sqlite: restore failed (rc=${rc})"
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Health probe
# -----------------------------------------------------------------------------
# PRAGMA schema_version, not integrity_check: the probe runs on every verify and
# integrity_check reads the entire database. quick_check is the middle ground if
# you want one - it is not the default because it is still O(size).
db_sqlite_verify_cmd() {
  local c="${1:-}" p
  p="$(db_sqlite_paths "${c}" | head -n1)"
  [ -n "${p}" ] || return 0
  printf 'docker\nexec\n%s\nsqlite3\n-readonly\n%s\nPRAGMA schema_version;\n' "${c}" "${p}"
}

# -----------------------------------------------------------------------------
# Operator notes
# -----------------------------------------------------------------------------
db_sqlite_notes() {
  cat <<'EOF'
SQLite databases are backed up through sqlite3's online backup API (".backup"),
never by copying the file. In WAL mode - the default for nearly every
self-hosted application - the file on disk is missing every commit since the
last checkpoint, and copying db, db-wal and db-shm separately captures three
different instants; the result opens fine and corrupts quietly. ".backup" is
preferred over "VACUUM INTO" because it preserves page layout, so restic
deduplicates a nightly 4 GiB database down to the pages that actually changed,
whereas VACUUM INTO rewrites everything and stores a full copy each night.
Databases are found from the container label bg-backup.sqlite.paths (the
reliable way), from JOB_DB_SQLITE_PATHS, or by scanning the container's mounts
for files starting with "SQLite format 3". If the image has no sqlite3 CLI,
bg-backup runs the same operation from the host against the mounted path; if
neither has it, the run is refused rather than downgraded to a file copy. Restore
uses ".restore", which drives the same API in reverse and handles the WAL - but
the owning application must be stopped first, because its cached schema will not
match the pages underneath it. Counts are exact and taken in a single statement,
so they all describe one instant.
EOF
}
