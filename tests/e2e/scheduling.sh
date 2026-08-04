#!/usr/bin/env bash
# =============================================================================
# e2e: schedule sync / enable / disable / list - the units that actually run
# =============================================================================
# lib/systemd.sh is the largest module in this codebase at ~960 lines, and until
# this suite existed not one of its 32 functions had ever been executed. That is
# a bad place for a blind spot: it generates the units and timers through which
# every backup, check, prune, verify and copy is invoked on a real host. A
# defect here does not produce a wrong backup, it produces NO backup - and the
# only symptom is a timer that never fires, which nothing alerts on.
#
# It was not covered by the installer suite either. install.sh calls
# `schedule sync && schedule enable` only under ENABLE_TIMERS=1, which no test
# ever set, and installer.sh ran `systemd-analyze verify` on the SHIPPED
# template unit rather than on anything generated.
#
# WHAT A CONTAINER CAN AND CANNOT PROVE. systemd is installed here but is not
# PID 1, so `systemctl daemon-reload` fails - bg-backup degrades to a warning,
# which is itself asserted below. `systemctl enable` and `disable` are pure
# symlink operations and DO work offline, so the whole enable/disable lifecycle
# is real. What cannot be proven here is that a timer actually fires; that needs
# a booted system and remains the job of the quarterly VM rehearsal.
#
# Runs on tests/rig/Dockerfile.victim.
# =============================================================================

# The assertion idiom here is deliberately `[ condition ]; ck $?`.
# shellcheck disable=SC2319
set -uo pipefail

SRC=/opt/bgb
PASS=0
FAIL=0
UNITS=/etc/systemd/system

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

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# The ENABLED column of `schedule list` for one timer.
timer_state() {
  bg-backup schedule list 2>/dev/null | awk -v u="$1" '$1 == u { print $2 }'
}

# -----------------------------------------------------------------------------
sect "0. A host with two jobs on different schedules"

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

install -d /srv/alpha /srv/beta
echo a >/srv/alpha/f
echo b >/srv/beta/f

cat >/etc/bg-backup/conf.d/50-alpha.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/alpha )
JOB_SCHEDULE="*-*-* 03:17:00"
JOB_RANDOM_DELAY="120"
JOB_KEEP_LAST="5"
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
cat >/etc/bg-backup/conf.d/51-beta.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/beta )
JOB_SCHEDULE="Mon *-*-* 22:45:00"
JOB_KEEP_LAST="5"
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-alpha.conf /etc/bg-backup/conf.d/51-beta.conf

# -----------------------------------------------------------------------------
sect "1. schedule sync generates a unit per job"

bg-backup schedule sync >/tmp/sync.log 2>&1
RC=$?
eq "schedule sync exits 0" "${RC}" "0"

# The daemon-reload CANNOT work without PID 1 systemd. Degrading to a warning
# rather than failing the command is the correct behaviour on a host being
# prepared from a chroot or a container, and it is asserted rather than assumed.
grep -q 'daemon-reload failed' /tmp/sync.log
ck $? "a failed daemon-reload is a warning, not a failure"

[ -f "${UNITS}/bg-backup@alpha.timer" ]
ck $? "alpha got its own timer"
[ -f "${UNITS}/bg-backup@beta.timer" ]
ck $? "beta got its own timer"

grep -q '03:17:00' "${UNITS}/bg-backup@alpha.timer"
ck $? "alpha's timer carries its configured OnCalendar"
grep -q 'Mon \*-\*-\* 22:45:00' "${UNITS}/bg-backup@beta.timer"
ck $? "beta's weekday schedule survived verbatim"
grep -qE '^RandomizedDelaySec=120' "${UNITS}/bg-backup@alpha.timer"
ck $? "the configured random delay is emitted"

# The maintenance timers come from the global schedule, not from a job.
for u in bg-backup-check.timer bg-backup-prune.timer bg-backup-verify.timer; do
  [ -f "${UNITS}/${u}" ] || {
    bad "${u} was not generated"
    continue
  }
  ok "${u} was generated"
done

# -----------------------------------------------------------------------------
sect "2. systemd accepts what we generated"

# installer.sh verifies the SHIPPED template. This verifies the output of the
# generator, which is the part that can drift.
GEN_FAIL=0
for u in "${UNITS}"/bg-backup@alpha.timer "${UNITS}"/bg-backup@beta.timer \
  "${UNITS}"/bg-backup-check.timer "${UNITS}"/bg-backup-prune.timer \
  "${UNITS}"/bg-backup-verify.timer; do
  [ -f "${u}" ] || continue
  if ! systemd-analyze verify "${u}" >>/tmp/analyze.log 2>&1; then
    bad "systemd-analyze rejects $(basename "${u}")"
    GEN_FAIL=1
  fi
done
[ "${GEN_FAIL}" -eq 0 ] && ok "systemd-analyze accepts every generated unit"

# -----------------------------------------------------------------------------
sect "3. credentials reach the unit by reference, never by value"

DROPIN="${UNITS}/bg-backup@.service.d"
[ -d "${DROPIN}" ]
ck $? "the credential drop-in directory exists"

