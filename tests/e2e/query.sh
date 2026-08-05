#!/usr/bin/env bash
# =============================================================================
# e2e: the commands an operator types while something is going wrong
# =============================================================================
# status, logs, ls, find, diff, stats, runs, dump, mount, unlock and the config
# inspection commands. None of them had ever been executed by a test.
#
# They are read-only, which is exactly why they went uncovered - and exactly why
# their being broken is so expensive. These are what someone reaches for at
# 03:00 when a backup looks wrong. A `status` that aborts, or a `logs` that
# prints nothing, turns a five-minute triage into an hour of reading shell
# scripts by torchlight. Two of this session's product bugs (doctor, check) were
# precisely this shape: dead on arrival, in the diagnostic path, unnoticed for
# six releases because nothing ever ran them.
#
# THE ASSERTIONS ARE DELIBERATELY SHALLOW ON FORMATTING AND STRICT ON TWO
# THINGS: that the command completes, and that its --json output is really JSON.
# Pinning exact table layouts would make this suite a maintenance tax that
# catches nothing; a command that aborts, or that emits a log line into a JSON
# stream, is a defect every time.
#
# Runs on tests/rig/Dockerfile.victim.
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

# Run a command, then assert it neither aborted on a missing module nor on an
# unset variable. That pair is the signature of every "this command was never
# executed" defect found in this codebase.
runs_clean() { # runs_clean <label> <cmd...>
  local label="$1"
  shift
  "$@" >/tmp/rc.out 2>&1
  local rc=$?
  # BASH's abort message, not bg-backup's own precondition message. The two
  # look alike: bash says "file: line 12: foo: command not found", while
  # `require_cmd` deliberately says "Required command not found: fusermount".
  # Matching the bare substring flagged a correct, well-worded refusal as a bug.
  if grep -qE 'unbound variable|line [0-9]+: [a-zA-Z_]+: command not found' /tmp/rc.out; then
    bad "${label}: aborted ($(grep -oE '[a-zA-Z_]+: (unbound variable|command not found)' /tmp/rc.out | tail -1))"
    return 1
  fi
  ok "${label} (exit ${rc})"
  return 0
}

is_json() { jq -e . >/dev/null 2>&1 <"$1"; }

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# -----------------------------------------------------------------------------
sect "0. Two snapshots with a difference between them"

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

install -d /srv/q/sub
echo one >/srv/q/first.txt
echo shared >/srv/q/sub/keep.txt

cat >/etc/bg-backup/conf.d/50-q.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/q )
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-q.conf

bg-backup backup q >/tmp/b1.log 2>&1
ck $? "the first backup succeeds"

echo two >/srv/q/second.txt
rm -f /srv/q/first.txt
bg-backup backup q >/tmp/b2.log 2>&1
ck $? "the second backup succeeds"

mapfile -t SNAPS < <(bg-backup snapshots --job q --json 2>/dev/null | jq -r '.[].short_id')
eq "two snapshots exist" "${#SNAPS[@]}" "2"
S1="${SNAPS[0]:-}"
S2="${SNAPS[1]:-}"

# -----------------------------------------------------------------------------
sect "1. status - the first thing anybody runs"

runs_clean "status" bg-backup status
cp /tmp/rc.out /tmp/status.txt
grep -q 'q' /tmp/status.txt
ck $? "status mentions the configured job"

runs_clean "status --job q" bg-backup status --job q

# status must be able to say "this is stale". It is the only command that
# answers "did last night work" without reading a log.
grep -qiE 'ago|never|ok|stale|age|last' /tmp/status.txt
ck $? "status reports an age or a state"

# -----------------------------------------------------------------------------
sect "2. logs"

runs_clean "logs" bg-backup logs
runs_clean "logs q" bg-backup logs q
runs_clean "logs --lines 5" bg-backup logs q --lines 5

bg-backup logs q --lines 5 >/tmp/logs5.txt 2>&1
[ -s /tmp/logs5.txt ]
ck $? "logs produced output"
# --lines is a bound, not a suggestion. An unbounded log dump in a terminal is
# how an operator loses the line they were looking at.
[ "$(grep -c . /tmp/logs5.txt)" -le 20 ]
ck $? "--lines 5 does not dump the whole file ($(grep -c . /tmp/logs5.txt) lines)"

# -----------------------------------------------------------------------------
sect "3. ls, find, diff - reading a snapshot"

runs_clean "ls <snapshot>" bg-backup ls "${S1}"
cp /tmp/rc.out /tmp/ls.txt
grep -q 'srv/q' /tmp/ls.txt
ck $? "ls lists the backed-up path"

bg-backup ls "${S1}" --json >/tmp/ls.json 2>/dev/null
is_json /tmp/ls.json
ck $? "ls --json emits valid JSON"

runs_clean "find" bg-backup find 'keep.txt'
cp /tmp/rc.out /tmp/find.txt
grep -q 'keep.txt' /tmp/find.txt
ck $? "find locates a file that exists"

bg-backup find 'keep.txt' --json >/tmp/find.json 2>/dev/null
is_json /tmp/find.json
ck $? "find --json emits valid JSON"

