#!/usr/bin/env bash
# =============================================================================
# e2e: the docker path, end to end, against a real Docker daemon
# =============================================================================
# JOB_MODE=docker, the database dump modules and restore project/db had never
# been executed before this test existed. The first real run of them found nine
# defects, every one of which would have hit the first production host:
#
#   * every PostgreSQL dump failed (psql wrote a formatted table where a raw
#     snapshot id was expected)
#   * every MySQL/MariaDB dump failed (splicing shell code through a bash
#     substitution halved its backslashes and broke a sed expression)
#   * every notifier was dead (the provider was sourced inside a command
#     substitution, so it never existed in the calling shell)
#   * the Prometheus textfile was never written (three functions called, none
#     defined)
#   * the image manifest recorded no pullable reference, and the "pull by
#     digest" step passed a hardcoded empty string
#   * `restore db` always resolved to the LAST dump of the run
#   * the globals dump carried two kind= tags, inflating `runs list`
#
# THIS SCRIPT MUST RUN INSIDE tests/rig/Dockerfile.docker-victim, which is
# privileged and runs its own dockerd. The host daemon is not an option: named
# volume contents are read straight from /var/lib/docker/volumes/<v>/_data.
# =============================================================================

# The assertion idiom here is deliberately `[ condition ]; ck $?`.
# shellcheck disable=SC2319
set -uo pipefail

SRC=/opt/bgb
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$(( PASS + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
ck()   { [ "$1" -eq 0 ] && ok "$2" || bad "$2"; }
eq()   { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected '$3', got '$2'"; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }
log()  { printf '\033[36m[stack]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[stack]\033[0m %s\n' "$*" >&2; exit 1; }

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# -----------------------------------------------------------------------------
sect "0. A Docker daemon of our own"

if ! docker info >/dev/null 2>&1; then
  log "starting dockerd"
  dockerd >/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
docker info >/dev/null 2>&1; ck $? "dockerd is up"
docker info >/dev/null 2>&1 || { tail -20 /var/log/dockerd.log; exit 1; }
docker compose version >/dev/null 2>&1; ck $? "the compose plugin is available"

# -----------------------------------------------------------------------------
sect "1. A realistic stack"

install -d /srv/stack/site /srv/stack/uploads /evidence

cat >/srv/stack/.env <<'ENV'
POSTGRES_PASSWORD=pg-throwaway-rig-pw
MARIADB_ROOT_PASSWORD=my-throwaway-rig-pw
APP_TITLE=bgb-rig
ENV

# The subnet is pinned deliberately, and it is worth being precise about what
# that proves: compose recreates it from THIS file. bg-backup records the subnet
# in its manifest but does not recreate it, so a compose file that leaves the
# subnet to the daemon would come back on a different one. See section 7.
cat >/srv/stack/docker-compose.yml <<'YML'
name: shop

services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: shopdb
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s
      timeout: 3s
      retries: 20
    networks: [back]

  mysqldb:
    image: mariadb:11
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: shopmy
    volumes:
      - mydata:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -uroot -p$$MARIADB_ROOT_PASSWORD || exit 1"]
      interval: 3s
      timeout: 3s
      retries: 20
    networks: [back]

  web:
    image: nginx:alpine
    environment:
      APP_TITLE: ${APP_TITLE}
    volumes:
      - appdata:/var/cache/app
      - /srv/stack/site:/usr/share/nginx/html:ro
      - /srv/stack/uploads:/uploads
    networks: [back]

volumes:
  pgdata:
  mydata:
  appdata:

networks:
  back:
    ipam:
      config:
        - subnet: 172.31.77.0/24
YML

log "starting the stack"
( cd /srv/stack && docker compose up -d ) >/tmp/up.log 2>&1 || { tail -20 /tmp/up.log; die "compose up failed"; }

for _ in $(seq 1 90); do
  h1="$(docker inspect --format '{{.State.Health.Status}}' shop-db-1      2>/dev/null || echo none)"
  h2="$(docker inspect --format '{{.State.Health.Status}}' shop-mysqldb-1 2>/dev/null || echo none)"
  [ "${h1}" = healthy ] && [ "${h2}" = healthy ] && break
  sleep 2
done

# "healthy" is not "ready". The official mariadb image runs a TEMPORARY server
# for initialisation and the healthcheck can pass against it; the socket then
# disappears while the real server starts, and a query issued in that window
# fails with "Can't connect to local server through socket". Wait for a real
# query instead.
for _ in $(seq 1 60); do
  docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 \
    mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1
ck $? "MariaDB answers a query"
docker exec shop-db-1 psql -U postgres -d shopdb -tAq -c 'SELECT 1' >/dev/null 2>&1
ck $? "PostgreSQL answers a query"

log "seeding"
docker exec -i shop-db-1 psql -U postgres -d shopdb -v ON_ERROR_STOP=1 -q <<'SQL' || die "postgres seed failed"
CREATE TABLE orders (id INT PRIMARY KEY, payload TEXT);
INSERT INTO orders SELECT g, md5(g::text) FROM generate_series(1,50000) g;
CREATE ROLE shopuser LOGIN PASSWORD 'shop-throwaway';
GRANT ALL ON orders TO shopuser;
SQL

# max_recursive_iterations defaults to 1000, so a 50k-row recursive CTE inserts
# NOTHING and every later comparison comes out NULL = NULL.
docker exec -i -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -uroot shopmy <<'SQL' || die "mariadb seed failed"
SET SESSION max_recursive_iterations = 1000000;
CREATE TABLE items (id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE=InnoDB;
INSERT INTO items (id, payload)
  WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 50000)
  SELECT n, MD5(n) FROM s;
SQL

docker exec shop-web-1 sh -c 'mkdir -p /var/cache/app && head -c 65536 /dev/urandom >/var/cache/app/cache.bin'
printf '<h1>bgb rig</h1>\n' >/srv/stack/site/index.html
head -c 32768 /dev/urandom >/srv/stack/uploads/blob.bin

WANT_PG_ROWS="$(docker exec shop-db-1 psql -U postgres -d shopdb -tAq -c 'SELECT count(*) FROM orders;')"
WANT_PG_FP="$(docker exec shop-db-1 psql -U postgres -d shopdb -tAq -c "SELECT md5(string_agg(id::text||'|'||payload, ';' ORDER BY id)) FROM orders;")"
WANT_MY_ROWS="$(docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -N -B -uroot shopmy -e 'SELECT COUNT(*) FROM items;')"
WANT_MY_FP="$(docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -N -B -uroot shopmy -e "SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,payload) ORDER BY id SEPARATOR ';')) FROM items;")"
WANT_VOL_FP="$(docker exec shop-web-1 sha256sum /var/cache/app/cache.bin | awk '{print $1}')"
WANT_BIND_FP="$(sha256sum /srv/stack/uploads/blob.bin | awk '{print $1}')"
WANT_SUBNET="$(docker network inspect shop_back --format '{{(index .IPAM.Config 0).Subnet}}')"