grep -rqE '^LoadCredential=repo\.env:' "${DROPIN}"
ck $? "repo.env is passed with LoadCredential="
grep -rqE '^LoadCredential=repo\.key:' "${DROPIN}"
ck $? "repo.key is passed with LoadCredential="

# Drop-ins APPEND to list options, so the list must be reset first or a
# re-sync accumulates duplicates until the unit refuses to start.
grep -rqE '^LoadCredential=$' "${DROPIN}"
ck $? "the credential list is reset before it is populated"

! grep -rqE '^[[:space:]]*EnvironmentFile=' "${DROPIN}"
ck $? "no credential is passed via EnvironmentFile="

# THE ASSERTION THAT MATTERS MOST. A generated unit must reference the file, not
# inline its contents: `systemctl show -p Environment` renders a unit's
# environment for any local user, with no root required.
if grep -rq "${BGB_IT_SECRET_KEY}" "${UNITS}" 2>/dev/null; then
  bad "the S3 secret is written into a unit file"
elif grep -rq "${BGB_IT_RESTIC_PASSWORD}" "${UNITS}" 2>/dev/null; then
  bad "the repository passphrase is written into a unit file"
else
  ok "no secret value appears in any generated unit"
fi

# -----------------------------------------------------------------------------
sect "4. the enable/disable lifecycle"

# `systemctl enable` and `disable` are symlink operations and work without a
# booted systemd, so this lifecycle is real rather than simulated.
eq "alpha starts out disabled" "$(timer_state bg-backup@alpha.timer)" "disabled"

bg-backup schedule enable >/tmp/enable.log 2>&1
ck $? "schedule enable exits 0"

eq "alpha is now enabled" "$(timer_state bg-backup@alpha.timer)" "enabled"
eq "beta is now enabled" "$(timer_state bg-backup@beta.timer)" "enabled"
eq "the check timer is enabled too" "$(timer_state bg-backup-check.timer)" "enabled"

bg-backup schedule disable >/tmp/disable.log 2>&1
ck $? "schedule disable exits 0"

eq "alpha is disabled again" "$(timer_state bg-backup@alpha.timer)" "disabled"
eq "beta is disabled again" "$(timer_state bg-backup@beta.timer)" "disabled"

# Re-enable for the rest of the suite: a disable that also deleted the units
# would make the next section pass for the wrong reason.
bg-backup schedule enable >/dev/null 2>&1
[ -f "${UNITS}/bg-backup@alpha.timer" ]
ck $? "disable did not delete the unit, only the symlink"

# -----------------------------------------------------------------------------
sect "5. schedule list reports what is actually configured"

bg-backup schedule list >/tmp/list.log 2>&1
ck $? "schedule list exits 0"

grep -q 'bg-backup@alpha.timer' /tmp/list.log
ck $? "alpha appears in the listing"
grep -q '03:17:00' /tmp/list.log
ck $? "the listing shows the real schedule, not a placeholder"

# A job with no schedule must be visible as such rather than silently absent -
# "I configured it and it never ran" is the failure this prevents.
grep -qE 'bg-backup-copy.timer .*(<none>|none)' /tmp/list.log
ck $? "a timer with no schedule is listed as having none"

# -----------------------------------------------------------------------------
sect "6. a removed job takes its units with it"

# Orphan pruning. Without it, deleting a job leaves an armed timer that invokes
# a job which no longer exists - a nightly failure alert for a backup nobody
# wants any more, which is how operators learn to ignore alerts.
rm -f /etc/bg-backup/conf.d/51-beta.conf

bg-backup schedule sync >/tmp/sync2.log 2>&1
ck $? "re-sync after removing a job exits 0"

[ ! -f "${UNITS}/bg-backup@beta.timer" ]
ck $? "beta's timer was pruned"
[ ! -d "${UNITS}/bg-backup@beta.service.d" ]
ck $? "beta's drop-in directory was pruned"
[ -f "${UNITS}/bg-backup@alpha.timer" ]
ck $? "alpha's timer was left alone"

# -----------------------------------------------------------------------------
sect "7. a secondary host must not be able to prune"

# ADR-0005 again, from the other end: the identity split stops a compromised
# backup host from deleting data, and this stops a SECOND host from pruning a
# repository the primary is responsible for. Two hosts repacking one repository
# concurrently can remove packs the other still references.
sed -i 's|^BGB_REPO_ROLE=.*|BGB_REPO_ROLE="secondary"|' /etc/bg-backup/bg-backup.conf
grep -q 'BGB_REPO_ROLE="secondary"' /etc/bg-backup/bg-backup.conf
ck $? "the secondary role was actually established"

bg-backup schedule sync >/tmp/sync3.log 2>&1
ck $? "sync on a secondary exits 0"

# The unit must be neutralised. Either it is not generated at all, or it carries
# a condition that makes systemd skip it - both are correct, and asserting
# "either" rather than one of them keeps this from breaking on a refactor that
# picks the other.
if [ ! -f "${UNITS}/bg-backup-prune.timer" ]; then
  ok "the prune timer is not generated on a secondary"
elif grep -rqE '^Condition' "${UNITS}/bg-backup-prune.service" "${UNITS}/bg-backup-prune.service.d" 2>/dev/null; then
  ok "the prune unit carries a condition that skips it on a secondary"
else
  bad "a secondary host has an unguarded prune unit"
fi

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
