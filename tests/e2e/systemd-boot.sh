#!/usr/bin/env bash
# =============================================================================
# e2e: the units actually RUN - on a host where systemd is PID 1
# =============================================================================
# tests/e2e/scheduling.sh proves the generator writes correct unit FILES.
# `systemd-analyze verify` cannot tell you whether a timer ever fires, and it
# cannot tell you whether LoadCredential= delivers anything - and those are the
# two things the whole scheduling design rests on:
#
#   * a timer that never fires produces SILENCE. There is no failed job to
#     alert on, no log line, nothing. It is the only failure mode in this tool
#     that is invisible from both ends.
#   * LoadCredential= is the security control chosen over EnvironmentFile=.
#     Until the unit really starts, all that has been proven is that the
#     directive is spelled correctly. Whether restic can actually read the
#     repository through $CREDENTIALS_DIRECTORY is a different question.
#
# This suite runs inside tests/rig/Dockerfile.systemd-victim, which boots
# systemd as PID 1. `systemctl is-system-running` reports "degraded" in a
# container because some default units cannot work there; that is expected and
# is why the assertions below name specific units instead.
# =============================================================================

# The assertion idiom here is deliberately `[ condition ]; ck $?`.
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

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# Wait until a unit leaves the active/activating state, or give up. Polling
# `is-active` rather than sleeping a fixed amount: a fixed sleep is either flaky
# or slow, and on a loaded CI runner it is usually both.
wait_inactive() {
  local unit="$1" limit="${2:-90}" i=0 state
  while [ "${i}" -lt "${limit}" ]; do
    state="$(systemctl is-active "${unit}" 2>/dev/null || true)"
    case "${state}" in activating | active | reloading) ;; *) return 0 ;; esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# -----------------------------------------------------------------------------
sect "0. systemd is really PID 1"

PID1="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')"
eq "PID 1 is systemd" "${PID1}" "systemd"

systemctl is-system-running >/tmp/sysrun.txt 2>&1 || true
# "degraded" is expected in a container; "offline"/"unknown" would mean the
# manager is not reachable at all and every assertion below would be vacuous.
grep -qE 'running|degraded|starting' /tmp/sysrun.txt
ck $? "the manager is reachable ($(tr -d '\n' </tmp/sysrun.txt))"

# -----------------------------------------------------------------------------
sect "1. install and arm, exactly as an operator would"

printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass

SOURCE_DIR="${SRC}" INSTALL_METHOD=local \
  INIT_REPO=1 \
  ENABLE_TIMERS=1 \
  BGB_REPOSITORY="${REPO}" \
  BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY="${BGB_IT_ACCESS_KEY}" \
  BGB_S3_SECRET_KEY="${BGB_IT_SECRET_KEY}" \
  BGB_S3_REGION="${BGB_IT_REGION}" \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1
ck $? "install.sh exits 0"

# Here daemon-reload CAN work, unlike in every other victim.
! grep -q 'daemon-reload failed' /tmp/install.log
ck $? "daemon-reload succeeded on a booted host"

install -d /srv/boot
echo "the-real-payload" >/srv/boot/f
head -c 4096 /dev/urandom >/srv/boot/blob.dat

# Every 15 seconds, so the suite waits seconds rather than minutes. Persistent=
# is off deliberately: this asserts a live fire, not a catch-up run.
cat >/etc/bg-backup/conf.d/50-tick.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/boot )
JOB_SCHEDULE="*:*:0/15"
JOB_RANDOM_DELAY="0"
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-tick.conf

bg-backup schedule sync >/tmp/sync.log 2>&1
ck $? "schedule sync exits 0"
bg-backup schedule enable >/tmp/enable.log 2>&1
ck $? "schedule enable exits 0"

# -----------------------------------------------------------------------------
sect "2. the unit starts, and LoadCredential really delivers"

# THE ASSERTION `systemd-analyze verify` CANNOT MAKE. If the credential does not
# arrive in $CREDENTIALS_DIRECTORY, restic has no repository and no key, and the
# service fails - which is exactly what would happen on a production host the
# first night, with nobody watching.
systemctl start bg-backup@tick.service >/tmp/start.log 2>&1 || true
wait_inactive bg-backup@tick.service 120
ck $? "the unit reached a terminal state"

RESULT="$(systemctl show -p Result --value bg-backup@tick.service 2>/dev/null)"
eq "the unit finished successfully" "${RESULT}" "success"

