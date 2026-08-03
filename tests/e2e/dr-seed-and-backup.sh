#!/usr/bin/env bash
# =============================================================================
# DR rehearsal, part 1: seed a realistic host and back it up
# =============================================================================
# Databases run NATIVELY here, not in docker-in-docker. It proves the same
# property - dump, destroy, restore, compare - without a privileged DinD that
# will be flaky in CI.
#
# The file tree is chosen for the things that actually go wrong in a restore:
# sparse files, hardlinks, symlinks, a UTF-8 name, restrictive modes with a
# non-root owner, and an xattr. Content checksums alone would miss every one.
# =============================================================================

set -uo pipefail

SRC=/opt/bgb
EV=/evidence
export DEBIAN_FRONTEND=noninteractive

log() { printf '\033[32m[seed]\033[0m %s\n' "$*"; }
die() {
  printf '\033[31m[seed]\033[0m %s\n' "$*" >&2
  exit 1
}

install -d -m 0755 "${EV}"

# -----------------------------------------------------------------------------
log "Installing PostgreSQL and MariaDB"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  postgresql mariadb-server jq attr acl >/dev/null

PGBIN="$(find /usr/lib/postgresql -maxdepth 2 -name pg_ctl -type f | head -n1)"
PGDIR="$(dirname "${PGBIN}")"
pg_ctlcluster "$(ls /etc/postgresql | head -n1)" main start || service postgresql start
service mariadb start || service mysql start
sleep 5

# -----------------------------------------------------------------------------
log "Seeding PostgreSQL"
su - postgres -c "psql -q -c \"CREATE DATABASE dr_test;\"" || die "createdb failed"
su - postgres -c "psql -q -d dr_test -c \"
  CREATE TABLE t (id int primary key, payload text);
  INSERT INTO t SELECT g, md5(g::text) FROM generate_series(1,50000) g;
\"" || die "seed failed"

# Order-insensitive and layout-insensitive: a physical reorganisation during
# dump/restore must not look like data loss.
PG_FP="$(su - postgres -c "psql -tAq -d dr_test -c \"
  SELECT md5(string_agg(t::text, '|' ORDER BY id)) FROM t;\"")"
PG_ROWS="$(su - postgres -c "psql -tAq -d dr_test -c 'SELECT count(*) FROM t;'")"
log "postgres fingerprint=${PG_FP} rows=${PG_ROWS}"

# -----------------------------------------------------------------------------
log "Seeding MariaDB"
mariadb -e "CREATE DATABASE dr_test;" 2>/dev/null || mysql -e "CREATE DATABASE dr_test;"
MY="$(command -v mariadb || command -v mysql)"

# The CLIENT and the DUMP TOOL are different binaries with disjoint options.
# `mariadb --single-transaction --all-databases` fails with "unknown option"
# and leaves an EMPTY dump file behind - which then gets backed up and
# "restored" without anyone noticing, because this harness runs without -e.
MYDUMP="$(command -v mariadb-dump || command -v mysqldump)" \
  || die "neither mariadb-dump nor mysqldump is installed"
[ -n "${MYDUMP}" ] || die "neither mariadb-dump nor mysqldump is installed"

# max_recursive_iterations defaults to 1000, so a 50k-row recursive CTE aborts
# with "query exceeded max_recursive_iterations" and inserts NOTHING. The table
# stayed empty, the fingerprint was the literal string NULL, and the restore
# assertion then compared NULL against NULL and passed.
"${MY}" dr_test <<'SQL'
SET SESSION max_recursive_iterations = 1000000;
CREATE TABLE t (id INT PRIMARY KEY, payload VARCHAR(64)) ENGINE=InnoDB;
INSERT INTO t (id, payload)
  WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 50000)
  SELECT n, MD5(n) FROM s;
SQL
[ $? -eq 0 ] || die "seeding MariaDB failed"

# CHECKSUM TABLE alone can differ across storage-engine internals and would give
# a false negative, so an ordered content hash is taken as well.
MY_CHK="$("${MY}" -N -B dr_test -e "CHECKSUM TABLE t EXTENDED;" | awk '{print $2}')"
MY_FP="$("${MY}" -N -B dr_test -e "SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,payload) ORDER BY id SEPARATOR ';')) FROM t;")"
MY_ROWS="$("${MY}" -N -B dr_test -e "SELECT COUNT(*) FROM t;")"
log "mariadb checksum=${MY_CHK} fingerprint=${MY_FP} rows=${MY_ROWS}"

# A rehearsal that restores an empty table proves nothing, so refuse to build on
# one. This check is what turns the two bugs above from "silently pointless" into
# "loudly broken".
[ "${MY_ROWS:-0}" -eq 50000 ] || die "MariaDB seed produced ${MY_ROWS:-0} rows, expected 50000"
[ -n "${MY_FP}" ] && [ "${MY_FP}" != "NULL" ] || die "MariaDB fingerprint is NULL - the table is empty"
[ "${PG_ROWS:-0}" -eq 50000 ] || die "PostgreSQL seed produced ${PG_ROWS:-0} rows, expected 50000"

# -----------------------------------------------------------------------------
log "Seeding the file tree"
D=/srv/data
install -d -m 0755 "${D}/sub"

: >"${D}/size-0.bin"
printf 'x' >"${D}/size-1.bin"
head -c 4096 /dev/urandom >"${D}/size-4k.bin"
head -c 104857600 /dev/urandom >"${D}/size-100m.bin"

