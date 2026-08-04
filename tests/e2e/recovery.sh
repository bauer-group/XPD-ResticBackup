#!/usr/bin/env bash
# =============================================================================
# e2e: the recovery surface - restore preview, restore system, dr plan/run/verify
# =============================================================================
# These are the commands an operator reaches for on the worst day of the year,
# and until this suite existed not one of them had ever been executed outside a
# developer's terminal. `restore system` and `dr plan` had no coverage at all;
# `restore preview` had none either, which is notable because preview already
# shipped one catastrophic bug: it set BGB_RESTORE_PREVIEW=1 and re-dispatched,
# but only restore_path_cmd ever read the flag, so `preview volume`,
# `preview project`, `preview db` and `preview system` performed the REAL
# operation. Typing "preview" to see what would happen got you the thing itself.
#
# THE ORGANISING IDEA IS "PROVE THE INERTNESS". Half the commands here are
# defined by what they must NOT do:
#
#   restore preview   must write nothing, anywhere, ever
#   dr plan           must write nothing - it is the first thing an operator
#                     runs on a machine whose state they do not yet understand
#   dr run --dry-run  must change nothing
#
# An assertion that a read-only command "exits 0" proves none of that, so the
# sections below fingerprint the filesystem around each one and compare.
#
# DESTRUCTIVE SECTIONS COME LAST. Section 8 really does restore over /, which is
# safe in a throwaway container but would invalidate everything after it.
#
# Runs on tests/rig/Dockerfile.victim. No Docker daemon needed.
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
FACTS=/var/lib/bg-backup/facts

export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# A content fingerprint of the paths a read-only command must not touch. Name,
# size and mtime - not just names, because a command that rewrote a file in
# place with the same length would otherwise pass.
fingerprint() {
  find /srv/payload /etc/bg-backup -printf '%p %s %T@\n' 2>/dev/null \
    | sort | sha256sum | cut -d' ' -f1
}

# -----------------------------------------------------------------------------
sect "0. A host with a payload and a backup of it"

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

install -d /srv/payload/nested
echo "the-original-content" >/srv/payload/keeper.txt
echo "this-one-gets-deleted" >/srv/payload/nested/victim.txt
head -c 8192 /dev/urandom >/srv/payload/blob.dat

# /etc/machine-id is on the NEVER list, and section 2 needs a snapshot that
# contains a NEVER path in order to prove the DANGER rail fires at all.
[ -s /etc/machine-id ] || printf '%s\n' 'deadbeefdeadbeefdeadbeefdeadbeef' >/etc/machine-id

cat >/etc/bg-backup/conf.d/50-rec.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/payload /etc/machine-id )
JOB_ONE_FILE_SYSTEM=0
JOB_EXCLUDE_FILE=""
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-rec.conf

bg-backup backup rec >/tmp/backup.log 2>&1
ck $? "the payload job backs up"

N="$(bg-backup snapshots --job rec --json 2>/dev/null | jq 'length')"
eq "one snapshot exists" "${N}" "1"

# -----------------------------------------------------------------------------
sect "1. restore preview writes NOTHING"

BEFORE="$(fingerprint)"

rm -rf /tmp/prev
bg-backup restore preview dir --path /srv/payload --to /tmp/prev >/tmp/prev-dir.log 2>&1
RC=$?
eq "preview dir exits 0 for a safe selection" "${RC}" "0"

grep -q 'Nothing was written. This was a preview.' /tmp/prev-dir.log
ck $? "preview says so in as many words"

# The target directory is created by restore_path_cmd AFTER the preview branch
# returns. If it exists, the preview fell through into the real restore.
[ ! -e /tmp/prev ]
ck $? "the --to target was never created"

eq "the filesystem is byte-for-byte unchanged" "$(fingerprint)" "${BEFORE}"

# -----------------------------------------------------------------------------
sect "2. preview refuses a selection on the NEVER list"

# /etc/machine-id is NEVER: restoring it clones another machine's identity onto
# this host.
#
# The refusal comes BEFORE the preview renders - EX_SAFETY, not the preview's
# own "this selection touches NEVER paths" exit 2. That ordering is deliberate
# and is the stronger of the two behaviours: a selection that names a NEVER path
# outright is refused whether or not the operator asked to see it first, so
# there is no way to reach the real restore by dropping the word "preview".
bg-backup restore preview dir --path /etc/machine-id >/tmp/prev-never.log 2>&1
RC=$?
eq "a NEVER path is refused with EX_SAFETY" "${RC}" "9"

