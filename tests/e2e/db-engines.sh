#!/usr/bin/env bash
# =============================================================================
# e2e: every supported database engine, dumped consistently
# =============================================================================
# Eight engines, each seeded with known content, backed up, and proven to have
# produced a real dump. Before this existed only PostgreSQL and MySQL/MariaDB
# had ever been executed, and the first run of the other six found:
#
#   * Elasticsearch could NEVER have worked - it names its snapshot after the
#     run id, which is a UTC timestamp containing T and Z, and Elasticsearch
#     rejects any snapshot name with an upper-case letter. The failure surfaced
#     as "state=unknown" because an error document has no .snapshot.state.
#   * The shipped JOB_DB_ENGINES default listed five engines, so influxdb,
#     clickhouse, elasticsearch, mssql and sqlite were filtered out of the plan
#     on every host that ran them - silently, and the run reported success.
#   * `discover` used a second hand-maintained list that had lost sqlite, the
#     one engine that cannot be found by image name and therefore depends on
#     discover to be noticed at all.
#
# TWO ENGINES NEED THE OPERATOR TO CONFIGURE SOMETHING BEFORE A CONSISTENT
# BACKUP IS POSSIBLE AT ALL, and this stack configures both, on purpose:
#
#   * MongoDB must be a replica set. A standalone mongod has no oplog, so
#     mongodump cannot produce a point-in-time archive and the tool correctly
#     reports the result as DEGRADED. Testing only the standalone case would
#     mean never executing the consistent path.
#   * ClickHouse needs a backup disk. Without one the module falls back to
#     per-table dumps, which are not a single point in time across tables.
#   * Elasticsearch needs path.repo. Without it the snapshot API is unavailable
#     and no correct backup exists at any price.
#
# Requires the privileged rig container with its own dockerd - see
# tests/rig/Dockerfile.docker-victim.
# =============================================================================

# shellcheck disable=SC2319
set -uo pipefail

SRC=/opt/bgb
PASS=0
FAIL=0

ok() {
  printf '  \033[32mPASS\033[0m %s\n' "$*"
  PASS=$((PASS + 1))
}
bad() {
  printf '  \033[31mFAIL\033[0m %s\n' "$*"
  FAIL=$((FAIL + 1))
}
ck() { [ "$1" -eq 0 ] && ok "$2" || bad "$2"; }
eq() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected '$3', got '$2'"; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }
log() { printf '\033[36m[eng]\033[0m %s\n' "$*"; }
die() {
  printf '\033[31m[eng]\033[0m %s\n' "$*" >&2
  exit 1
}

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

MY_PW=my-throwaway-rig-pw
MONGO_PW=mongo-throwaway-rig-pw
INFLUX_TOKEN=influx-throwaway-rig-token-0123456789

# -----------------------------------------------------------------------------
sect "0. A Docker daemon of our own"

if ! docker info >/dev/null 2>&1; then
  dockerd >/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
fi
docker info >/dev/null 2>&1
ck $? "dockerd is up"
docker info >/dev/null 2>&1 || {
  tail -20 /var/log/dockerd.log
  exit 1
}

# -----------------------------------------------------------------------------
sect "1. Eight engines, configured for consistency"

install -d /srv/eng/essnap /srv/eng/chcfg
chmod 0777 /srv/eng/essnap

# The backup disk ClickHouse needs. Without it BACKUP ... TO Disk() is refused
# and the module degrades to per-table dumps.
cat >/srv/eng/chcfg/backup-disk.xml <<'XML'
<clickhouse>
  <storage_configuration>
    <disks>
      <backups>
        <type>local</type>
        <path>/backups/</path>
      </backups>
    </disks>
  </storage_configuration>
  <backups>
    <allowed_disk>backups</allowed_disk>
  </backups>
</clickhouse>
XML

cat >/srv/eng/docker-compose.yml <<YML
name: engines

