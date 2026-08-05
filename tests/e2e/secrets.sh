#!/usr/bin/env bash
# =============================================================================
# e2e: the bootstrap story - export, import, key rotation, recovery card
# =============================================================================
# lib/secrets.sh is 746 lines and had one covered path: `dr bootstrap` READING a
# bundle somebody else made. Everything that MAKES one - config export, the
# escrow copy, the recovery card - and everything that changes a key - rotation,
# adding a recovery key - had never run.
#
# That is the wrong module to guess about. After a total loss the operator has
# the recovery card and nothing else; if the bundle it points at was never
# written, or was written unencrypted to a third-party bucket, or the rotated
# passphrase never actually took, the discovery happens at the worst possible
# moment and there is no second chance.
#
# THE TWO ASSERTIONS THIS SUITE EXISTS FOR:
#
#   * a round trip. /etc/bg-backup is destroyed and rebuilt from the bundle,
#     then validated. Anything less proves the export produced bytes, not that
#     the bytes are a configuration.
#   * rotation really rotates. After `rotate-repo-password` the OLD passphrase
#     must STOP opening the repository. An export that still works with the old
#     key is not a rotation, it is a second key - and the difference only
#     matters after the old one has leaked.
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

REPO="s3:${BGB_IT_ENDPOINT}/${BGB_IT_BUCKET}/${BGB_IT_PREFIX}"
BUNDLE=/root/bundle.tar.age
ESCROW_DIR=/srv/escrow
BUNDLE_PASS=/root/.bundle-pass

export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

# Which MinIO identity repo.env presents. A FULL rotation needs the prune
# identity: removing the old key deletes <prefix>/keys/<id>, and ADR-0005 lets
# the backup identity delete nothing but its own locks. See section 7.
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
    /etc/bg-backup/credentials/repo.env
  export AWS_ACCESS_KEY_ID="${key}" AWS_SECRET_ACCESS_KEY="${secret}"
  grep -qF "export AWS_ACCESS_KEY_ID='${key}'" /etc/bg-backup/credentials/repo.env
}

# Can restic open the repository with this passphrase file? Used as a positive
# AND a negative assertion, so it must never abort the suite itself.
repo_opens_with() {
  RESTIC_PASSWORD_FILE="$1" restic -r "${REPO}" snapshots >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
sect "0. A configured host with something worth recovering"

printf '%s' "${BGB_IT_RESTIC_PASSWORD}" >/root/.bgb-pass
chmod 0400 /root/.bgb-pass
printf '%s' 'bundle-throwaway-passphrase' >"${BUNDLE_PASS}"
chmod 0400 "${BUNDLE_PASS}"

SOURCE_DIR="${SRC}" INSTALL_METHOD=local \
  INIT_REPO=1 \
  BGB_REPOSITORY="${REPO}" \
  BGB_PASSWORD_FILE=/root/.bgb-pass \
  BGB_S3_ACCESS_KEY="${BGB_IT_ACCESS_KEY}" \
  BGB_S3_SECRET_KEY="${BGB_IT_SECRET_KEY}" \
  BGB_S3_REGION="${BGB_IT_REGION}" \
  bash "${SRC}/install.sh" >/tmp/install.log 2>&1
ck $? "install.sh exits 0"

install -d "${ESCROW_DIR}" /srv/payload
echo secret-payload >/srv/payload/f

# A marker that must survive the round trip. A configuration that comes back
# "valid" but without the operator's own jobs is not a recovered configuration.
cat >/etc/bg-backup/conf.d/50-marker.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/payload )
JOB_DESCRIPTION="THE-ROUND-TRIP-MARKER"
JOB_KEEP_LAST="5"
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-marker.conf

sed -i "s|^BGB_ESCROW_LOCAL=.*|BGB_ESCROW_LOCAL=\"${ESCROW_DIR}/bundle.tar.age\"|" \
  /etc/bg-backup/bg-backup.conf
grep -q "^BGB_ESCROW_LOCAL=" /etc/bg-backup/bg-backup.conf \
  || echo "BGB_ESCROW_LOCAL=\"${ESCROW_DIR}/bundle.tar.age\"" >>/etc/bg-backup/bg-backup.conf

bg-backup config validate --strict >/tmp/validate.log 2>&1
ck $? "the starting configuration is valid"

# -----------------------------------------------------------------------------
sect "1. secrets show redacts by default"