EXITC="$(systemctl show -p ExecMainStatus --value bg-backup@tick.service 2>/dev/null)"
eq "its exit status is 0" "${EXITC}" "0"

# THE ASSERTION THAT CAUGHT THE WORST BUG THIS SUITE FOUND. The backup itself
# succeeded and the snapshot was written, but ExecStopPost= exited 2 - the
# dispatcher had eaten its `--job` - so systemd recorded "Failed with result
# 'exit-code'" and fired OnFailure= after a perfectly good run. Result= alone is
# not enough: ExecMainStatus was 0 the whole time, and only the CONTROL process
# was failing.
STOPPOST="$(systemctl show -p ExecStopPostEx --value bg-backup@tick.service 2>/dev/null)"
case "${STOPPOST}" in
  *'status=0'* | '') ok "ExecStopPost= exited 0" ;;
  *) bad "ExecStopPost= failed: ${STOPPOST}" ;;
esac

# And no failure notification may have been triggered for a successful run.
FIRED_ON_OK="$(systemctl show -p ExecMainStartTimestamp --value \
  bg-backup-failure@tick.service 2>/dev/null || true)"
[ -z "${FIRED_ON_OK}" ] || [ "${FIRED_ON_OK}" = "n/a" ]
ck $? "OnFailure= did NOT fire for a successful backup"

# It really backed something up - a unit that started, did nothing and exited 0
# would satisfy everything above.
N="$(bg-backup snapshots --job tick --json 2>/dev/null | jq 'length')"
[ "${N:-0}" -ge 1 ]
ck $? "the run through systemd produced a snapshot (${N:-0})"

# And the credential must NOT be visible to an unprivileged user. This is the
# entire reason LoadCredential= was chosen over EnvironmentFile=.
systemctl show -p Environment bg-backup@tick.service >/tmp/unitenv.txt 2>&1
! grep -q "${BGB_IT_SECRET_KEY}" /tmp/unitenv.txt
ck $? "the S3 secret is not rendered by 'systemctl show -p Environment'"
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/unitenv.txt
ck $? "the passphrase is not rendered either"

# -----------------------------------------------------------------------------
sect "3. a timer actually fires"

# The failure mode that is invisible from both ends: no failed unit, no log
# line, no alert - just a backup that silently never happens.
systemctl is-enabled bg-backup@tick.timer >/tmp/tenabled.txt 2>&1
grep -q enabled /tmp/tenabled.txt
ck $? "the timer is enabled"

systemctl start bg-backup@tick.timer >/dev/null 2>&1
systemctl is-active bg-backup@tick.timer >/tmp/tactive.txt 2>&1
grep -q '^active' /tmp/tactive.txt
ck $? "the timer is active"

# NEXT must be a real point in time. "n/a" means the calendar expression never
# resolves, which is a unit that will never run and looks perfectly healthy.
#
# POLLED, not read once. With OnCalendar=*:*:0/15 the property is transiently
# empty while the triggered service is running - systemd has fired and has not
# yet computed the following elapse. A single read caught that window once in
# roughly twenty nightly runs and failed a timer that demonstrably fired two
# assertions later.
NEXT=""
for _ in $(seq 1 20); do
  NEXT="$(systemctl show -p NextElapseUSecRealtime --value bg-backup@tick.timer 2>/dev/null)"
  case "${NEXT}" in '' | 'n/a' | 0) ;; *) break ;; esac
  sleep 1
done
[ -n "${NEXT}" ] && [ "${NEXT}" != "n/a" ] && [ "${NEXT}" != "0" ]
ck $? "the timer has a next elapse (${NEXT:-none})"

BEFORE="$(bg-backup snapshots --job tick --json 2>/dev/null | jq 'length')"

# Wait for the counter systemd itself keeps, rather than for a snapshot: it
# distinguishes "the timer fired" from "the job happened to run for some other
# reason".
FIRED=0
for _ in $(seq 1 60); do
  N_TRIG="$(systemctl show -p NAccepted --value bg-backup@tick.timer 2>/dev/null || true)"
  LAST="$(systemctl show -p LastTriggerUSec --value bg-backup@tick.timer 2>/dev/null || true)"
  if [ -n "${LAST}" ] && [ "${LAST}" != "0" ] && [ "${LAST}" != "n/a" ]; then
    FIRED=1
    break
  fi
  sleep 2
done
[ "${FIRED}" -eq 1 ]
ck $? "the timer fired on its own within the window"