services:
  pg:
    image: postgres:16-alpine
    environment: {POSTGRES_PASSWORD: pg-throwaway-rig-pw, POSTGRES_DB: appdb}
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U postgres"], interval: 3s, retries: 40}

  my:
    image: mariadb:11
    environment: {MARIADB_ROOT_PASSWORD: ${MY_PW}, MARIADB_DATABASE: appmy}
    volumes: [mydata:/var/lib/mysql]
    healthcheck: {test: ["CMD-SHELL", "mariadb-admin ping -uroot -p${MY_PW} || exit 1"], interval: 3s, retries: 40}

  mongo:
    image: mongo:7
    # --replSet is what gives mongodump an oplog, and therefore a point-in-time
    # archive. A standalone mongod is correctly reported as DEGRADED, so testing
    # only that shape would never execute the consistent path.
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all"]
    volumes: [mongodata:/data/db]
    healthcheck: {test: ["CMD-SHELL", "mongosh --quiet --eval 'db.adminCommand(1)' || exit 1"], interval: 5s, retries: 40}

  redis:
    image: redis:7-alpine
    command: ["redis-server", "--save", "60", "1", "--appendonly", "no"]
    volumes: [redisdata:/data]
    healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 3s, retries: 40}

  influx:
    image: influxdb:2.7-alpine
    environment:
      DOCKER_INFLUXDB_INIT_MODE: setup
      DOCKER_INFLUXDB_INIT_USERNAME: admin
      DOCKER_INFLUXDB_INIT_PASSWORD: influx-throwaway-rig-pw
      DOCKER_INFLUXDB_INIT_ORG: bgb
      DOCKER_INFLUXDB_INIT_BUCKET: metrics
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: ${INFLUX_TOKEN}
    volumes: [influxdata:/var/lib/influxdb2]
    healthcheck: {test: ["CMD", "influx", "ping"], interval: 5s, retries: 40}

  ch:
    image: clickhouse/clickhouse-server:24-alpine
    environment: {CLICKHOUSE_SKIP_USER_SETUP: "1"}
    ulimits: {nofile: {soft: 262144, hard: 262144}}
    volumes:
      - chdata:/var/lib/clickhouse
      - chbackup:/backups
      - /srv/eng/chcfg/backup-disk.xml:/etc/clickhouse-server/config.d/backup-disk.xml:ro
    healthcheck: {test: ["CMD-SHELL", "clickhouse-client -q 'SELECT 1' || exit 1"], interval: 5s, retries: 40}

  es:
    image: elasticsearch:8.15.0
    environment:
      discovery.type: single-node
      xpack.security.enabled: "false"
      ES_JAVA_OPTS: "-Xms256m -Xmx256m"
      # Without path.repo the snapshot API is unavailable and NO correct backup
      # of this engine is possible at any price.
      path.repo: /snapshots
    volumes:
      - esdata:/usr/share/elasticsearch/data
      - /srv/eng/essnap:/snapshots
    healthcheck: {test: ["CMD-SHELL", "curl -fsS localhost:9200/_cluster/health || exit 1"], interval: 5s, retries: 60}

  app:
    image: alpine:3.20
    command: ["sh", "-c", "apk add --no-cache sqlite >/dev/null 2>&1; sleep infinity"]
    # SQLite is a LIBRARY, not a server: it cannot be detected from an image
    # name, so the operator declares where its databases live.
    labels: {bg-backup.sqlite.paths: "/data/app.sqlite"}
    volumes: [appdata:/data]

volumes: {pgdata: {}, mydata: {}, mongodata: {}, redisdata: {}, influxdata: {}, chdata: {}, chbackup: {}, esdata: {}, appdata: {}}
YML

log "starting the stack"
(cd /srv/eng && docker compose up -d) >/tmp/engup.log 2>&1 || {
  tail -25 /tmp/engup.log
  die "compose up failed"
}

