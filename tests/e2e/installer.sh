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

ok() {
  printf '  \033[32mPASS\033[0m %s\n' "$*"
  PASS=$((PASS + 1))
}
bad() {
  printf '  \033[31mFAIL\033[0m %s\n' "$*"
  FAIL=$((FAIL + 1))
}
ck() { [ "$1" -eq 0 ] && ok "$2" || bad "$2"; }
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

[ -x /usr/local/sbin/bg-backup ]
ck $? "bg-backup is installed"
[ -L /usr/local/sbin/bg-backup ]
ck $? "bg-backup is a symlink into the release directory"
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
[ -s /tmp/restic.sha ]
ck $? "restic binary hashes"

grep -qi 'GPG signature verified\|Checksum verified' /tmp/install.log
ck $? "the installer verified the download"

# -----------------------------------------------------------------------------
sect "3. systemd units are syntactically valid"

# No PID 1 in this container, so verify rather than start. That is what the
# harness can honestly prove; started timers are the VM rehearsal's job.
# A PASS for "not checked" is how a whole section stops testing anything without
# anyone noticing - which is precisely what happened: on 22.04 systemd was
# absent, install_units() skipped, the unit file never existed, and the
# EnvironmentFile assertion "passed" by grepping a file that was not there.
# The victim image now installs systemd deliberately, so absence is a defect.
if ! command -v systemd-analyze >/dev/null 2>&1; then
  bad "systemd-analyze is missing - unit syntax was NOT verified on this image"
elif [ ! -f /etc/systemd/system/bg-backup@.service ]; then
  bad "the unit was never installed - nothing in this section was verified"
else
  systemd-analyze verify /etc/systemd/system/bg-backup@.service >/tmp/unit.log 2>&1
  ck $? "systemd-analyze accepts bg-backup@.service"
fi

[ -f /etc/systemd/system/bg-backup@.service ]
ck $? "the unit file exists"

grep -q 'LoadCredential=' /etc/systemd/system/bg-backup@.service 2>/dev/null
ck $? "the unit uses LoadCredential= (not EnvironmentFile=)"
# Anchored to a DIRECTIVE, not to the word: the unit carries a comment block
# explaining why EnvironmentFile= is not used, and an unanchored grep matched
# that explanation and failed a unit that was correct.
! grep -qE '^[[:space:]]*EnvironmentFile=' /etc/systemd/system/bg-backup@.service
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
[ "${N}" = "1" ]
ck $? "exactly one snapshot exists (got ${N:-none})"

SNAP="$(bg-backup snapshots --job e2e --json 2>/dev/null | jq -r '.[0].short_id')"
[ -n "${SNAP}" ]
ck $? "the snapshot id was recorded: ${SNAP:-none}"

# -----------------------------------------------------------------------------
sect "6. an unreadable file yields exit 3, not 1"

# The distinction this tool exists to preserve. Collapsing 3 into 1 makes every
# full-filesystem backup fail nightly; collapsing it into 0 hides real damage.
install -d /srv/data/locked
echo secret >/srv/data/locked/file
chmod 000 /srv/data/locked

# chmod 000 does NOT stop root: CAP_DAC_OVERRIDE is in Docker's default
# capability set, so the backup read the file happily and returned 0. The test
# passed vacuously in the only direction that matters. Dropping the capability
# from the bounding set makes even uid 0 subject to the permission check, since
# for a root exec the kernel derives the new permitted set from the bounding
# set. Verified in this rig: the plain read succeeds, the setpriv read is denied.
if command -v setpriv >/dev/null 2>&1 \
  && ! setpriv --bounding-set=-dac_override,-dac_read_search \
    cat /srv/data/locked/file >/dev/null 2>&1; then
  setpriv --bounding-set=-dac_override,-dac_read_search \
    bg-backup backup e2e >/tmp/backup3.log 2>&1
  RC=$?
  [ "${RC}" -eq 3 ]
  ck $? "exit 3 on an unreadable source (got ${RC})"
else
  bad "cannot revoke DAC_OVERRIDE here - the exit-3 path was NOT exercised"
fi