bg-backup secrets show >/tmp/show.log 2>&1
ck $? "secrets show exits 0"

! grep -q "${BGB_IT_SECRET_KEY}" /tmp/show.log
ck $? "the S3 secret is redacted"
! grep -q "${BGB_IT_RESTIC_PASSWORD}" /tmp/show.log
ck $? "the repository passphrase is redacted"

# It must still be USEFUL - a command that prints nothing also passes the two
# assertions above.
grep -qiE 'repositor|credential|key' /tmp/show.log
ck $? "it still reports what is configured"

# --reveal REFUSES WITHOUT A TERMINAL, deliberately. A secret printed into a
# pipe ends up in a CI log, a `tee`, a scrollback buffer somebody screen-shares.
# Requiring a TTY means the operator has to be sitting there.
bg-backup secrets show --reveal >/tmp/reveal.log 2>&1
RC=$?
eq "--reveal without a terminal is refused" "${RC}" "4"
grep -qi 'requires a terminal' /tmp/reveal.log
ck $? "and it says why"
! grep -q "${BGB_IT_SECRET_KEY}" /tmp/reveal.log
ck $? "nothing was revealed into the pipe"

# -----------------------------------------------------------------------------
sect "2. the recovery card names what a stranger would need"

bg-backup secrets print-recovery-card >/tmp/card.txt 2>&1
ck $? "print-recovery-card exits 0"
[ -s /tmp/card.txt ]
ck $? "the card is not empty"

grep -q "${BGB_IT_BUCKET}" /tmp/card.txt
ck $? "the card names the repository"
grep -qiE 'bundle|escrow|export' /tmp/card.txt
ck $? "the card says where the bundle lives"

# -----------------------------------------------------------------------------
sect "3. config export produces an ENCRYPTED bundle"

rm -f /root/bundle.tar.*
bg-backup config export --out "${BUNDLE}" --passphrase-file "${BUNDLE_PASS}" --batch \
  >/tmp/export.log 2>&1
ck $? "config export exits 0"

# THE OUTPUT NAME IS PER METHOD, not the literal --out path. `age` is absent on
# a bare Ubuntu, so the export falls back to gpg and openssl and writes
# bundle.tar.gpg and bundle.tar.enc. Asserting the exact --out path would fail
# on a CORRECT export; asserting only "some file appeared" would pass on a
# broken one - so the count is checked too.
mapfile -t PRODUCED < <(find /root -maxdepth 1 -name 'bundle.tar.*' -size +0c | sort)
[ "${#PRODUCED[@]}" -ge 1 ]
ck $? "an encrypted copy was written (${PRODUCED[*]:-none})"

# Independently encrypted copies are the design: one method going wrong - a gpg
# upgrade, a lost key - must not leave the operator with nothing.
[ "${#PRODUCED[@]}" -ge 2 ]
ck $? "more than one method produced a copy (${#PRODUCED[@]})"

# Each copy is decrypted again before the command claims success. An export that
# writes an unopenable file is worse than one that fails loudly.
grep -q 'round trip verified' /tmp/export.log
ck $? "each copy was decrypted again before being trusted"

BUNDLE="${PRODUCED[0]:-/root/bundle.tar.none}"

# The bundle lands on storage that restic does NOT encrypt - a third-party
# bucket, a colleague's laptop - so it carries its own encryption. Grepping the
# raw bytes is the bluntest possible check and exactly the right one.
! grep -aq "${BGB_IT_SECRET_KEY}" "${BUNDLE}"
ck $? "the S3 secret is not readable in the bundle"
! grep -aq "${BGB_IT_RESTIC_PASSWORD}" "${BUNDLE}"
ck $? "the repository passphrase is not readable in the bundle"
! grep -aq 'THE-ROUND-TRIP-MARKER' "${BUNDLE}"
ck $? "not even a job description is readable"

# The control. Without it, "no secret found" could equally mean the export
# wrote nothing recognisable at all.
tar -tf "${BUNDLE}" >/tmp/istar.log 2>&1
[ $? -ne 0 ]
ck $? "the bundle is not a plain tar"

# -----------------------------------------------------------------------------
sect "4. the escrow copy is made"

# BGB_ESCROW_LOCAL is the copy that exists when the operator's laptop does not.
# It is the DEFAULT destination, used when --out is not given - so the export
# above, which named its own path, deliberately did not write one. Exporting
# again without --out is what a scheduled export does.
bg-backup config export --passphrase-file "${BUNDLE_PASS}" --batch \
  >/tmp/export-escrow.log 2>&1