# A rehearsal that restores an empty table proves nothing.
eq "PostgreSQL seeded" "${WANT_PG_ROWS}" "50000"
eq "MariaDB seeded"    "${WANT_MY_ROWS}" "50000"
[ -n "${WANT_MY_FP}" ] && [ "${WANT_MY_FP}" != "NULL" ]; ck $? "MariaDB fingerprint is a real value"

# -----------------------------------------------------------------------------
sect "2. Install and configure the docker job"

printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass

SOURCE_DIR="${SRC}" INSTALL_METHOD=local INIT_REPO=1 \
  BGB_REPOSITORY="${REPO}" BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY="${BGB_IT_ACCESS_KEY}" BGB_S3_SECRET_KEY="${BGB_IT_SECRET_KEY}" \
  BGB_S3_REGION="${BGB_IT_REGION}" \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1
ck $? "install.sh succeeds on a docker host"

cat >/etc/bg-backup/conf.d/50-dock.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="docker"
JOB_DOCKER_DISCOVER=1
JOB_DOCKER_PROJECTS=()
JOB_DOCKER_EXCLUDE_PROJECTS=()
JOB_DOCKER_INCLUDE_COMPOSE_FILES=1
JOB_DOCKER_INCLUDE_ENV_FILES=1
JOB_DOCKER_INCLUDE_NAMED_VOLUMES=1
JOB_DOCKER_INCLUDE_BIND_MOUNTS=1
JOB_DOCKER_IMAGE_MANIFEST=1
JOB_DOCKER_NETWORK_MANIFEST=1
JOB_DOCKER_EXPORT_IMAGES="missing"
JOB_DOCKER_INCLUDE_OVERLAY2=0
JOB_DOCKER_EXTRA_PATHS=( /etc/docker )
JOB_DB_DUMP=1
JOB_DB_ENGINES=( postgres mysql mariadb )
JOB_DB_EXCLUDE_CONTAINERS=()
JOB_DB_DUMP_TIMEOUT="3600"
JOB_DB_DUMP_COMPRESS=0
JOB_DB_RECORD_COUNTS=1
JOB_QUIESCE="docker-pause"
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-dock.conf

bg-backup config validate >/tmp/validate.log 2>&1
ck $? "the docker job passes the config linter"

