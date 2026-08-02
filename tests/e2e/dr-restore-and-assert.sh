#!/usr/bin/env bash
# =============================================================================
# DR rehearsal, part 2: recover on a host that has never seen the data
# =============================================================================
# This container receives ONLY what the recovery sheet lists: the repository
# URL, the passphrase and the backend credentials. If the rehearsal needs
# anything else, the recovery sheet is wrong - and that is the finding, not an
# inconvenience.
# =============================================================================

# The assertion idiom here is deliberately `[ condition ]; ck $?` - $? IS the
# condition's status, which is exactly what we want to report. ShellCheck flags
# that shape generically, so it is disabled for these harness files only.
# shellcheck disable=SC2319
set -uo pipefail

SRC=/opt/bgb
EV=/evidence
export DEBIAN_FRONTEND=noninteractive

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$(( PASS + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
ck()   { [ "$1" -eq 0 ] && ok "$2" || bad "$2"; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }
log()  { printf '\033[32m[phoenix]\033[0m %s\n' "$*"; }

[ -r "${EV}/before.json" ] || { echo "no evidence from the seed phase" >&2; exit 1; }
BEFORE="$(cat "${EV}/before.json")"
jq -r . <<<"${BEFORE}" >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null; }

WANT_RUN="$(jq -r '.run'            <<<"${BEFORE}")"
WANT_PG_FP="$(jq -r '.pg_fingerprint' <<<"${BEFORE}")"
WANT_PG_ROWS="$(jq -r '.pg_rows'      <<<"${BEFORE}")"
WANT_MY_FP="$(jq -r '.my_fingerprint' <<<"${BEFORE}")"
WANT_MY_ROWS="$(jq -r '.my_rows'      <<<"${BEFORE}")"

# -----------------------------------------------------------------------------
sect "1. Recovery with only what the sheet lists"

# Exactly the four facts from section 1 of the recovery sheet.
REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass

SOURCE_DIR="${SRC}" INSTALL_METHOD=local \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1
ck $? "install.sh runs on a host that has never seen this data"

# The backend credentials must be in the environment BEFORE bootstrap: it takes
# only --repo and --password-file, and its last step is to prove the repository
# is reachable. Exporting them afterwards made that proof fail while everything
# downstream still worked, so bootstrap reported an error nobody acted on.
# This ordering is also what the recovery sheet tells a human to do.
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

bg-backup dr bootstrap \
  --repo "${REPO}" \
  --password-file /root/.bgb-pass >/tmp/bootstrap.log 2>&1
BOOT_RC=$?
# BOOT_RC was collected and only reported in the closing JSON, so a bootstrap
# that died on its first line produced eleven downstream FAILs and no statement
# about the actual cause. Assert it where it happens.
[ "${BOOT_RC}" -eq 0 ]; ck $? "dr bootstrap exits 0"
[ "${BOOT_RC}" -eq 0 ] || sed 's/^/      /' /tmp/bootstrap.log | head -10

bg-backup snapshots >/tmp/snapshots.log 2>&1
ck $? "the repository is reachable with only the sheet's credentials"

# -----------------------------------------------------------------------------
sect "2. Restore BY RUN"

# Not by "latest" per snapshot: a run groups the file tree and every dump, and
# resolving each independently pairs Monday's database with Tuesday's files.
bg-backup restore dir --path /srv --run "${WANT_RUN}" --to /tmp/restore >/tmp/restore.log 2>&1
RESTORE_RC=$?
[ "${RESTORE_RC}" -eq 0 ]; ck $? "restore --run ${WANT_RUN} exits 0"
[ "${RESTORE_RC}" -eq 0 ] || sed 's/^/      /' /tmp/restore.log | head -10

R="$(find /tmp/restore -type d -name data -path '*/srv/*' 2>/dev/null | head -n1)"
[ -n "${R}" ]; ck $? "the restored /srv/data was found"
DUMPS="$(find /tmp/restore -type d -name dumps -path '*/srv/*' 2>/dev/null | head -n1)"
[ -n "${DUMPS}" ]; ck $? "the restored dumps were found"
# Without a placeholder an empty DUMPS turns "${DUMPS}/my-all.sql" into the
# absolute path /my-all.sql, and the harness then reports a confusing
# "No such file or directory" for a file it never meant to name.
: "${R:=/nonexistent-restore-root}"
: "${DUMPS:=/nonexistent-dumps-dir}"

# -----------------------------------------------------------------------------
sect "3. The negative control"

# Created AFTER the snapshot. Its presence would mean the restore read live data
# rather than the repository - and every other assertion would pass anyway.
[ ! -e "${R}/AFTER-SNAPSHOT.txt" ]
ck $? "the post-snapshot file is ABSENT from the restore"

# -----------------------------------------------------------------------------
sect "4. Content and metadata"

( cd "${R}" && find . -type f -exec sha256sum {} + | sort -k2 ) >/tmp/after-files.sha256
grep -v '^.*  ./dumps' "${EV}/files.sha256" | grep -E '  \./' | sort -k2 >/tmp/before-files.sha256 || true
diff <(grep -E '  \./(size|sub|symlink|hardlink|Gr|sparse)' /tmp/before-files.sha256 | sort -k2) \
     <(grep -E '  \./(size|sub|symlink|hardlink|Gr|sparse)' /tmp/after-files.sha256  | sort -k2) >/dev/null 2>&1
ck $? "file content hashes match"

[ -L "${R}/symlink.bin" ]; ck $? "symlink restored as a symlink"

# Hardlinks: restic preserves the link, so both names must share one inode.
A_INO="$(stat -c %i "${R}/hardlink-a.bin" 2>/dev/null)"
B_INO="$(stat -c %i "${R}/hardlink-b.bin" 2>/dev/null)"
[ -n "${A_INO}" ] && [ "${A_INO}" = "${B_INO}" ]
ck $? "hardlink pair shares an inode"

[ -f "${R}/size-0.bin" ] && [ ! -s "${R}/size-0.bin" ]; ck $? "zero-byte file stayed zero bytes"
# A glob rather than `ls | grep`: the filename under test is deliberately
# non-ASCII, which is exactly the case where parsing ls output goes wrong.
compgen -G "${R}/Gr*" >/dev/null; ck $? "UTF-8 filename preserved"

M="$(stat -c '%a %u' "${R}/sub/restricted.txt" 2>/dev/null)"
[ "${M}" = "600 4242" ]; ck $? "restrictive mode and non-root owner preserved (got '${M}')"

# Sparseness: the restored file must not have become 1 GiB of real blocks.
#
# Defaulted, because when an earlier step failed the file is absent, stat prints
# nothing, and the arithmetic became `$(( * ))` - a syntax error that under
# `set -u` killed the whole harness mid-report. A missing file must be a FAIL
# like any other, not the end of the run.
APPARENT="$(stat -c %s "${R}/sparse.bin" 2>/dev/null || echo 0)"
_BLOCKS="$(stat -c %b "${R}/sparse.bin" 2>/dev/null || echo 0)"
_BSIZE="$(stat -c %B "${R}/sparse.bin" 2>/dev/null || echo 0)"
ACTUAL="$(( ${_BLOCKS:-0} * ${_BSIZE:-0} ))"
[ "${APPARENT:-0}" -gt "${ACTUAL}" ]
ck $? "sparse file stayed sparse (apparent ${APPARENT:-0}, actual ${ACTUAL})"

# -----------------------------------------------------------------------------
sect "5. The databases actually load"

apt-get update -qq
apt-get install -y -qq --no-install-recommends postgresql mariadb-server >/dev/null
pg_ctlcluster "$(ls /etc/postgresql | head -n1)" main start || service postgresql start
service mariadb start || service mysql start
sleep 5

su - postgres -c "psql -q -f -" <"${DUMPS}/pg-globals.sql" >/dev/null 2>&1 || true
su - postgres -c "psql -q -c 'CREATE DATABASE dr_test;'" >/dev/null 2>&1
su - postgres -c "pg_restore -d dr_test" <"${DUMPS}/pg-dr_test.dump" >/tmp/pgrestore.log 2>&1
ck $? "the PostgreSQL dump loads"

GOT_PG_FP="$(su - postgres -c "psql -tAq -d dr_test -c \"
  SELECT md5(string_agg(t::text, '|' ORDER BY id)) FROM t;\"" 2>/dev/null)"