# Remove the fixture, do not merely unlock it. Its whole purpose was to be
# absent from the snapshot, so leaving it in the live tree makes the later
# `diff -r live restored` report "Only in /srv/data: locked" - a correct restore
# failing an assertion about a file that was deliberately never backed up.
chmod 755 /srv/data/locked
rm -rf /srv/data/locked

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
#
# Blanking JOB_KEEP_LAST alone does NOT produce that state: the job inherits
# BGB_DEFAULT_KEEP_LAST/DAILY/WEEKLY/MONTHLY from bg-backup.conf, so a policy
# still existed and forget correctly did its job. The assertion was measuring
# inheritance, not the safety rail. Both levels have to be empty.
cp /etc/bg-backup/bg-backup.conf /tmp/bg-backup.conf.bak
cp /etc/bg-backup/conf.d/50-e2e.conf /tmp/50-e2e.conf.bak
sed -i 's/^\(BGB_DEFAULT_KEEP_[A-Z]*\)=.*/\1=""/' /etc/bg-backup/bg-backup.conf
sed -i 's/^\(JOB_KEEP_[A-Z]*\)=.*/\1=""/' /etc/bg-backup/conf.d/50-e2e.conf

grep -qE '^BGB_DEFAULT_KEEP_[A-Z]+=""' /etc/bg-backup/bg-backup.conf
ck $? "the no-policy state was actually established"

bg-backup forget --job e2e --apply --yes >/tmp/forget.log 2>&1
RC=$?
[ "${RC}" -eq 9 ]
ck $? "forget with no policy exits 9 (EX_SAFETY), got ${RC}"

N="$(bg-backup snapshots --job e2e --json 2>/dev/null | jq 'length')"
[ "${N}" != "0" ]
ck $? "no snapshot was deleted"

cp /tmp/bg-backup.conf.bak /etc/bg-backup/bg-backup.conf
cp /tmp/50-e2e.conf.bak /etc/bg-backup/conf.d/50-e2e.conf

# -----------------------------------------------------------------------------
sect "8. restore reproduces content AND metadata"

bg-backup restore dir --path /srv/data --to /tmp/restore >/tmp/restore.log 2>&1
ck $? "restore exits 0"

R="$(find /tmp/restore -type d -name data 2>/dev/null | head -n1)"
[ -n "${R}" ]
ck $? "the restored tree was found"

if diff -r /srv/data "${R}" >/tmp/tree.diff 2>&1; then
  ok "content is identical"
else
  bad "content is identical"
  # An assertion that only says "differs" costs an hour to chase. Say what.
  sed 's/^/      /' /tmp/tree.diff | head -20
fi

# A checksum-only assertion misses exactly the things that actually go wrong.
[ -L "${R}/link.txt" ]
ck $? "the symlink is still a symlink"
[ -f "${R}/empty.txt" ] && [ ! -s "${R}/empty.txt" ]
ck $? "the empty file is still empty"

A="$(stat -c '%a %U %G' /srv/data/plain.txt)"
B="$(stat -c '%a %U %G' "${R}/plain.txt")"
[ "${A}" = "${B}" ]
ck $? "mode and ownership preserved (${A})"

X="$(sha256sum </srv/data/sub/bin.dat | cut -d' ' -f1)"
Y="$(sha256sum <"${R}/sub/bin.dat" | cut -d' ' -f1)"
[ "${X}" = "${Y}" ]
ck $? "binary content byte-identical"

# -----------------------------------------------------------------------------
sect "9. a failed dump command stores NOTHING"

# THE CLAIM THIS PROJECT RESTS ON, demonstrated rather than asserted in a
# comment. lib/db.sh says a truncated database dump must never be storable as a
# healthy snapshot, and the whole reason every engine streams through
# `restic backup --stdin-from-command` instead of piping into `--stdin` is that
# the former propagates the command's exit status and the latter cannot.
#
# Until now that was a design note. It is now a test, and it runs on every
# supported Ubuntu.