# Poll for the EFFECT, not for a state. wait_inactive returns immediately when
# the unit has not started yet, which is the normal situation microseconds after
# the timer records its trigger - so a single check here reported "1 -> 1" for a
# run that was about to happen. The condition being waited on is a new snapshot;
# anything else is a proxy for it.
AFTER="${BEFORE:-0}"
for _ in $(seq 1 60); do
  AFTER="$(bg-backup snapshots --job tick --json 2>/dev/null | jq 'length')"
  [ "${AFTER:-0}" -gt "${BEFORE:-0}" ] && break
  sleep 2
done
[ "${AFTER:-0}" -gt "${BEFORE:-0}" ]
ck $? "the fire produced another snapshot (${BEFORE:-0} -> ${AFTER:-0})"

# And that second run must ALSO have ended clean - the ExecStopPost= defect
# would otherwise reappear on every scheduled run while the manual start stayed
# green.
wait_inactive bg-backup@tick.service 120 || true
TRESULT="$(systemctl show -p Result --value bg-backup@tick.service 2>/dev/null)"
eq "the timer-driven run also finished successfully" "${TRESULT}" "success"

# -----------------------------------------------------------------------------
sect "4. a failing job is reported through OnFailure"

# bg-backup-failure@.service is how a failed run reaches the notifier when the
# main process was killed rather than exiting. It is wired with OnFailure= and
# nothing had ever proven that systemd triggers it.
cat >/usr/local/bin/bgb-boom <<'EOS'
#!/bin/sh
printf %s PARTIAL
exit 1
EOS
chmod 0755 /usr/local/bin/bgb-boom

cat >/etc/bg-backup/conf.d/60-boom.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="stdin"
JOB_STDIN_COMMAND=( /usr/local/bin/bgb-boom )
JOB_STDIN_FILENAME="/db/boom.sql"
JOB_SCHEDULE="*-*-* 04:00:00"
JOB_KEEP_LAST="5"
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/60-boom.conf

bg-backup schedule sync >/dev/null 2>&1

grep -qE '^OnFailure=' /etc/systemd/system/bg-backup@.service
ck $? "the template wires OnFailure="

systemctl start bg-backup@boom.service >/tmp/boom.log 2>&1 || true
wait_inactive bg-backup@boom.service 120
ck $? "the failing unit reached a terminal state"

BRESULT="$(systemctl show -p Result --value bg-backup@boom.service 2>/dev/null)"
[ "${BRESULT}" != "success" ]
ck $? "systemd records the failure (Result=${BRESULT})"

# The OnFailure unit must have been triggered. It runs `bg-backup internal
# notify-failure`, so its own result tells us whether that entry point works
# when invoked the way systemd invokes it - which is the only way it ever is.
#
# The instance is %i - the JOB name - not %n. `OnFailure=bg-backup-failure@%i`
# in bg-backup@.service means the handler for job "boom" is
# bg-backup-failure@boom.service.
wait_inactive 'bg-backup-failure@boom.service' 60 || true
systemctl show -p ExecMainStartTimestamp --value \
  'bg-backup-failure@boom.service' >/tmp/onfail.txt 2>&1 || true
FAILSTAMP="$(tr -d '\n' </tmp/onfail.txt)"
[ -n "${FAILSTAMP}" ] && [ "${FAILSTAMP}" != "n/a" ]
ck $? "OnFailure= started the failure handler${FAILSTAMP:+ (${FAILSTAMP})}"

journalctl -u 'bg-backup-failure@*' --no-pager >/tmp/failjournal.txt 2>&1 || true
! grep -qE 'command not found|unbound variable' /tmp/failjournal.txt
ck $? "the failure handler ran without a missing module"

# -----------------------------------------------------------------------------
sect "5. nothing else broke, and no secret reached the journal"

systemctl --failed --no-legend >/tmp/failed.txt 2>&1 || true
! grep -q '^bg-backup' /tmp/failed.txt
ck $? "no bg-backup unit is left in the failed state"

journalctl -u 'bg-backup@tick.service' --no-pager >/tmp/journal.txt 2>&1 || true
[ -s /tmp/journal.txt ]
ck $? "the run is in the journal"
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/journal.txt
ck $? "no passphrase in the journal"
! grep -q "${BGB_IT_SECRET_KEY}" /tmp/journal.txt
ck $? "no backend secret in the journal"

# Leave the host quiet so a re-run is deterministic.
systemctl stop bg-backup@tick.timer >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