log "waiting for every engine to answer a real query"
wait_for() { # <name> <command...>
  local name="$1"
  shift
  local i
  for i in $(seq 1 90); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

wait_for pg docker exec engines-pg-1 psql -U postgres -d appdb -tAq -c 'SELECT 1'
ck $? "PostgreSQL answers"
wait_for my docker exec -e MYSQL_PWD="${MY_PW}" engines-my-1 mariadb -uroot -e 'SELECT 1'
ck $? "MariaDB answers"
wait_for redis docker exec engines-redis-1 redis-cli ping
ck $? "Redis answers"
wait_for influx docker exec engines-influx-1 influx ping
ck $? "InfluxDB answers"
wait_for ch docker exec engines-ch-1 clickhouse-client -q 'SELECT 1'
ck $? "ClickHouse answers"
wait_for es docker exec engines-es-1 curl -fsS localhost:9200/_cluster/health
ck $? "Elasticsearch answers"
wait_for app docker exec engines-app-1 sh -c 'command -v sqlite3'
ck $? "the SQLite container has sqlite3"

# Mongo needs the replica set initiated before it accepts writes.
docker exec engines-mongo-1 mongosh --quiet --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"localhost:27017"}]})' >/dev/null 2>&1 || true
wait_for mongo docker exec engines-mongo-1 mongosh --quiet --eval 'db.hello().isWritablePrimary'
ck $? "MongoDB is a writable replica-set primary"

# -----------------------------------------------------------------------------
sect "2. Seed every engine with known content"

docker exec -i engines-pg-1 psql -U postgres -d appdb -v ON_ERROR_STOP=1 -q <<'SQL' || die "pg seed"
CREATE TABLE t (id INT PRIMARY KEY, payload TEXT);
INSERT INTO t SELECT g, md5(g::text) FROM generate_series(1,20000) g;
SQL
WANT_PG="$(docker exec engines-pg-1 psql -U postgres -d appdb -tAq -c 'SELECT count(*) FROM t;')"

docker exec -i -e MYSQL_PWD="${MY_PW}" engines-my-1 mariadb -uroot appmy <<'SQL' || die "my seed"
SET SESSION max_recursive_iterations = 1000000;
CREATE TABLE t (id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE=InnoDB;
INSERT INTO t (id, payload)
  WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 20000)
  SELECT n, MD5(n) FROM s;
SQL
WANT_MY="$(docker exec -e MYSQL_PWD="${MY_PW}" engines-my-1 mariadb -N -B -uroot appmy -e 'SELECT COUNT(*) FROM t;')"

docker exec engines-mongo-1 mongosh --quiet --eval \
  'for (let i=0;i<5000;i++) db.getSiblingDB("appdb").t.insertOne({_id:i,v:"v"+i}); print(db.getSiblingDB("appdb").t.countDocuments())' >/tmp/mongoseed 2>&1
WANT_MONGO="$(tail -1 /tmp/mongoseed | tr -d '\r')"

docker exec engines-redis-1 redis-cli -n 0 eval "for i=1,5000 do redis.call('SET','k'..i,'v'..i) end return redis.call('DBSIZE')" 0 >/tmp/redisseed 2>&1
WANT_REDIS="$(tail -1 /tmp/redisseed | tr -d '\r')"

docker exec engines-ch-1 clickhouse-client -q \
  "CREATE TABLE IF NOT EXISTS t (id UInt32, v String) ENGINE = MergeTree ORDER BY id; INSERT INTO t SELECT number, toString(number) FROM numbers(20000);" >/dev/null 2>&1
WANT_CH="$(docker exec engines-ch-1 clickhouse-client -q 'SELECT count() FROM t')"

# Written to a FILE, not passed through "$(...)". Command substitution strips
# trailing newlines and the _bulk API requires the body to end with one - without
# it the last action is incomplete and Elasticsearch rejects the whole request.
# The dump then still "succeeded": it snapshotted an empty cluster, which is
# exactly the kind of vacuous pass this assertion exists to catch.
#
# And the cluster must be past RED before it accepts writes. /_cluster/health
# answers as soon as the HTTP layer is up, which is why the wait in section 1 is
# not enough on its own: the first attempt hit a node that returned nothing at
# all, so the count came back as the empty string rather than 0.
for i in $(seq 1 60); do
  st="$(docker exec engines-es-1 curl -fsS 'localhost:9200/_cluster/health' 2>/dev/null | jq -r '.status // empty')"
  case "${st}" in green | yellow) break ;; esac
  sleep 3
done

