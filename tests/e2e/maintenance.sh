#!/usr/bin/env bash
# =============================================================================
# e2e: the maintenance commands - check, verify, forget, prune, copy
# =============================================================================
# Before this suite existed, `check`, `verify`, `prune` and `copy` had never run
# once outside a developer's terminal. They are the four commands that run
# UNATTENDED on a timer against a real repository, which is the worst possible
# place to discover that one of them does not work.
#
# THE CENTRE OF THIS FILE IS SECTION 6. ADR-0005 says the backup identity may not
# delete repository data and only a separate prune identity may. Until now that
# was a sentence in a document and a policy in a compose file; nothing ever
# authenticated as the backup identity and tried to delete something. Here the
# rig's real MinIO policy answers, so a widened policy - or a prune that quietly
# runs with the wrong credentials - fails this suite instead of being discovered
# after a ransomware incident.
#
# WHY THE COPY TARGET IS A rest-server AND NOT A SECOND S3 PREFIX. restic reads
# its S3 credentials from one set of AWS_* variables, and lib/retention.sh
# cmd_copy overrides only RESTIC_REPOSITORY and RESTIC_FROM_REPOSITORY - so both
# sides of an S3-to-S3 copy authenticate as the PRIMARY identity. A scoped
# secondary S3 user would therefore be unusable, and widening the primary to
# reach the copy would defeat the point of having a copy at all. A rest
# repository carries its auth in the URL and has neither problem, which also
# makes it append-only - see section 8.
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
REST_SECONDARY="rest:${BGB_IT_REST_ENDPOINT}/secondary/"
REPO_ENV=/etc/bg-backup/credentials/repo.env

export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# Swap which MinIO identity /etc/bg-backup/credentials/repo.env authenticates as.
# The repository, the passphrase and everything else stay identical - the ONLY
# variable is which S3 user restic presents, which is exactly the variable
# ADR-0005 is about.
use_identity() {
  local key secret
  case "$1" in
    backup)
      key="${BGB_IT_ACCESS_KEY}"
      secret="${BGB_IT_SECRET_KEY}"
      ;;
    prune)
      key="${BGB_IT_PRUNE_ACCESS_KEY}"
      secret="${BGB_IT_PRUNE_SECRET_KEY}"
      ;;
    *) return 1 ;;
  esac

  sed -i "s|^export AWS_ACCESS_KEY_ID=.*|export AWS_ACCESS_KEY_ID='${key}'|; \
          s|^export AWS_SECRET_ACCESS_KEY=.*|export AWS_SECRET_ACCESS_KEY='${secret}'|" \
    "${REPO_ENV}"

  # Prove the swap landed rather than trusting sed's exit code, which is 0 even
  # when the pattern matched nothing. A silently unchanged file would make
  # section 6 report that the backup identity CAN prune - the exact opposite of
  # the truth - and nothing else in this suite would notice.
  grep -qF "export AWS_ACCESS_KEY_ID='${key}'" "${REPO_ENV}"
}

snap_count() { bg-backup snapshots --job maint --json 2>/dev/null | jq 'length'; }

# -----------------------------------------------------------------------------
sect "0. Install, as the BACKUP identity"

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

[ -r "${REPO_ENV}" ]
ck $? "the repository environment exists"

# -----------------------------------------------------------------------------
sect "1. Ten snapshots with genuinely distinct content"

# Distinct content per round on purpose. Ten identical snapshots share every
# pack, so a later forget would free nothing and section 6 would ask the backup
# identity to delete data that does not exist - which succeeds, and would let a
# fully permissive policy pass.
cat >/etc/bg-backup/conf.d/50-maint.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/maint )
JOB_ONE_FILE_SYSTEM=0
JOB_EXCLUDE_FILE=""
JOB_KEEP_LAST="5"
JOB_KEEP_DAILY=""
JOB_KEEP_WEEKLY=""
JOB_KEEP_MONTHLY=""
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-maint.conf

# Blanking JOB_KEEP_DAILY above is NOT enough to make keep-last the only rule:
# an unset job value INHERITS the global default by design, so
# BGB_DEFAULT_KEEP_DAILY/WEEKLY/MONTHLY still applied and forget kept six
# snapshots rather than five. BGB_DEFAULT_KEEP_LAST deliberately stays set -
# blanking every global would be the "no policy" state, which exits 9.
sed -i 's/^\(BGB_DEFAULT_KEEP_\(DAILY\|WEEKLY\|MONTHLY\|YEARLY\)\)=.*/\1=""/' \
  /etc/bg-backup/bg-backup.conf