bg-backup discover >/tmp/discover.log 2>&1
ck $? "discover succeeds"
grep -q 'shop' /tmp/discover.log; ck $? "discover finds the compose project"

# -----------------------------------------------------------------------------
sect "3. The backup itself"

bg-backup backup dock >/tmp/backup.log 2>&1
BRC=$?
[ "${BRC}" -eq 0 ]; ck $? "backup exits 0 (got ${BRC})"
[ "${BRC}" -eq 0 ] || sed 's/^/      /' /tmp/backup.log | grep -vE '^\s+\{' | tail -20

# The single most important assertion in this file. A dump that fails must not
# be able to look like a success, and a dump that "succeeds" without producing
# data is the failure mode this whole project exists to prevent.
grep -q 'Database dumps: 2 attempted, 0 failed' /tmp/backup.log
ck $? "both database dumps succeeded"

grep -qi 'command not found' /tmp/backup.log && bad "something called an undefined function during the run" \
  || ok "no undefined function was called during the run"

# docker-pause must always be reversed.
docker ps --filter 'status=paused' --format '{{.Names}}' >/tmp/paused.txt 2>/dev/null
[ ! -s /tmp/paused.txt ]; ck $? "no container was left paused"
RUNNING="$(docker ps --format '{{.Names}}' | wc -l)"
eq "all three containers still run" "${RUNNING}" "3"

# -----------------------------------------------------------------------------
sect "4. What the run recorded"

RUN="$(bg-backup snapshots --job dock --json | jq -r 'sort_by(.time) | last | .tags[] | select(startswith("run="))' | sed 's/^run=//')"
[ -n "${RUN}" ]; ck $? "the run id was recorded: ${RUN:-none}"

N_DUMP="$(bg-backup snapshots --job dock --json | jq --arg r "run=${RUN}" '[.[] | select(.tags | index($r)) | select(.tags | index("kind=dbdump"))] | length')"
eq "four dump snapshots exist" "${N_DUMP}" "4"

N_FILES="$(bg-backup snapshots --job dock --json | jq --arg r "run=${RUN}" '[.[] | select(.tags | index($r)) | select(.tags | index("kind=files"))] | length')"
eq "exactly one file snapshot exists" "${N_FILES}" "1"

# A snapshot must never carry two tags with the same key: `runs list` extracts
# kind= with a filter that then yields two values and emits two rows for one
# snapshot, inflating the run.
DUP="$(bg-backup snapshots --job dock --json \
  | jq '[.[] | select([.tags[] | select(startswith("kind="))] | length > 1)] | length')"
eq "no snapshot carries two kind= tags" "${DUP}" "0"

MF=/var/lib/bg-backup/facts/docker-manifest.json
[ -r "${MF}" ]; ck $? "the docker manifest was written"

# image_ref is what makes a restore reproducible. image_id is the LOCAL config
# id and identifies nothing a fresh host can pull.
NO_REF="$(jq '[.projects[].containers[] | select((.image_ref // "") == "")] | length' "${MF}")"
eq "every container has a pullable image_ref" "${NO_REF}" "0"
DIGESTS="$(jq -r '[.projects[].containers[].image_ref | select(test("@sha256:"))] | length' "${MF}")"
[ "${DIGESTS}" -ge 1 ]; ck $? "at least one image_ref is a registry digest (${DIGESTS})"

SUBNET_IN_MF="$(jq -r '.networks[] | select(.name=="shop_back") | .ipam.Config[0].Subnet' "${MF}")"
eq "the network subnet is in the manifest" "${SUBNET_IN_MF}" "${WANT_SUBNET}"

# -----------------------------------------------------------------------------
sect "5. Every dump is individually retrievable"

# Each dump is its own single-file snapshot and they all carry kind=dbdump, so
# selecting on the tag alone returns whichever engine was dumped LAST. Ask for
# each one by name and check the bytes actually arrive.
while IFS= read -r p; do
  [ -n "${p}" ] || continue
  spec="${p#/db/}"
  bg-backup restore db --db "${spec}" --into - >/tmp/dump.bin 2>/tmp/dump.err
  rc=$?
  sz="$(stat -c %s /tmp/dump.bin 2>/dev/null || echo 0)"
  if [ "${rc}" -eq 0 ] && [ "${sz}" -gt 0 ]; then
    ok "restore db ${spec} (${sz} bytes)"
  else
    bad "restore db ${spec} (rc=${rc}, ${sz} bytes)"
    head -2 /tmp/dump.err | sed 's/^/      /'
  fi
done < <(bg-backup snapshots --job dock --tag kind=dbdump --json | jq -r '.[].paths[0]' | sort -u)

# -----------------------------------------------------------------------------
sect "6. Destroy everything"