GOT_PG_ROWS="$(su - postgres -c "psql -tAq -d dr_test -c 'SELECT count(*) FROM t;'" 2>/dev/null)"

[ "${GOT_PG_ROWS}" = "${WANT_PG_ROWS}" ]
ck $? "PostgreSQL row count matches (${GOT_PG_ROWS} = ${WANT_PG_ROWS})"
[ "${GOT_PG_FP}" = "${WANT_PG_FP}" ]
ck $? "PostgreSQL content fingerprint matches"

MY="$(command -v mariadb || command -v mysql)"
"${MY}" <"${DUMPS}/my-all.sql" >/tmp/myrestore.log 2>&1
ck $? "the MariaDB dump loads"

GOT_MY_FP="$("${MY}" -N -B dr_test -e "SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,payload) ORDER BY id SEPARATOR ';')) FROM t;" 2>/dev/null)"
GOT_MY_ROWS="$("${MY}" -N -B dr_test -e "SELECT COUNT(*) FROM t;" 2>/dev/null)"

[ "${GOT_MY_ROWS}" = "${WANT_MY_ROWS}" ]
ck $? "MariaDB row count matches (${GOT_MY_ROWS} = ${WANT_MY_ROWS})"
[ "${GOT_MY_FP}" = "${WANT_MY_FP}" ]
ck $? "MariaDB content fingerprint matches"

# -----------------------------------------------------------------------------
sect "6. The recovered host protects itself"

# The step people forget in a real recovery, so it is a test here.
bg-backup doctor >/tmp/doctor.log 2>&1 || true
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/doctor.log
ck $? "no passphrase in doctor output on the recovered host"

# -----------------------------------------------------------------------------
{
  printf '{"pg_fingerprint":"%s","pg_rows":%s,"my_fingerprint":"%s","my_rows":%s,"bootstrap_rc":%s}\n' \
    "${GOT_PG_FP}" "${GOT_PG_ROWS:-0}" "${GOT_MY_FP}" "${GOT_MY_ROWS:-0}" "${BOOT_RC}"
} >"${EV}/after.json"

printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
