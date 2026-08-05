#!/usr/bin/env bash
# =============================================================================
# e2e: self-update, rollback, uninstall and the systemd-only entry points
# =============================================================================
# The commands that change the installation itself, plus `bg-backup internal`,
# which exists solely so systemd's ExecStopPost= and OnFailure= have something
# to call. None had ever been executed.
#
# `internal` deserves special mention: it runs when the MAIN PROCESS IS ALREADY
# DEAD - killed by a timeout, by OOM, by a reboot. That is the one moment when a
# "command not found" cannot be noticed by anyone, because there is no
# foreground run left to report it. It was also, in this codebase, the exact
# defect class that took out check, prune and doctor for six releases.
#
# WHAT DEPENDS ON THE NETWORK AND WHAT DOES NOT. `self-update --check` asks
# GitHub what the latest release is, so the assertion here is that it either
# answers or fails CLEANLY - a rate-limited runner must not look like a broken
# command. Rollback needs no network at all and is asserted strictly: a second
# release directory is synthesised and the symlink must really move.
#
# Runs on tests/rig/Dockerfile.victim.
# =============================================================================

# The assertion idiom here is deliberately `[ condition ]; ck $?`.
# shellcheck disable=SC2319
set -uo pipefail

SRC=/opt/bgb
PASS=0
FAIL=0
PREFIX=/opt/bg-backup

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

# The signature of a command that was never executed.
no_abort() { # no_abort <file> <label>
  if grep -qE 'unbound variable|command not found' "$1"; then
    bad "$2: aborted ($(grep -oE '[a-zA-Z_]+: (unbound variable|command not found)' "$1" | head -1))"
    return 1
  fi
  ok "$2"
  return 0
}

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# -----------------------------------------------------------------------------
sect "0. An installed host"

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

install -d /srv/life
echo alive >/srv/life/f
cat >/etc/bg-backup/conf.d/50-life.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/life )
JOB_KEEP_LAST="5"
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-life.conf

bg-backup backup life >/tmp/backup.log 2>&1
ck $? "a backup exists to protect"

# -----------------------------------------------------------------------------
sect "1. bg-backup internal - the entry points systemd uses"

# unquiesce is what ExecStopPost= calls to undo a filesystem freeze or a paused
# container after the main process died. If it aborts, the host is left frozen.
bg-backup internal unquiesce life >/tmp/unquiesce.log 2>&1
UQ=$?
no_abort /tmp/unquiesce.log "internal unquiesce runs (exit ${UQ})"

# It has to be safe when there is nothing to undo, because that is the common
# case: systemd calls ExecStopPost= after EVERY run, successful or not.
bg-backup internal unquiesce life >/tmp/unquiesce2.log 2>&1
eq "unquiesce is idempotent" "$?" "${UQ}"

# notify-failure is OnFailure='s target. It runs with the main process gone.
bg-backup internal notify-failure "bg-backup@life.service" >/tmp/notifyfail.log 2>&1
NF=$?
no_abort /tmp/notifyfail.log "internal notify-failure runs (exit ${NF})"

# An unknown subcommand must be a usage error, not a silent success - systemd
# would otherwise report a healthy ExecStopPost= for a typo in a unit file.
bg-backup internal nonsense >/tmp/internal-bad.log 2>&1
eq "an unknown internal subcommand exits EX_USAGE" "$?" "2"

# -----------------------------------------------------------------------------
sect "2. self-update --check"

bg-backup self-update --check >/tmp/update-check.log 2>&1
UC=$?
no_abort /tmp/update-check.log "self-update --check runs (exit ${UC})"

# Either it answers, or it says why it cannot. What it must not do is exit
# non-zero with an empty log, which is indistinguishable from a crash.
[ -s /tmp/update-check.log ]
ck $? "it said something either way"
grep -qiE 'version|latest|up to date|newer|release|unable|failed|network|rate' /tmp/update-check.log
ck $? "the message is about updating, not a stack trace"

# --check must never change anything. It is what an operator runs to decide.
CURRENT_BEFORE="$(readlink -f "${PREFIX}/current")"
bg-backup self-update --check >/dev/null 2>&1 || true
eq "--check did not move the current symlink" "$(readlink -f "${PREFIX}/current")" "${CURRENT_BEFORE}"

# -----------------------------------------------------------------------------
sect "3. rollback moves the symlink, and needs no network"