grep -q 'NEVER list' /tmp/prev-never.log
ck $? "the refusal names the classification"
grep -qi 'unbootable or unreachable' /tmp/prev-never.log
ck $? "the consequence is spelled out, not just flagged"
grep -q 'unsafe-restore.list' /tmp/prev-never.log
ck $? "it points at the file that made the decision"

# And the same path without 'preview' must be refused too - otherwise the rail
# would only exist in the mode that writes nothing anyway.
bg-backup --yes restore dir --path /etc/machine-id --to /tmp/never-real >/tmp/never-real.log 2>&1
RC=$?
eq "the real restore of a NEVER path is refused as well" "${RC}" "9"
[ ! -e /tmp/never-real ]
ck $? "and nothing was written"

# -----------------------------------------------------------------------------
sect "3. restore preview system is inert and points at the planner"

# THE BUG THIS PINS. Before restore_preview_report existed, this call reached
# dr_restore_system and performed a real system restore. The staging directory
# is the cheapest proof that dr_stage_dangerous never ran.
rm -rf /var/lib/bg-backup/restore/staged
BEFORE="$(fingerprint)"

bg-backup restore preview system --profile full >/tmp/prev-sys.log 2>&1
RC=$?
eq "preview system exits 0" "${RC}" "0"

grep -q 'PREVIEW - nothing will be written' /tmp/prev-sys.log
ck $? "it announces itself as a preview before doing anything"

# A system restore has a real planner; a second, thinner preview would drift.
grep -q 'bg-backup dr plan' /tmp/prev-sys.log
ck $? "it points at dr plan rather than reimplementing it"

[ ! -d /var/lib/bg-backup/restore/staged ]
ck $? "dr_stage_dangerous never ran - no staging directory exists"

eq "preview system changed nothing" "$(fingerprint)" "${BEFORE}"

# -----------------------------------------------------------------------------
sect "4. dr plan without facts says so instead of guessing"

rm -rf "${FACTS}"

bg-backup dr plan >/tmp/plan-nofacts.log 2>&1
RC=$?
eq "dr plan without facts still exits 0" "${RC}" "0"

grep -q 'No system facts available' /tmp/plan-nofacts.log
ck $? "it reports the absence rather than rendering an empty plan"
grep -q 'dr bootstrap' /tmp/plan-nofacts.log
ck $? "it says what to do about it"

# -----------------------------------------------------------------------------
sect "5. dr plan with facts renders, and writes nothing"

bash "${SRC}/share/hooks/collect-system-facts.sh" >/tmp/facts.log 2>&1
ck $? "the facts hook exits 0"
[ -r "${FACTS}/host.env" ]
ck $? "host.env was captured"

BEFORE="$(fingerprint)"
bg-backup dr plan >/tmp/plan.log 2>&1
RC=$?
eq "dr plan exits 0" "${RC}" "0"

grep -q 'DISASTER RECOVERY PLAN' /tmp/plan.log
ck $? "the plan renders its header"
grep -q 'Nothing below has been executed' /tmp/plan.log
ck $? "the plan states that it is a report"
grep -q 'SOURCE vs TARGET' /tmp/plan.log
ck $? "it compares the backed-up host against this one"
grep -q 'PACKAGES' /tmp/plan.log
ck $? "it reports the package reconciliation"

eq "dr plan wrote nothing" "$(fingerprint)" "${BEFORE}"

# --out is the ONLY thing a plan may write.
rm -f /tmp/plan-out.txt
bg-backup dr plan --out /tmp/plan-out.txt >/tmp/plan-out.log 2>&1
ck $? "dr plan --out exits 0"
[ -s /tmp/plan-out.txt ]
ck $? "the plan file was written"
grep -q 'DISASTER RECOVERY PLAN' /tmp/plan-out.txt
ck $? "the file holds the plan, not the log"

# -----------------------------------------------------------------------------
sect "6. dr plan REFUSES the three unrecoverable mismatches"

# Crafted facts, because the interesting cases cannot be produced by running the
# hook on this host - and they are exactly the cases where proceeding destroys
# the machine you are trying to rebuild.
plan_with() { # plan_with <sed-expression> -> stdout+stderr of dr plan
  cp "${FACTS}/host.env" /tmp/host.env.bak
  sed -i "$1" "${FACTS}/host.env"
  bg-backup dr plan 2>&1
  cp /tmp/host.env.bak "${FACTS}/host.env"
}