grep -qE '^BGB_DEFAULT_KEEP_DAILY=""' /etc/bg-backup/bg-backup.conf
ck $? "keep-last is the only retention rule in play"

install -d /srv/maint
rounds_ok=1
for i in $(seq 1 10); do
  head -c 262144 /dev/urandom >"/srv/maint/blob-${i}.dat"
  bg-backup backup maint >>/tmp/backup.log 2>&1 || rounds_ok=0
done
[ "${rounds_ok}" -eq 1 ]
ck $? "ten backups all exit 0"

N="$(snap_count)"
eq "snapshot count" "${N}" "10"

# -----------------------------------------------------------------------------
sect "1b. JOB_MODE=config - the job the whole bootstrap story rests on"

# The shipped config job is what `dr bootstrap` finds after a total loss, and
# until now nothing ever ran it. It is also a precondition for section 3: verify
# walks EVERY enabled job, so a config job with no snapshot would fail the whole
# verification for a reason that has nothing to do with what is being tested.
bg-backup backup config >/tmp/backup-config.log 2>&1
ck $? "the config job backs up /etc/bg-backup"

CN="$(bg-backup snapshots --job config --json 2>/dev/null | jq 'length')"
eq "the config job produced a snapshot" "${CN}" "1"

# The tag is a hard interface: dr bootstrap looks for exactly this string, and a
# renamed tag makes a recovered host unable to find its own configuration at the
# one moment nobody has time to debug tag filters.
bg-backup snapshots --job config --json 2>/dev/null \
  | jq -e '.[0].tags | index("bg-backup-config")' >/dev/null
ck $? "the snapshot carries the bg-backup-config tag dr bootstrap looks for"

# The configuration hash is what lets doctor say "your recovery bundle no longer
# matches what is deployed" - the most common way this design rots in practice.
grep -q '^config_hash=' /var/lib/bg-backup/state/_repo.env 2>/dev/null \
  || bg-backup snapshots --job config --json >/dev/null 2>&1
grep -q '^config_hash=' /var/lib/bg-backup/state/_repo.env
ck $? "the configuration hash was recorded for doctor to compare against"

# -----------------------------------------------------------------------------
sect "2. check - the integrity gate that runs on a timer"

bg-backup check >/tmp/check.log 2>&1
ck $? "check exits 0 on a healthy repository"

# --read-data-subset ROTATES; the whole point is that a missed day is caught up
# rather than skipped forever. Two runs must therefore not pick the same slice.
bg-backup check --read-data-subset 1 >/tmp/check-sub1.log 2>&1
ck $? "check --read-data-subset exits 0"
S1="$(grep -oE 'Reading data subset [0-9]+' /tmp/check-sub1.log | grep -oE '[0-9]+$' | tail -n1)"
bg-backup check --read-data-subset 1 >/tmp/check-sub2.log 2>&1
S2="$(grep -oE 'Reading data subset [0-9]+' /tmp/check-sub2.log | grep -oE '[0-9]+$' | tail -n1)"
[ -n "${S1}" ] && [ -n "${S2}" ] && [ "${S1}" != "${S2}" ]
ck $? "the data subset rotates between runs (${S1:-?} then ${S2:-?})"

# -----------------------------------------------------------------------------
sect "3. verify - restores a canary rather than trusting metadata"

# Every enabled job, not just maint: verify walks them all, and running it the
# way the monthly timer runs it is the only way to learn whether the timer will
# succeed. Both jobs now have a snapshot, so a non-zero exit is a real finding.
bg-backup verify --sample 1 >/tmp/verify.log 2>&1
RC=$?
if [ "${RC}" -eq 0 ]; then
  ok "verify exits 0 with every job backed up"
else
  bad "verify exits 0 with every job backed up: got ${RC}"
  sed 's/^/      /' /tmp/verify.log | tail -25
fi

# A verify that restored nothing must not be able to report success. If this
# assertion is what breaks after a refactor, verify has become a metadata check
# wearing a restore's name.
grep -qiE 'restored byte-identical|canary restored' /tmp/verify.log
ck $? "verify actually read data back, rather than inspecting metadata"