# A pattern that matches nothing must be an empty answer, not an error - "no
# results" and "the command is broken" have to be distinguishable.
bg-backup find 'no-such-file-anywhere-xyz' >/tmp/find0.txt 2>&1
RC=$?
eq "find with no match still exits 0" "${RC}" "0"

if [ -n "${S1}" ] && [ -n "${S2}" ]; then
  runs_clean "diff" bg-backup diff "${S2}" "${S1}"
  cp /tmp/rc.out /tmp/diff.txt
  # The second backup removed first.txt and added second.txt; a diff that
  # reports neither is not reading the snapshots.
  grep -qE 'first\.txt|second\.txt' /tmp/diff.txt
  ck $? "diff reports the change between the two snapshots"
else
  bad "diff was not exercised - no two snapshots"
fi

# -----------------------------------------------------------------------------
sect "4. dump - a single file, without a restore"

bg-backup dump "${S1}" /srv/q/sub/keep.txt >/tmp/dumped.txt 2>/tmp/dump.err
ck $? "dump exits 0"
eq "dump wrote the file's content" "$(cat /tmp/dumped.txt 2>/dev/null)" "shared"

bg-backup dump "${S1}" /srv/q/sub/keep.txt --to /tmp/dumped2.txt >/tmp/dump2.log 2>&1
ck $? "dump --to exits 0"
eq "dump --to wrote the same bytes" "$(cat /tmp/dumped2.txt 2>/dev/null)" "shared"

# -----------------------------------------------------------------------------
sect "5. stats and runs"

runs_clean "stats" bg-backup stats
bg-backup stats --json >/tmp/stats.json 2>/dev/null
is_json /tmp/stats.json
ck $? "stats --json emits valid JSON"

runs_clean "stats --mode raw-data" bg-backup stats --mode raw-data
runs_clean "runs" bg-backup runs
cp /tmp/rc.out /tmp/runs.txt

# runs lists what actually happened; two backups must show up as two runs.
[ "$(grep -c 'q' /tmp/runs.txt)" -ge 2 ]
ck $? "runs lists both backups"

# -----------------------------------------------------------------------------
sect "6. unlock and mount"

runs_clean "unlock" bg-backup unlock
runs_clean "unlock --remove-all" bg-backup unlock --remove-all

# mount needs FUSE, which this container does not have. What must NOT happen is
# a stack trace or an unbound variable - a missing kernel feature is a
# precondition, and the operator has to be told which one.
bg-backup mount /mnt >/tmp/mount.log 2>&1
MRC=$?
! grep -qE 'unbound variable|line [0-9]+: [a-zA-Z_]+: command not found' /tmp/mount.log
ck $? "mount fails on a precondition, not on a bug (exit ${MRC})"
if [ "${MRC}" -ne 0 ]; then
  # EX_PRECOND, and a message naming the missing dependency. "It did not work"
  # with no reason is what sends an operator into the source at 03:00.
  eq "mount reports a precondition failure" "${MRC}" "4"
  grep -qiE 'fuse|fusermount|Required command not found' /tmp/mount.log
  ck $? "and it names what is missing"
else
  ok "mount succeeded - FUSE is available here"
fi

# -----------------------------------------------------------------------------
sect "7. config inspection and the built-ins"

runs_clean "config show" bg-backup config show
cp /tmp/rc.out /tmp/confshow.txt
! grep -q "${BGB_IT_SECRET_KEY}" /tmp/confshow.txt
ck $? "config show does not print the S3 secret"

runs_clean "config validate" bg-backup config validate
runs_clean "config validate --strict" bg-backup config validate --strict

# EDITOR is honoured rather than hard-coded; `true` makes the edit a no-op and
# exercises the write-back path without a terminal.
EDITOR=/bin/true bg-backup config edit >/tmp/edit.log 2>&1
RC=$?
! grep -qE 'unbound variable|command not found' /tmp/edit.log
ck $? "config edit runs its editor and returns (exit ${RC})"
bg-backup config validate --strict >/tmp/validate-after-edit.log 2>&1
ck $? "the configuration is still valid after an edit"

runs_clean "version" bg-backup version
bg-backup version --json >/tmp/version.json 2>/dev/null
is_json /tmp/version.json
ck $? "version --json emits valid JSON"

runs_clean "completion bash" bg-backup completion bash
cp /tmp/rc.out /tmp/completion.sh
bash -n /tmp/completion.sh
ck $? "the emitted completion script is syntactically valid bash"

runs_clean "help" bg-backup help

# -----------------------------------------------------------------------------
sect "8. no secret in any of it"

LEAKED=0
for f in /tmp/*.txt /tmp/*.log /tmp/*.json; do
  [ -e "${f}" ] || continue
  if grep -q "${BGB_IT_RESTIC_PASSWORD}" "${f}" 2>/dev/null; then
    bad "the passphrase leaked into ${f}"
    LEAKED=1
    break
  fi
  if grep -q "${BGB_IT_SECRET_KEY}" "${f}" 2>/dev/null; then
    bad "the S3 secret leaked into ${f}"
    LEAKED=1
    break
  fi
done
[ "${LEAKED}" -eq 0 ] && ok "no credential in any command's output"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