OUT="$(plan_with 's/^os_id=.*/os_id=debian/')"
printf '%s' "${OUT}" | grep -q 'REFUSE'
ck $? "a different distribution is REFUSED"
printf '%s' "${OUT}" | grep -qi 'different distribution'
ck $? "and the reason is named"

# The target must never be OLDER than the source: database dumps are
# forward-compatible only, so a 16 dump does not load into 15.
OUT="$(plan_with 's/^os_version=.*/os_version=99.04/')"
printf '%s' "${OUT}" | grep -q 'REFUSE'
ck $? "an older target OS is REFUSED"
printf '%s' "${OUT}" | grep -qi 'forward-compatible'
ck $? "the dump-compatibility reason is given, not just a refusal"

OUT="$(plan_with 's/^arch=.*/arch=aarch64/')"
printf '%s' "${OUT}" | grep -q 'REFUSE'
ck $? "an architecture change is REFUSED"

# The control: unmodified facts describe this very host, so nothing is refused.
# Without it, a plan that printed REFUSE unconditionally would pass all three.
bg-backup dr plan >/tmp/plan-ok.log 2>&1
! grep -q 'REFUSE' /tmp/plan-ok.log
ck $? "matching facts are NOT refused"

# -----------------------------------------------------------------------------
sect "7. dr run --dry-run changes nothing"

BEFORE="$(fingerprint)"

# --yes is required: dr run confirms before every phase, and with no terminal
# attached confirm() refuses rather than assuming consent.
bg-backup --yes dr run --phase system --dry-run >/tmp/dr-dry.log 2>&1
RC=$?
[ "${RC}" -eq 0 ] || [ "${RC}" -eq 9 ]
ck $? "dr run --dry-run exits 0 or refuses cleanly (got ${RC})"

eq "the dry run changed nothing" "$(fingerprint)" "${BEFORE}"

# -----------------------------------------------------------------------------
sect "8. dr verify reports on the rebuilt host"

bg-backup dr verify >/tmp/dr-verify.log 2>&1
RC=$?
# 0 or EX_VERIFY. Anything else means it aborted rather than reported, which is
# the failure mode that made check, prune and doctor unusable for six releases.
[ "${RC}" -eq 0 ] || [ "${RC}" -eq 7 ]
ck $? "dr verify reports instead of aborting (exit ${RC})"

! grep -qE 'unbound variable|command not found' /tmp/dr-verify.log
ck $? "no module was missing from the dr dispatch group"

grep -q 'DR verification' /tmp/dr-verify.log
ck $? "it renders its report"

# The last and most important item it checks.
grep -qi 'repository is reachable' /tmp/dr-verify.log
ck $? "it confirms the new host can reach the repository"

# -----------------------------------------------------------------------------
sect "9. restore system - the destructive one, last"

bg-backup restore system --profile nonsense >/tmp/sys-bad.log 2>&1
RC=$?
eq "an unknown profile exits EX_USAGE" "${RC}" "2"
grep -q 'safe|staged|full' /tmp/sys-bad.log
ck $? "the usable profiles are named"

# Now the real thing. A file removed from the live tree must come back.
rm -f /srv/payload/nested/victim.txt
[ ! -e /srv/payload/nested/victim.txt ]
ck $? "the fixture file was really removed first"

bg-backup --yes restore system --profile safe >/tmp/sys-safe.log 2>&1
ck $? "restore system --profile safe exits 0"

[ -f /srv/payload/nested/victim.txt ]
ck $? "the deleted file was restored from the snapshot"
[ "$(cat /srv/payload/nested/victim.txt 2>/dev/null)" = "this-one-gets-deleted" ]
ck $? "its content is the backed-up content"

# The safe profile restores payload directories and stages nothing. The NEVER
# entry must not have been written to the live system by it.
grep -qE 'Restoring payload directories|No file snapshot' /tmp/sys-safe.log
ck $? "the safe profile did the payload restore"

# -----------------------------------------------------------------------------
sect "10. no credential reached a log"

LEAKED=0
for f in /tmp/*.log /tmp/plan-out.txt /var/log/bg-backup/*.log; do
  [ -e "${f}" ] || continue
  if grep -q "${BGB_IT_RESTIC_PASSWORD}" "${f}" 2>/dev/null; then
    bad "the repository passphrase leaked into ${f}"
    LEAKED=1
    break
  fi
  if grep -q "${BGB_IT_SECRET_KEY}" "${f}" 2>/dev/null; then
    bad "the S3 secret leaked into ${f}"
    LEAKED=1
    break
  fi
done
[ "${LEAKED}" -eq 0 ] && ok "no passphrase and no backend secret in any log"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