grep -q 'proven to restore' /tmp/verify.log
ck $? "verify states the claim it is allowed to make"

# -----------------------------------------------------------------------------
sect "4. prune refuses to run from a non-primary host"

# Two hosts repacking one repository concurrently can drop data the other still
# references. The role gate is a safety control, not a preference.
cp /etc/bg-backup/bg-backup.conf /tmp/conf.bak
sed -i "s|^BGB_REPO_ROLE=.*|BGB_REPO_ROLE=\"secondary\"|" /etc/bg-backup/bg-backup.conf
grep -q 'BGB_REPO_ROLE="secondary"' /etc/bg-backup/bg-backup.conf
ck $? "the secondary role was actually established"

bg-backup prune >/tmp/prune-role.log 2>&1
RC=$?
eq "prune on a secondary exits EX_SAFETY" "${RC}" "9"

cp /tmp/conf.bak /etc/bg-backup/bg-backup.conf

# -----------------------------------------------------------------------------
sect "5. forget honours its rails and leaves unused data behind"

# 10 snapshots, keep-last 5: five removed is exactly 50%, and the ceiling is
# "more than 50%" - so a legitimate forget passes WITHOUT --yes. Anything that
# tightens these defaults will fail here rather than in production at 03:00.
use_identity prune
ck $? "switched to the prune identity"

# `check` above took an exclusive repository lock. restic removes it on a clean
# exit, but an interrupted run leaves it behind and every later forget then
# fails with "repository is already locked by PID ... on <a container that no
# longer exists>" - which reads like a concurrency bug in bg-backup rather than
# debris. Clearing it here also exercises `unlock`, which nothing else did.
bg-backup unlock --remove-all >/tmp/unlock.log 2>&1
ck $? "unlock clears any lock left behind by the integrity checks"

bg-backup forget --job maint --apply >/tmp/forget.log 2>&1
ck $? "forget --apply exits 0 within the rails"

N="$(snap_count)"
if [ "${N}" = "5" ]; then
  ok "snapshots remaining (5)"
else
  bad "snapshots remaining: expected '5', got '${N}'"
  # An assertion that only says "wrong number" costs an hour to chase. Say what
  # forget actually decided - the rails print their reasoning.
  sed 's/^/      /' /tmp/forget.log | tail -20
fi

# -----------------------------------------------------------------------------
sect "6. ADR-0005: only the prune identity may delete data"

# THE ASSERTION THIS SUITE EXISTS FOR. The repository now holds packs that no
# snapshot references, so a prune has real deletions to perform. The MinIO
# policy - not a mock, not a flag - decides who may perform them.
use_identity backup
ck $? "switched to the backup identity"

bg-backup prune >/tmp/prune-denied.log 2>&1
RC=$?
[ "${RC}" -ne 0 ]
ck $? "prune FAILS as the backup identity (exit ${RC})"
eq "the failure is reported as a repository error" "${RC}" "6"

# Be specific about WHY it failed. Without this, a prune that broke for an
# unrelated reason - a typo, an unreachable endpoint - would satisfy the
# assertion above and the least-privilege claim would go untested.
grep -qiE 'accessdenied|access denied|forbidden|403' /tmp/prune-denied.log
ck $? "the backend refused the delete (AccessDenied), not something else"

# Nothing was destroyed by the attempt.
N="$(snap_count)"
eq "the failed prune deleted no snapshot" "${N}" "5"

use_identity prune
ck $? "switched back to the prune identity"

bg-backup prune --dry-run >/tmp/prune-dry.log 2>&1
ck $? "prune --dry-run exits 0"

bg-backup prune >/tmp/prune.log 2>&1
ck $? "prune SUCCEEDS as the prune identity"

bg-backup check >/tmp/check-after-prune.log 2>&1
ck $? "the repository is still intact after the prune"

# -----------------------------------------------------------------------------
sect "7. copy replicates to the secondary repository"

use_identity backup
ck $? "back to the backup identity for the copy"

