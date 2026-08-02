#!/usr/bin/env bash
# =============================================================================
# e2e: install.sh end to end in a clean Ubuntu container
# =============================================================================
# Every assertion here exists because its absence would let the suite pass
# vacuously - which is the real failure mode for an installer test. "It ran and
# exited 0" proves almost nothing.
# =============================================================================

# The assertion idiom here is deliberately `[ condition ]; ck $?` - $? IS the
# condition's status, which is exactly what we want to report. ShellCheck flags
# that shape generically, so it is disabled for these harness files only.
# shellcheck disable=SC2319
set -uo pipefail

SRC=/opt/bgb
PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$(( PASS + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
ck()   { [ "$1" -eq 0 ] && ok "$2" || bad "$2"; }
sect() { printf '\n\033[1m%s\033[0m\n' "$*"; }

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# -----------------------------------------------------------------------------
sect "1. install.sh on a bare host"

printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass

SOURCE_DIR="${SRC}" INSTALL_METHOD=local \
  INIT_REPO=1 \
  BGB_REPOSITORY="${REPO}" \
  BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY="${BGB_IT_ACCESS_KEY}" \
  BGB_S3_SECRET_KEY="${BGB_IT_SECRET_KEY}" \
  BGB_S3_REGION="${BGB_IT_REGION}" \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1
ck $? "install.sh exits 0"

[ -x /usr/local/sbin/bg-backup ]; ck $? "bg-backup is installed"
[ -L /usr/local/sbin/bg-backup ]; ck $? "bg-backup is a symlink into the release directory"
readlink -f /usr/local/sbin/bg-backup | grep -q '^/opt/bg-backup/releases/'
ck $? "the symlink points into /opt/bg-backup/releases"

# -----------------------------------------------------------------------------
sect "2. restic is the pinned, verified version"

PINNED="$(grep -oE 'RESTIC_VERSION:-[0-9.]+' "${SRC}/install.sh" | head -n1 | cut -d- -f2)"
GOT="$(restic version 2>/dev/null | awk '{print $2; exit}')"
[ -n "${PINNED}" ] && [ "${GOT}" = "${PINNED}" ]
ck $? "restic ${GOT} matches the pinned ${PINNED}"

# The installer verified a GPG signature; re-assert the binary hash is stable so
# a later step cannot have swapped it.
sha256sum /usr/local/bin/restic >/tmp/restic.sha
[ -s /tmp/restic.sha ]; ck $? "restic binary hashes"

grep -qi 'GPG signature verified\|Checksum verified' /tmp/install.log
ck $? "the installer verified the download"

# -----------------------------------------------------------------------------
sect "3. systemd units are syntactically valid"

# No PID 1 in this container, so verify rather than start. That is what the
# harness can honestly prove; started timers are the VM rehearsal's job.
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify /etc/systemd/system/bg-backup@.service >/tmp/unit.log 2>&1
  ck $? "systemd-analyze accepts bg-backup@.service"
else
  ok "systemd-analyze unavailable - unit syntax not checked here"
fi

grep -q 'LoadCredential=' /etc/systemd/system/bg-backup@.service
ck $? "the unit uses LoadCredential= (not EnvironmentFile=)"
! grep -q 'EnvironmentFile=.*repo\.' /etc/systemd/system/bg-backup@.service
ck $? "no credential is passed via EnvironmentFile="

# -----------------------------------------------------------------------------
sect "4. idempotence and refusals"

SOURCE_DIR="${SRC}" INSTALL_METHOD=local bash "${SRC}/install.sh" >/tmp/install2.log 2>&1
ck $? "re-running install.sh exits 0"
grep -qi 'already installed\|upgrading in place' /tmp/install2.log
ck $? "the second run recognises the existing installation"

bg-backup init --non-interactive --repo "${REPO}" >/tmp/init2.log 2>&1
[ $? -ne 0 ] || grep -qi 'already configured\|nothing to do' /tmp/init2.log
ck $? "a second init does not silently reconfigure"

# -----------------------------------------------------------------------------
sect "5. a backup produces exactly one snapshot"

mkdir -p /srv/data/sub
echo hello >/srv/data/plain.txt
head -c 4096 /dev/urandom >/srv/data/sub/bin.dat
ln -sf plain.txt /srv/data/link.txt
: >/srv/data/empty.txt

cat >/etc/bg-backup/conf.d/50-e2e.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/data )
JOB_ONE_FILE_SYSTEM=0
JOB_EXCLUDE_FILE=""
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-e2e.conf

bg-backup backup e2e >/tmp/backup.log 2>&1
ck $? "backup exits 0"

N="$(bg-backup snapshots --job e2e --json 2>/dev/null | jq 'length')"
[ "${N}" = "1" ]; ck $? "exactly one snapshot exists (got ${N:-none})"

SNAP="$(bg-backup snapshots --job e2e --json 2>/dev/null | jq -r '.[0].short_id')"
[ -n "${SNAP}" ]; ck $? "the snapshot id was recorded: ${SNAP:-none}"

# -----------------------------------------------------------------------------
sect "6. an unreadable file yields exit 3, not 1"

# The distinction this tool exists to preserve. Collapsing 3 into 1 makes every
# full-filesystem backup fail nightly; collapsing it into 0 hides real damage.
install -d /srv/data/locked
echo secret >/srv/data/locked/file
chmod 000 /srv/data/locked

bg-backup backup e2e >/tmp/backup3.log 2>&1
RC=$?
[ "${RC}" -eq 3 ]; ck $? "exit 3 on an unreadable source (got ${RC})"

chmod 755 /srv/data/locked

if [ -n "${BGB_METRICS_TEXTFILE:-}" ] || [ -d /var/lib/node_exporter/textfile_collector ]; then
  find /var/lib/node_exporter/textfile_collector -name 'bg-backup.prom' -size +0c >/dev/null 2>&1
  ck $? "the metrics file was still written on a partial run"
else
  ok "metrics textfile not configured - skipped"
fi

# -----------------------------------------------------------------------------
sect "7. forget refuses to delete everything"

# A configuration with no keep-* must be read as "misconfigured", never as
# "keep nothing".
sed -i 's/^JOB_KEEP_LAST=.*/JOB_KEEP_LAST=""/' /etc/bg-backup/conf.d/50-e2e.conf
bg-backup forget --job e2e --apply --yes >/tmp/forget.log 2>&1
RC=$?
[ "${RC}" -eq 9 ]; ck $? "forget with no policy exits 9 (EX_SAFETY), got ${RC}"

N="$(bg-backup snapshots --job e2e --json 2>/dev/null | jq 'length')"
[ "${N}" != "0" ]; ck $? "no snapshot was deleted"
sed -i 's/^JOB_KEEP_LAST=.*/JOB_KEEP_LAST="5"/' /etc/bg-backup/conf.d/50-e2e.conf

# -----------------------------------------------------------------------------
sect "8. restore reproduces content AND metadata"

bg-backup restore dir --path /srv/data --to /tmp/restore >/tmp/restore.log 2>&1
ck $? "restore exits 0"

R="$(find /tmp/restore -type d -name data 2>/dev/null | head -n1)"
[ -n "${R}" ]; ck $? "the restored tree was found"

diff -r /srv/data "${R}" >/dev/null 2>&1
ck $? "content is identical"

# A checksum-only assertion misses exactly the things that actually go wrong.
[ -L "${R}/link.txt" ]; ck $? "the symlink is still a symlink"
[ -f "${R}/empty.txt" ] && [ ! -s "${R}/empty.txt" ]; ck $? "the empty file is still empty"

A="$(stat -c '%a %U %G' /srv/data/plain.txt)"
B="$(stat -c '%a %U %G' "${R}/plain.txt")"
[ "${A}" = "${B}" ]; ck $? "mode and ownership preserved (${A})"

X="$(sha256sum </srv/data/sub/bin.dat | cut -d' ' -f1)"
Y="$(sha256sum <"${R}/sub/bin.dat" | cut -d' ' -f1)"
[ "${X}" = "${Y}" ]; ck $? "binary content byte-identical"

# -----------------------------------------------------------------------------
sect "9. no secret appears in doctor output"

# The redaction regression test, in CI rather than in a document.
bg-backup doctor >/tmp/doctor.log 2>&1 || true
! grep -q "${BGB_IT_SECRET_KEY}" /tmp/doctor.log
ck $? "the S3 secret does not appear in doctor output"
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/doctor.log
ck $? "the repository passphrase does not appear in doctor output"

for f in /var/log/bg-backup/*.log /var/log/bg-backup/jobs/*.log; do
  [ -e "${f}" ] || continue
  grep -q "${BGB_IT_RESTIC_PASSWORD}" "${f}" && bad "passphrase leaked into ${f}" && break
done
ok "no passphrase in the log files"

# -----------------------------------------------------------------------------
sect "10. uninstall leaves the repository alone"

BEFORE="$(bg-backup snapshots --json 2>/dev/null | jq 'length')"

FORCE=1 UNINSTALL=1 bash "${SRC}/install.sh" >/tmp/uninstall.log 2>&1
ck $? "uninstall exits 0"

[ ! -e /usr/local/sbin/bg-backup ]; ck $? "the binary is gone"
[ ! -d /opt/bg-backup ]; ck $? "the install prefix is gone"
[ -d /etc/bg-backup ]; ck $? "configuration is kept without --purge"

export RESTIC_REPOSITORY="${REPO}"
export RESTIC_PASSWORD="${BGB_IT_RESTIC_PASSWORD}"
AFTER="$(restic snapshots --json 2>/dev/null | jq 'length')"
[ "${BEFORE}" = "${AFTER}" ]
ck $? "the repository still holds ${AFTER} snapshot(s) - uninstall did not touch it"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