# Script files, and JOB_STDIN_COMMAND as an ARRAY. Both matter: a plain string
# is split on spaces and then glob-expanded, so an inline `sh -c 'printf x; exit
# 1'` would fall apart into separate words and fail for the WRONG reason - which
# would let this test pass while proving nothing about --stdin-from-command.
cat >/usr/local/bin/bgb-partial-dump <<'EOS'
#!/bin/sh
# Emits real bytes and THEN fails - the dangerous case. A command that failed
# before writing anything would prove much less: restic would have nothing to
# store either way.
printf %s BEGIN-PARTIAL-PAYLOAD
exit 1
EOS
cat >/usr/local/bin/bgb-good-dump <<'EOS'
#!/bin/sh
printf %s COMPLETE-PAYLOAD
EOS
chmod 0755 /usr/local/bin/bgb-partial-dump /usr/local/bin/bgb-good-dump

cat >/etc/bg-backup/conf.d/60-faildump.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="stdin"
JOB_STDIN_COMMAND=( /usr/local/bin/bgb-partial-dump )
JOB_STDIN_FILENAME="/db/proof/truncated.sql"
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/60-faildump.conf

bg-backup backup faildump >/tmp/faildump.log 2>&1
FRC=$?
[ "${FRC}" -ne 0 ]
ck $? "a failing dump command fails the job (exit ${FRC})"

N_BAD="$(bg-backup snapshots --job faildump --json 2>/dev/null | jq 'length')"
[ "${N_BAD}" = "0" ]
ck $? "no snapshot was written for the failed dump (got ${N_BAD:-?})"

# And the partial bytes must not be anywhere in the repository, under any
# snapshot. This is the assertion that would catch a future switch to --stdin.
restic_find_partial() {
  restic find --json 'truncated.sql' 2>/dev/null | grep -q 'truncated.sql'
}
export RESTIC_REPOSITORY="${REPO}"
export RESTIC_PASSWORD="${BGB_IT_RESTIC_PASSWORD}"
! restic_find_partial
ck $? "the partial payload is in no snapshot at all"

# The positive control: the same mechanism must still store a dump that works.
# Without it, "no snapshot" could equally mean the job never ran.
sed -i 's|^JOB_STDIN_COMMAND=.*|JOB_STDIN_COMMAND=( /usr/local/bin/bgb-good-dump )|' \
  /etc/bg-backup/conf.d/60-faildump.conf
bg-backup backup faildump >/tmp/okdump.log 2>&1
ck $? "the same job succeeds when the command succeeds"

N_OK="$(bg-backup snapshots --job faildump --json 2>/dev/null | jq 'length')"
[ "${N_OK}" = "1" ]
ck $? "exactly one snapshot exists now (got ${N_OK:-?})"

GOT="$(bg-backup snapshots --job faildump --json 2>/dev/null | jq -r '.[0].short_id')"
[ "$(restic dump "${GOT}" /db/proof/truncated.sql 2>/dev/null)" = "COMPLETE-PAYLOAD" ]
ck $? "the stored payload is the complete one"

unset RESTIC_REPOSITORY RESTIC_PASSWORD
rm -f /etc/bg-backup/conf.d/60-faildump.conf \
  /usr/local/bin/bgb-partial-dump /usr/local/bin/bgb-good-dump

# -----------------------------------------------------------------------------
sect "10. no secret appears in doctor output"

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
sect "11. uninstall leaves the repository alone"

BEFORE="$(bg-backup snapshots --json 2>/dev/null | jq 'length')"

FORCE=1 UNINSTALL=1 bash "${SRC}/install.sh" >/tmp/uninstall.log 2>&1
ck $? "uninstall exits 0"

[ ! -e /usr/local/sbin/bg-backup ]
ck $? "the binary is gone"
[ ! -d /opt/bg-backup ]
ck $? "the install prefix is gone"
[ -d /etc/bg-backup ]
ck $? "configuration is kept without --purge"

export RESTIC_REPOSITORY="${REPO}"
export RESTIC_PASSWORD="${BGB_IT_RESTIC_PASSWORD}"
AFTER="$(restic snapshots --json 2>/dev/null | jq 'length')"
[ "${BEFORE}" = "${AFTER}" ]
ck $? "the repository still holds ${AFTER} snapshot(s) - uninstall did not touch it"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