( cd /srv/stack && docker compose down -v ) >/dev/null 2>&1
rm -rf /srv/stack
docker image rm -f postgres:16-alpine mariadb:11 nginx:alpine >/dev/null 2>&1
docker volume ls -q | xargs -r docker volume rm -f >/dev/null 2>&1
docker network rm shop_back >/dev/null 2>&1

[ ! -d /srv/stack ];                      ck $? "the compose files are gone"
[ "$(docker ps -aq | wc -l)" -eq 0 ];     ck $? "no container remains"
[ "$(docker volume ls -q | wc -l)" -eq 0 ]; ck $? "no volume remains"

# -----------------------------------------------------------------------------
sect "7. Restore the project"

cd /
bg-backup restore project --name shop --run "${RUN}" --recreate --yes >/tmp/restore.log 2>&1
RRC=$?
[ "${RRC}" -eq 0 ]; ck $? "restore project --recreate exits 0 (got ${RRC})"
[ "${RRC}" -eq 0 ] || tail -15 /tmp/restore.log | sed 's/^/      /'

[ -f /srv/stack/docker-compose.yml ]; ck $? "the compose file came back"
# .env is a dotfile: an `ls` without -a hides it, which is an easy way to
# believe it was lost when it was not.
[ -f /srv/stack/.env ];              ck $? "the .env came back"
grep -q 'POSTGRES_PASSWORD' /srv/stack/.env; ck $? "the .env still carries its values"

for _ in $(seq 1 60); do
  docker exec shop-db-1 psql -U postgres -d shopdb -tAq -c 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
for _ in $(seq 1 60); do
  docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done

# -----------------------------------------------------------------------------
sect "8. The data is the same data"

GOT_PG_ROWS="$(docker exec shop-db-1 psql -U postgres -d shopdb -tAq -c 'SELECT count(*) FROM orders;' 2>/dev/null)"
GOT_PG_FP="$(docker exec shop-db-1 psql -U postgres -d shopdb -tAq -c "SELECT md5(string_agg(id::text||'|'||payload, ';' ORDER BY id)) FROM orders;" 2>/dev/null)"
GOT_ROLE="$(docker exec shop-db-1 psql -U postgres -tAq -c "SELECT count(*) FROM pg_roles WHERE rolname='shopuser';" 2>/dev/null)"
GOT_MY_ROWS="$(docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -N -B -uroot shopmy -e 'SELECT COUNT(*) FROM items;' 2>/dev/null)"
GOT_MY_FP="$(docker exec -e MYSQL_PWD=my-throwaway-rig-pw shop-mysqldb-1 mariadb -N -B -uroot shopmy -e "SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,payload) ORDER BY id SEPARATOR ';')) FROM items;" 2>/dev/null)"
GOT_VOL_FP="$(docker exec shop-web-1 sha256sum /var/cache/app/cache.bin 2>/dev/null | awk '{print $1}')"
GOT_BIND_FP="$(sha256sum /srv/stack/uploads/blob.bin 2>/dev/null | awk '{print $1}')"
GOT_SUBNET="$(docker network inspect shop_back --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)"

eq "PostgreSQL row count"      "${GOT_PG_ROWS}"  "${WANT_PG_ROWS}"
eq "PostgreSQL fingerprint"    "${GOT_PG_FP}"    "${WANT_PG_FP}"
eq "PostgreSQL role survived"  "${GOT_ROLE}"     "1"
eq "MariaDB row count"         "${GOT_MY_ROWS}"  "${WANT_MY_ROWS}"
eq "MariaDB fingerprint"       "${GOT_MY_FP}"    "${WANT_MY_FP}"
eq "named volume contents"     "${GOT_VOL_FP}"   "${WANT_VOL_FP}"
eq "bind mount contents"       "${GOT_BIND_FP}"  "${WANT_BIND_FP}"

# NOTE ON THIS ONE: compose recreates the subnet from the compose file, which
# pins it. bg-backup records the subnet in the manifest but does not recreate
# it, so a compose file that leaves the subnet to the daemon would come back on
# a different one. This assertion proves the manifest and the stack agree - not
# that bg-backup would restore an unpinned subnet.
eq "network subnet"            "${GOT_SUBNET}"   "${WANT_SUBNET}"

# -----------------------------------------------------------------------------
sect "9. No secret leaked along the way"

bg-backup doctor >/tmp/doctor.log 2>&1 || true
! grep -q "${BGB_IT_SECRET_KEY}" /tmp/doctor.log;      ck $? "no S3 secret in doctor output"
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/doctor.log; ck $? "no passphrase in doctor output"
! grep -rq 'pg-throwaway-rig-pw' /tmp/backup.log;      ck $? "no database password in the backup log"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