ck $? "an export without --out exits 0"

mapfile -t ESCROWED < <(find "${ESCROW_DIR}" -maxdepth 1 -type f -size +0c | sort)
[ "${#ESCROWED[@]}" -ge 1 ]
ck $? "the escrow copy was written (${ESCROWED[*]:-none})"
! grep -aq "${BGB_IT_RESTIC_PASSWORD}" "${ESCROWED[0]:-/dev/null}"
ck $? "the escrow copy is encrypted too"

MODE="$(stat -c %a "${ESCROWED[0]:-/dev/null}" 2>/dev/null)"
case "${MODE}" in 6[04]0 | 400 | 600) ok "the escrow copy is not world-readable (${MODE})" ;;
*) bad "the escrow copy has mode ${MODE}" ;; esac

# -----------------------------------------------------------------------------
sect "5. THE ROUND TRIP - destroy the configuration and rebuild it"

# This is the claim the whole design rests on: with the card and the bundle, a
# stranger can rebuild /etc/bg-backup. Anything short of destroying it first
# proves that the import command exits 0, not that it recovers anything.
cp -a /etc/bg-backup /root/etc-backup
rm -rf /etc/bg-backup
[ ! -d /etc/bg-backup ]
ck $? "the configuration was really destroyed"

bg-backup config import --in "${BUNDLE}" --passphrase-file "${BUNDLE_PASS}" --batch --force \
  >/tmp/import.log 2>&1
ck $? "config import exits 0"

[ -f /etc/bg-backup/bg-backup.conf ]
ck $? "the main configuration is back"
[ -f /etc/bg-backup/conf.d/50-marker.conf ]
ck $? "the operator's own job is back"
grep -q 'THE-ROUND-TRIP-MARKER' /etc/bg-backup/conf.d/50-marker.conf
ck $? "with its contents intact"
[ -f /etc/bg-backup/credentials/repo.env ]
ck $? "the credentials are back"

MODE="$(stat -c %a /etc/bg-backup/credentials/repo.env 2>/dev/null)"
eq "the restored credential keeps mode 0400" "${MODE}" "400"

bg-backup config validate --strict >/tmp/validate2.log 2>&1
ck $? "the recovered configuration validates"

# And it must actually WORK, not merely parse.
bg-backup snapshots >/tmp/snap-after-import.log 2>&1
ck $? "the recovered host can reach its repository"

# -----------------------------------------------------------------------------
sect "6. add-recovery-key adds a SECOND key without removing the first"

# It GENERATES the passphrase itself and prints it once. That is the design: a
# recovery passphrase stored on the host it is meant to recover is not a
# recovery passphrase. The suite therefore reads it off the output, exactly as
# an operator would, and then proves the host does not keep a copy.
bg-backup --yes secrets add-recovery-key >/tmp/addkey.log 2>&1
ck $? "add-recovery-key exits 0"

# tail, not head: `grep | head -1` would SIGPIPE the grep under pipefail.
RECPASS="$(grep -oE '[A-Za-z0-9]{32}' /tmp/addkey.log | tail -1)"
[ -n "${RECPASS}" ]
ck $? "the recovery passphrase was printed for the operator to store"

printf '%s' "${RECPASS}" >/root/.reckey
chmod 0400 /root/.reckey

repo_opens_with /root/.reckey
ck $? "the printed recovery key really opens the repository"
repo_opens_with /root/.bgb-pass
ck $? "the ORIGINAL passphrase still works - this adds, it does not replace"

# THE PROPERTY THAT MAKES IT A RECOVERY KEY. If it were written anywhere under
# /etc/bg-backup, a host compromise would take it with everything else, and the
# second key would protect against nothing.
! grep -rqa "${RECPASS}" /etc/bg-backup/ 2>/dev/null
ck $? "the recovery passphrase is NOT stored on this host"

# -----------------------------------------------------------------------------
sect "7. rotate-repo-password really rotates"