# Synthesise a previous release. selfupdate_rollback picks the most recent
# release directory that is NOT the current one, so the copy must be older -
# hence the explicit mtime rather than relying on copy order.
PREV="${PREFIX}/releases/0.0.1-previous"
cp -a "${CURRENT_BEFORE}" "${PREV}"
touch -d '2020-01-01' "${PREV}"
[ -d "${PREV}" ]
ck $? "a previous release exists to roll back to"

bg-backup --yes self-update --rollback >/tmp/rollback.log 2>&1
RB=$?
no_abort /tmp/rollback.log "self-update --rollback runs (exit ${RB})"

NOW="$(readlink -f "${PREFIX}/current")"
eq "current now points at the previous release" "${NOW}" "${PREV}"

# And the tool must still work from the rolled-back release - a rollback that
# leaves an unusable installation is worse than the bug it was undoing.
bg-backup version >/tmp/version-after-rollback.log 2>&1
ck $? "bg-backup still runs after the rollback"
bg-backup snapshots --job life >/tmp/snap-after-rollback.log 2>&1
ck $? "and can still reach the repository"

# Roll forward again so the rest of the suite runs against the real release.
ln -sfn "${CURRENT_BEFORE}" "${PREFIX}/current.new"
mv -T "${PREFIX}/current.new" "${PREFIX}/current"
rm -rf "${PREV}"
eq "restored to the real release" "$(readlink -f "${PREFIX}/current")" "${CURRENT_BEFORE}"

# With no previous release, rollback must refuse rather than break the symlink.
bg-backup --yes self-update --rollback >/tmp/rollback-none.log 2>&1
RN=$?
[ "${RN}" -ne 0 ]
ck $? "rollback with nothing to roll back to refuses (exit ${RN})"
eq "and left the installation alone" "$(readlink -f "${PREFIX}/current")" "${CURRENT_BEFORE}"

# -----------------------------------------------------------------------------
sect "4. uninstall keeps the configuration and never touches the repository"

BEFORE_SNAPS="$(bg-backup snapshots --json 2>/dev/null | jq 'length')"
[ -n "${BEFORE_SNAPS}" ]
ck $? "the repository holds ${BEFORE_SNAPS:-?} snapshot(s) before uninstall"

bg-backup --yes uninstall >/tmp/uninstall.log 2>&1
UN=$?
no_abort /tmp/uninstall.log "bg-backup uninstall runs (exit ${UN})"

[ ! -d "${PREFIX}" ] || [ ! -e "${PREFIX}/current" ]
ck $? "the installation is gone"

# Without --purge the configuration survives. An uninstall that also deleted
# /etc/bg-backup would take the recovery card's counterpart with it.
[ -d /etc/bg-backup ]
ck $? "the configuration is kept without --purge"
[ -f /etc/bg-backup/credentials/repo.env ]
ck $? "and so are the credentials"

# THE ASSERTION THAT MATTERS: uninstalling the tool must never touch the data.
export RESTIC_REPOSITORY="${REPO}"
export RESTIC_PASSWORD_FILE=/root/.bgb-pass
AFTER_SNAPS="$(restic snapshots --json 2>/dev/null | jq 'length')"
eq "the repository is untouched by the uninstall" "${AFTER_SNAPS}" "${BEFORE_SNAPS}"
unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

# -----------------------------------------------------------------------------
sect "5. --purge removes the configuration, deliberately"

# Reinstall so there is something to purge.
SOURCE_DIR="${SRC}" INSTALL_METHOD=local bash "${SRC}/install.sh" >/tmp/reinstall.log 2>&1
ck $? "reinstall exits 0"

bg-backup --yes uninstall --purge >/tmp/purge.log 2>&1
PU=$?
no_abort /tmp/purge.log "uninstall --purge runs (exit ${PU})"

[ ! -d /etc/bg-backup ] || [ -z "$(ls -A /etc/bg-backup 2>/dev/null)" ]
ck $? "--purge removed the configuration"

# Even --purge must not reach the repository. This is the last line between a
# decommission and a data loss.
export RESTIC_REPOSITORY="${REPO}"
export RESTIC_PASSWORD_FILE=/root/.bgb-pass
PURGED_SNAPS="$(restic snapshots --json 2>/dev/null | jq 'length')"
eq "the repository survives --purge" "${PURGED_SNAPS}" "${BEFORE_SNAPS}"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