# Sparse: 1 GiB apparent, a few blocks actual.
dd if=/dev/zero of="${D}/sparse.bin" bs=1 count=0 seek=1G status=none

ln -sf size-4k.bin "${D}/symlink.bin"
cp "${D}/size-1.bin" "${D}/hardlink-a.bin"
ln "${D}/hardlink-a.bin" "${D}/hardlink-b.bin"

printf 'umlauts\n' >"${D}/Grüße-äöü-日本語.txt"

useradd -m -u 4242 druser 2>/dev/null || true
printf 'restricted\n' >"${D}/sub/restricted.txt"
chown druser:druser "${D}/sub/restricted.txt"
chmod 0600 "${D}/sub/restricted.txt"

setfattr -n user.bgb -v "rehearsal" "${D}/size-4k.bin" 2>/dev/null || true

# Content plus METADATA. The metadata manifest is what catches a restore that
# reproduces bytes and loses modes, owners or link structure.
(cd "${D}" && find . -type f -exec sha256sum {} + | sort -k2) >"${EV}/files.sha256"
(cd "${D}" && find . -printf '%p|%y|%m|%U|%G|%s|%n\n' | sort) >"${EV}/files.meta"

# -----------------------------------------------------------------------------
log "Installing bg-backup and configuring the repository"
printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass

SOURCE_DIR="${SRC}" INSTALL_METHOD=local \
  INIT_REPO=1 \
  BGB_REPOSITORY="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}" \
  BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY="${BGB_IT_ACCESS_KEY}" \
  BGB_S3_SECRET_KEY="${BGB_IT_SECRET_KEY}" \
  BGB_S3_REGION="${BGB_IT_REGION}" \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1 || die "install failed"

cat >/etc/bg-backup/conf.d/50-dr.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/data /etc/bg-backup )
JOB_ONE_FILE_SYSTEM=0
JOB_EXCLUDE_FILE=""
JOB_TAGS=( stopped )
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="service-stop"
JOB_QUIESCE_UNITS=( postgresql mariadb )
JOB_PRE_HOOKS=( /opt/bg-backup/current/share/hooks/collect-system-facts.sh )
CONF
chmod 0640 /etc/bg-backup/conf.d/50-dr.conf

# -----------------------------------------------------------------------------
log "Dumping the databases"
install -d -m 0700 /srv/dumps
su - postgres -c "pg_dumpall --globals-only" >/srv/dumps/pg-globals.sql
su - postgres -c "pg_dump -Fc dr_test" >/srv/dumps/pg-dr_test.dump
"${MYDUMP}" --single-transaction --quick --routines --triggers --events \
  --hex-blob --all-databases >/srv/dumps/my-all.sql \
  || die "mariadb-dump failed"

# An empty dump is the failure this rehearsal exists to catch, so assert it
# here rather than discovering it during the restore. 10 KiB is comfortably
# below a real 50k-row dump and comfortably above a header-only stub.
for f in /srv/dumps/pg-globals.sql /srv/dumps/pg-dr_test.dump /srv/dumps/my-all.sql; do
  [ -s "${f}" ] || die "dump ${f} is empty"
done
[ "$(stat -c %s /srv/dumps/my-all.sql)" -gt 10240 ] \
  || die "my-all.sql is only $(stat -c %s /srv/dumps/my-all.sql) bytes - the dump did not contain the data"
grep -q 'INSERT INTO' /srv/dumps/my-all.sql \
  || die "my-all.sql contains no INSERT statements"

(cd /srv && find dumps -type f -exec sha256sum {} + | sort -k2) >>"${EV}/files.sha256"

# -----------------------------------------------------------------------------
log "Backing up"
sed -i 's|JOB_PATHS=( /srv/data /etc/bg-backup )|JOB_PATHS=( /srv/data /srv/dumps /etc/bg-backup )|' \
  /etc/bg-backup/conf.d/50-dr.conf

bg-backup backup dr >/tmp/backup.log 2>&1
RC=$?
[ "${RC}" -eq 0 ] || [ "${RC}" -eq 3 ] || die "backup failed with rc=${RC}"
log "backup rc=${RC}"

SNAP="$(bg-backup snapshots --job dr --json | jq -r 'sort_by(.time) | last | .short_id')"
RUN="$(bg-backup snapshots --job dr --json | jq -r 'sort_by(.time) | last | .tags[] | select(startswith("run="))')"

# -----------------------------------------------------------------------------
# The negative control. This file is created AFTER the snapshot and must NOT
# appear in the restore. Without it, a rehearsal that accidentally reads from a
# live mount still passes.
log "Writing the post-snapshot canary"
printf 'this must NOT survive the restore\n' >"${D}/AFTER-SNAPSHOT.txt"

# -----------------------------------------------------------------------------
log "Recording evidence"
{
  printf '{'
  printf '"snapshot":"%s",' "${SNAP}"
  printf '"run":"%s",' "${RUN#run=}"
  printf '"pg_fingerprint":"%s","pg_rows":%s,' "${PG_FP}" "${PG_ROWS}"
  printf '"my_checksum":"%s","my_fingerprint":"%s","my_rows":%s,' "${MY_CHK}" "${MY_FP}" "${MY_ROWS}"
  printf '"backup_rc":%s' "${RC}"
  printf '}\n'
} >"${EV}/before.json"

cat "${EV}/before.json"
log "Seed complete. Snapshot ${SNAP}, run ${RUN#run=}"