for i in $(seq 1 200); do printf '{"index":{}}
{"v":"doc%s"}
' "${i}"; done >/tmp/es-bulk.ndjson
docker cp /tmp/es-bulk.ndjson engines-es-1:/tmp/es-bulk.ndjson >/dev/null 2>&1

docker exec engines-es-1 curl -sS -X POST 'localhost:9200/appidx/_bulk?refresh=true' -H 'Content-Type: application/x-ndjson' --data-binary @/tmp/es-bulk.ndjson >/tmp/es-bulk.resp 2>&1

# _cat/count, not _count: a plain number, no JSON parser and no --fail. The JSON
# form was retried twenty times and never once parsed, while the bulk response
# showed "errors":false and documents being created - so the loop re-indexed the
# same 200 documents nineteen times and still reported a count of zero. A
# readiness probe that can fail for reasons unrelated to readiness is worse than
# no probe at all.
WANT_ES=0
for i in $(seq 1 30); do
  WANT_ES="$(docker exec engines-es-1 curl -sS 'localhost:9200/_cat/count/appidx?h=count' 2>/dev/null | tr -dc '0-9')"
  [ -n "${WANT_ES}" ] && [ "${WANT_ES}" -ge 200 ] 2>/dev/null && break
  sleep 2
done
[ -n "${WANT_ES}" ] || WANT_ES=0
if [ "${WANT_ES}" -ge 200 ] 2>/dev/null; then
  WANT_ES=200
else
  log "elasticsearch seeding fell short - last bulk response:"
  head -c 400 /tmp/es-bulk.resp | sed 's/^/      /'
fi

docker exec engines-influx-1 influx write --token "${INFLUX_TOKEN}" --org bgb --bucket metrics \
  --precision s "m,host=a v=1 1700000000" >/dev/null 2>&1
WANT_INFLUX=1

docker exec engines-app-1 sh -c "sqlite3 /data/app.sqlite \"CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t(v) SELECT 'x' FROM (WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<5000) SELECT n FROM c);\"" >/dev/null 2>&1
WANT_SQLITE="$(docker exec engines-app-1 sqlite3 /data/app.sqlite 'SELECT COUNT(*) FROM t;')"

eq "PostgreSQL seeded" "${WANT_PG}" "20000"
eq "MariaDB seeded" "${WANT_MY}" "20000"
eq "MongoDB seeded" "${WANT_MONGO}" "5000"
eq "Redis seeded" "${WANT_REDIS}" "5000"
eq "ClickHouse seeded" "${WANT_CH}" "20000"
eq "Elasticsearch seeded" "${WANT_ES}" "200"
eq "SQLite seeded" "${WANT_SQLITE}" "5000"
[ "${WANT_INFLUX}" = "1" ]
ck $? "InfluxDB seeded"

# -----------------------------------------------------------------------------
sect "3. bg-backup sees all eight"

printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass
SOURCE_DIR="${SRC}" INSTALL_METHOD=local INIT_REPO=1 \
  BGB_REPOSITORY="${REPO}" BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY="${BGB_IT_ACCESS_KEY}" BGB_S3_SECRET_KEY="${BGB_IT_SECRET_KEY}" \
  BGB_S3_REGION="${BGB_IT_REGION}" \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1
ck $? "install.sh succeeds"

cat >/etc/bg-backup/conf.d/50-eng.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="docker"
JOB_DOCKER_DISCOVER=1
JOB_DB_DUMP=1
JOB_DB_RECORD_COUNTS=1
JOB_QUIESCE="none"
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-eng.conf

# NOTE: JOB_DB_ENGINES is deliberately NOT set - this asserts the shipped
# DEFAULT covers every engine. It used to list five, so influxdb, clickhouse,
# elasticsearch and sqlite were filtered out of the plan on every host.
bg-backup discover >/tmp/discover.log 2>&1
ck $? "discover succeeds"
for e in postgres mysql mongodb redis influxdb clickhouse elasticsearch sqlite; do
  grep -qE "[[:space:]]${e}[[:space:]]" /tmp/discover.log \
    && ok "discover lists ${e}" || bad "discover does NOT list ${e}"
done

# -----------------------------------------------------------------------------
sect "4. One backup, every engine dumped"