# Like add-recovery-key, it generates the new passphrase itself and installs it
# as this host's repo.key. So the assertion is about the KEY FILE changing and
# the old value dying - not about a passphrase the test chose.
#
# AND IT RUNS AS THE PRUNE IDENTITY, which is an operational fact worth knowing:
# completing a rotation means REMOVING the old key, which deletes
# <prefix>/keys/<id>. ADR-0005 lets the backup identity delete nothing outside
# its own locks/ prefix, so a rotation run with the backup credentials adds and
# installs the new key and then reports
#     Could not remove the old key - remove it by hand
# leaving the old passphrase valid. That is the policy working, not a defect -
# but an operator who rotates after a leak and walks away has not revoked
# anything. Section 7b asserts that warning explicitly.
cp /etc/bg-backup/credentials/repo.key /tmp/oldkey
chmod 0400 /tmp/oldkey

use_identity prune
ck $? "switched to the prune identity for a complete rotation"

bg-backup --yes secrets rotate-repo-password >/tmp/rotate.log 2>&1
RC=$?
if [ "${RC}" -eq 0 ]; then
  ok "rotate-repo-password exits 0"
else
  bad "rotate-repo-password exits 0: got ${RC}"
  # Rotation is careful by design - it verifies the new key from a clean
  # environment BEFORE removing the old one - so a failure here means it
  # refused rather than half-finished. Which refusal it was is the whole
  # question, and an exit code alone does not say.
  sed 's/^/      /' /tmp/rotate.log | tail -20
fi

! cmp -s /tmp/oldkey /etc/bg-backup/credentials/repo.key
ck $? "the host's key file was replaced"

repo_opens_with /etc/bg-backup/credentials/repo.key
ck $? "the new passphrase opens the repository"

# THE POINT OF A ROTATION. If the old key still opens the repository, this was
# an add, not a rotate - and the difference only becomes visible after the old
# key has leaked, which is the one moment it must not.
! repo_opens_with /tmp/oldkey
ck $? "the OLD passphrase no longer opens the repository"

# The recovery key from section 6 must SURVIVE a rotation of the host key.
# Rotating the host passphrase and silently invalidating the off-host recovery
# key would leave the operator with one copy again, without telling them.
repo_opens_with /root/.reckey
ck $? "the recovery key still opens the repository after the rotation"

# -----------------------------------------------------------------------------
sect "7b. rotating as the BACKUP identity cannot revoke, and says so"

# The other half of the same fact. This is the case an operator hits after a
# credential leak, when they are in a hurry and least likely to read carefully.
use_identity backup
ck $? "switched back to the backup identity"

cp /etc/bg-backup/credentials/repo.key /tmp/prekey
chmod 0400 /tmp/prekey

bg-backup --yes secrets rotate-repo-password >/tmp/rotate2.log 2>&1
R2=$?

# It must still succeed at what it CAN do - a new usable key on the host.
repo_opens_with /etc/bg-backup/credentials/repo.key
ck $? "a new working passphrase was installed even so"

# And it must say, in as many words, that the old key is still valid.
grep -qi 'could not remove the old key' /tmp/rotate2.log
ck $? "it warns that the old key was NOT removed"
grep -qi 'by hand\|restic key remove' /tmp/rotate2.log
ck $? "and tells the operator how to finish the job"

# The warning must be true: the previous passphrase really does still work.
repo_opens_with /tmp/prekey
ck $? "the previous passphrase indeed still opens the repository"

# The rotation must NOT report a hard failure for work it completed. It used to
# exit 4 here, because the re-export calls die() and `|| warn` cannot catch an
# exit - so a fully successful rotation looked like a failed one, and the
# obvious response is to run it again and add another stray key.
[ "${R2}" -eq 0 ]
ck $? "a rotation that did everything it was permitted to do exits 0 (got ${R2})"

use_identity prune
ck $? "back to the prune identity"

# The host must have been updated to use the new key, or the next scheduled
# backup fails at 02:30 with nobody watching.
bg-backup snapshots >/tmp/snap-after-rotate.log 2>&1
ck $? "the host itself still works after the rotation"

# -----------------------------------------------------------------------------
sect "8. no secret reached a log"

LEAKED=0
for f in /tmp/*.log /tmp/card.txt; do
  [ -e "${f}" ] || continue
  if grep -q "${BGB_IT_RESTIC_PASSWORD}" "${f}" 2>/dev/null; then
    bad "the repository passphrase leaked into ${f}"
    LEAKED=1
    break
  fi
done
# No exception for reveal.log: --reveal refuses without a terminal, so nothing
# in this suite is allowed to contain the passphrase at all.
[ "${LEAKED}" -eq 0 ] && ok "no passphrase in any log"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