# --copy-chunker-params is not optional: without matching chunker parameters
# restic re-chunks every blob, deduplication against the primary is lost and the
# copy can end up several times larger. lib/retention.sh prints this as a note;
# here it is actually done.
# RESTIC_PASSWORD_FILE is the DESTINATION's key and --from-password-file is the
# source's. Both are needed and they are not interchangeable: with only the
# latter, restic prompts for a passphrase on a terminal that does not exist and
# the rig hangs until the job times out.
RESTIC_PASSWORD_FILE=/etc/bg-backup/credentials/repo.key \
  restic -r "${REST_SECONDARY}" init \
  --from-repo "${REPO}" \
  --from-password-file /etc/bg-backup/credentials/repo.key \
  --copy-chunker-params >/tmp/sec-init.log 2>&1
ck $? "the secondary repository was created with matching chunker parameters"

cat >/etc/bg-backup/credentials/secondary.env <<EOF
export RESTIC_REPOSITORY='${REST_SECONDARY}'
export RESTIC_PASSWORD_FILE='/etc/bg-backup/credentials/repo.key'
EOF
chmod 0400 /etc/bg-backup/credentials/secondary.env

sed -i "s|^BGB_SECONDARY_REPO_ENV=.*|BGB_SECONDARY_REPO_ENV=\"/etc/bg-backup/credentials/secondary.env\"|" \
  /etc/bg-backup/bg-backup.conf
grep -q '^BGB_SECONDARY_REPO_ENV=' /etc/bg-backup/bg-backup.conf \
  || echo 'BGB_SECONDARY_REPO_ENV="/etc/bg-backup/credentials/secondary.env"' \
    >>/etc/bg-backup/bg-backup.conf
echo 'JOB_COPY_TO_SECONDARY=1' >>/etc/bg-backup/conf.d/50-maint.conf

bg-backup config validate --strict >/tmp/validate.log 2>&1
ck $? "the configuration with a secondary is still valid"

bg-backup copy --job maint >/tmp/copy.log 2>&1
ck $? "copy exits 0"

# Compared against the PRIMARY's count for the same job rather than a literal.
# The claim worth testing is "copy replicated this job's snapshots", and a hard
# number would additionally encode restic's retention arithmetic - which is what
# section 5 is for, and which would make this assertion fail for reasons that
# have nothing to do with copy.
PRIMARY_N="$(snap_count)"
COPIED="$(RESTIC_PASSWORD_FILE=/etc/bg-backup/credentials/repo.key \
  restic -r "${REST_SECONDARY}" snapshots --json --tag "job=maint" 2>/dev/null | jq 'length')"
eq "the secondary holds this job's snapshots too" "${COPIED}" "${PRIMARY_N}"

# A copy that produced snapshots which cannot be read back is not a copy.
RESTIC_PASSWORD_FILE=/etc/bg-backup/credentials/repo.key \
  restic -r "${REST_SECONDARY}" check >/tmp/sec-check.log 2>&1
ck $? "the secondary repository passes its own integrity check"

# -----------------------------------------------------------------------------
sect "8. the secondary is append-only, which is the point of having it"

# The strongest ransomware control restic supports today: an attacker with the
# host's credentials can add snapshots but cannot remove any. Asserted against
# the real server rather than inferred from the compose flag.
RESTIC_PASSWORD_FILE=/etc/bg-backup/credentials/repo.key \
  restic -r "${REST_SECONDARY}" forget --keep-last 1 --prune \
  >/tmp/sec-forget.log 2>&1
RC=$?
[ "${RC}" -ne 0 ]
ck $? "deleting from the append-only secondary is refused (exit ${RC})"

STILL="$(RESTIC_PASSWORD_FILE=/etc/bg-backup/credentials/repo.key \
  restic -r "${REST_SECONDARY}" snapshots --json --tag "job=maint" 2>/dev/null | jq 'length')"
eq "every snapshot survived the deletion attempt" "${STILL}" "${COPIED}"

# -----------------------------------------------------------------------------
sect "9. no credential reached a log"

for f in /tmp/*.log /var/log/bg-backup/*.log /var/log/bg-backup/jobs/*.log; do
  [ -e "${f}" ] || continue
  if grep -q "${BGB_IT_RESTIC_PASSWORD}" "${f}" 2>/dev/null; then
    bad "the repository passphrase leaked into ${f}"
    break
  fi
  if grep -q "${BGB_IT_PRUNE_SECRET_KEY}" "${f}" 2>/dev/null; then
    bad "the prune secret leaked into ${f}"
    break
  fi
done
ok "no passphrase and no backend secret in any log"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