bg-backup backup eng >/tmp/backup.log 2>&1
BRC=$?
grep -q 'Database dumps: 8 attempted, 0 failed' /tmp/backup.log
ck $? "all eight engines were dumped, none failed"
grep -q 'Database dumps: 8 attempted, 0 failed' /tmp/backup.log \
  || grep -E 'Database dumps:|FAILED|DEGRADED' /tmp/backup.log | sed 's/^/      /'

# DEGRADED is a real outcome and must not be hidden - but with this stack
# configured correctly (mongo replica set, clickhouse backup disk, es path.repo)
# there is nothing left to degrade.
! grep -q 'DEGRADED' /tmp/backup.log
ck $? "no engine reported a degraded dump (got exit ${BRC})"
grep -q 'DEGRADED' /tmp/backup.log && grep 'DEGRADED' /tmp/backup.log | sed 's/^/      /'

# -----------------------------------------------------------------------------
sect "5. Every engine produced a retrievable dump"

RUN="$(bg-backup snapshots --job eng --json | jq -r 'sort_by(.time) | last | .tags[] | select(startswith("run="))' | sed 's/^run=//')"
[ -n "${RUN}" ]
ck $? "the run id was recorded: ${RUN:-none}"

for e in postgres mysql mongodb redis influxdb clickhouse elasticsearch sqlite; do
  n="$(bg-backup snapshots --job eng --json \
    | jq --arg r "run=${RUN}" --arg d "db=${e}" \
      '[.[] | select(.tags | index($r)) | select(.tags | index($d))] | length')"
  [ "${n}" -ge 1 ] && ok "${e}: ${n} dump snapshot(s)" || bad "${e}: no dump snapshot"
done

# The bytes must actually come back, per dump, by name.
while IFS= read -r p; do
  [ -n "${p}" ] || continue
  spec="${p#/db/}"
  bg-backup restore db --db "${spec}" --into - >/tmp/d.bin 2>/tmp/d.err
  rc=$?
  sz="$(stat -c %s /tmp/d.bin 2>/dev/null || echo 0)"
  if [ "${rc}" -eq 0 ] && [ "${sz}" -gt 100 ]; then
    ok "restore db ${spec} (${sz} bytes)"
  else
    bad "restore db ${spec} (rc=${rc}, ${sz} bytes)"
    head -2 /tmp/d.err | sed 's/^/      /'
  fi
done < <(bg-backup snapshots --job eng --tag kind=dbdump --json | jq -r '.[].paths[0]' | sort -u)

# -----------------------------------------------------------------------------
sect "6. The dumps are the real thing, not empty files"

# Per-engine content markers. A dump of the right size can still be a header
# with no rows, which is the failure this whole project exists to prevent.
check_marker() { # <path-fragment> <grep-pattern> <label>
  local frag="$1" pat="$2" label="$3" path
  path="$(bg-backup snapshots --job eng --tag kind=dbdump --json \
    | jq -r --arg f "${frag}" '[.[].paths[0] | select(contains($f))] | last // empty')"
  if [ -z "${path}" ]; then
    bad "${label}: no dump path matched '${frag}'"
    return
  fi
  bg-backup restore db --db "${path#/db/}" --into - 2>/dev/null | head -c 4000000 >/tmp/m.bin
  if grep -qa "${pat}" /tmp/m.bin; then ok "${label} carries its data"; else bad "${label} has no '${pat}'"; fi
}

check_marker "/db/postgres/" 'PGDMP' "the PostgreSQL archive"
check_marker "/db/mysql/" 'INSERT INTO' "the MariaDB dump"
check_marker "/db/sqlite/" 'SQLite format 3' "the SQLite copy"
check_marker "/db/redis/" 'REDIS' "the Redis RDB"

# -----------------------------------------------------------------------------
sect "7. No secret leaked"

bg-backup doctor >/tmp/doctor.log 2>&1 || true
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/doctor.log
ck $? "no passphrase in doctor output"
! grep -qE "${MY_PW}|${MONGO_PW}|${INFLUX_TOKEN}" /tmp/backup.log
ck $? "no database credential in the backup log"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
