#!/usr/bin/env bash
# =============================================================================
# e2e: does an alert actually leave the host?
# =============================================================================
# The notification channels were the largest untested surface after systemd.sh.
# The unit suite proved that each provider FILE loads and that its function name
# matches - which is worth having, because a mismatch silences a channel
# permanently - but nothing ever showed that a delivery reaches anything.
#
# That is the wrong thing to leave untested in a backup tool. Every other defect
# produces a wrong or missing backup that someone eventually notices; a dead
# notifier produces SILENCE, which is indistinguishable from success. The one
# bug this codebase already had here proves the point: every notifier was loaded
# inside a command substitution, so the function died with the subshell and the
# parent called a name it had never seen. No e-mail, no Teams card, no Kuma
# push, ever - and the only symptom was a "command not found" nobody reads.
#
# The rig runs a throwaway HTTP receiver (tests/rig/webhook-sink.py). The three
# HTTP channels are pointed at it and the recording is read back from
# /_requests. Prometheus is not an HTTP channel - it writes a textfile - so it
# is asserted on disk in section 5.
#
# WHAT IS NOT COVERED: e-mail. It needs a local MTA, the victim image has none,
# and installing one would test Postfix rather than bg-backup. Section 6
# asserts the honest thing instead - that a configured but undeliverable
# channel does not take the run down with it.
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
SINK="${BGB_IT_SINK}"
METRICS=/var/lib/node_exporter/textfile_collector/bg-backup.prom

export AWS_ACCESS_KEY_ID="${BGB_IT_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${BGB_IT_SECRET_KEY}"
export AWS_DEFAULT_REGION="${BGB_IT_REGION}"

sink_reset() { curl -sS "${SINK}/_reset" >/dev/null; }
sink_dump() { curl -sS "${SINK}/_requests"; }
# Requests recorded against one path prefix, as compact JSON lines.
sink_for() { sink_dump | jq -c --arg p "$1" 'select(.path | startswith($p))'; }
sink_count() { sink_for "$1" | grep -c . || true; }

# The generic webhook receives EVERY event, including the "start" one, so a
# request must be selected by event rather than by position. Picking head -1
# silently reads the start notification - which always carries rc=0 - and turns
# "the failure was reported" into an assertion that can never fail correctly.
hook_event() {
  sink_for /hook/generic \
    | jq -c --arg e "$1" 'select((.body | fromjson | .event) == $e)' | head -1
}
# The TERMINAL event, whatever it is called. Matching a literal "failure" would
# make this suite assert the tool's vocabulary rather than its behaviour, and
# renaming an event is not the defect worth catching here.
hook_terminal() {
  sink_for /hook/generic \
    | jq -c 'select((.body | fromjson | .event) != "start")' | tail -1
}
hook_body() { hook_event "$1" | jq -r '.body'; }

# -----------------------------------------------------------------------------
sect "0. A host wired to every channel the rig can receive"

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

curl -sS "${SINK}/_requests" >/dev/null 2>&1
ck $? "the notification sink is reachable"

# Distinct paths per channel so the assertions cannot confuse one for another.
cat >>/etc/bg-backup/bg-backup.conf <<EOF

# --- injected by tests/e2e/notify.sh -----------------------------------------
BGB_NOTIFIERS="webhook teams uptime-kuma prometheus"
BGB_MONITOR_ON="always"
BGB_MONITOR_WEBHOOK_URL="${SINK}/hook/generic"
BGB_MONITOR_TEAMS_WEBHOOK_URL="${SINK}/hook/teams"
BGB_MONITOR_KUMA_PUSH_URL="${SINK}/hook/kuma"
BGB_METRICS_TEXTFILE="${METRICS}"
EOF

# metrics.sh REFUSES to create this directory and warns instead - correct
# behaviour, because inventing a collector directory that no exporter reads
# would be silent self-deception. On a real host node_exporter owns it, so the
# rig has to provide it.
install -d -m 0755 "$(dirname "${METRICS}")"

install -d /srv/notify
echo payload >/srv/notify/f
cat >/etc/bg-backup/conf.d/50-ntf.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="files"
JOB_PATHS=( /srv/notify )
JOB_ONE_FILE_SYSTEM=0
JOB_EXCLUDE_FILE=""
JOB_KEEP_LAST="5"
JOB_FORGET_AFTER_BACKUP=0
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/50-ntf.conf

bg-backup config validate --strict >/tmp/validate.log 2>&1
ck $? "the notifier configuration is valid"

# -----------------------------------------------------------------------------
sect "1. a successful backup notifies every configured channel"

sink_reset
bg-backup backup ntf >/tmp/backup-ok.log 2>&1
ck $? "the backup succeeds"

# The generic webhook is the escape hatch and receives EVERY event, start
# included. The human-facing channels receive only terminal ones - a Kuma push
# of status=up at the START of a backup would report a run healthy before it has
# done anything, and a Teams card per start is how a channel gets muted.
[ "$(sink_count /hook/generic)" -ge 2 ]
ck $? "the generic webhook received the start and the outcome ($(sink_count /hook/generic))"
[ -n "$(hook_event start)" ]
ck $? "a start event was delivered"
[ -n "$(hook_event success)" ]
ck $? "a success event was delivered"

eq "Teams received only the outcome" "$(sink_count /hook/teams)" "1"
eq "Uptime Kuma received only the outcome" "$(sink_count /hook/kuma)" "1"

# -----------------------------------------------------------------------------
sect "2. the webhook payload is the documented envelope"

HOOK="$(hook_event success)"
[ -n "${HOOK}" ]
ck $? "the webhook request was recorded"

printf '%s' "${HOOK}" | jq -e '.method == "POST"' >/dev/null
ck $? "it is a POST"
printf '%s' "${HOOK}" | jq -e '.headers["content-type"] | test("application/json")' >/dev/null
ck $? "it declares application/json"

# The body must be JSON, not a string that looks like it.
BODY="$(printf '%s' "${HOOK}" | jq -r '.body')"
printf '%s' "${BODY}" | jq -e . >/dev/null 2>&1
ck $? "the body parses as JSON"

for field in event host job rc run_id repo; do
  if printf '%s' "${BODY}" | jq -e --arg f "${field}" 'has($f)' >/dev/null 2>&1; then
    ok "the payload carries '${field}'"
  else
    bad "the payload is missing '${field}'"
  fi
done

eq "the job name is the one that ran" \
  "$(printf '%s' "${BODY}" | jq -r '.job')" "ntf"
eq "a successful run reports rc 0" \
  "$(printf '%s' "${BODY}" | jq -r '.rc')" "0"

# The routing headers, which are how a receiver filters without parsing.
printf '%s' "${HOOK}" | jq -e '.headers["x-bg-backup-job"] == "ntf"' >/dev/null
ck $? "the job travels in a header too"

# -----------------------------------------------------------------------------
sect "3. NO SECRET IS DELIVERED"

# The single most damaging thing this tool could do to a customer: post their
# repository passphrase or S3 secret to a webhook endpoint. Checked against the
# ENTIRE recording, every channel, headers included - a redaction that only
# covers the body is not a redaction.
ALL="$(sink_dump)"
if printf '%s' "${ALL}" | grep -q "${BGB_IT_RESTIC_PASSWORD}"; then
  bad "the repository passphrase was delivered to a webhook"
elif printf '%s' "${ALL}" | grep -q "${BGB_IT_SECRET_KEY}"; then
  bad "the S3 secret was delivered to a webhook"
else
  ok "no passphrase and no backend secret in any delivered request"
fi

# The repository URL is reported on purpose - an operator needs to know WHICH
# repository - so it must be present but carry no embedded credentials.
REPO_FIELD="$(printf '%s' "${BODY}" | jq -r '.repo // ""')"
[ -n "${REPO_FIELD}" ]
ck $? "the payload names the repository"
case "${REPO_FIELD}" in
  *"${BGB_IT_SECRET_KEY}"* | *':'*'@'*) bad "the repository field embeds a credential" ;;
  *) ok "the repository field carries no credential" ;;
esac

# -----------------------------------------------------------------------------
sect "4. Teams and Kuma speak their own protocols"

TEAMS="$(sink_for /hook/teams | head -1)"
TBODY="$(printf '%s' "${TEAMS}" | jq -r '.body')"
printf '%s' "${TBODY}" | jq -e . >/dev/null 2>&1
ck $? "the Teams body parses as JSON"
printf '%s' "${TBODY}" | grep -qi 'adaptive\|attachments\|MessageCard'
ck $? "it is a card payload rather than the generic envelope"
printf '%s' "${TBODY}" | grep -q 'ntf'
ck $? "the card names the job"

# Kuma is a GET with a query string - `curl -G`, so status and msg must be in
# the query, not the body.
KUMA="$(sink_for /hook/kuma | head -1)"
eq "Kuma is pushed with GET" "$(printf '%s' "${KUMA}" | jq -r '.method')" "GET"
printf '%s' "${KUMA}" | jq -r '.query' | grep -q 'status=up'
ck $? "a successful run pushes status=up"
printf '%s' "${KUMA}" | jq -r '.query' | grep -q 'msg='
ck $? "the push carries a human message"

# -----------------------------------------------------------------------------
sect "5. the Prometheus textfile is written and parseable"

# This is what the old installer assertion CLAIMED to check. It was wrapped in
# `if [ -n "${BGB_METRICS_TEXTFILE:-}" ] || [ -d ... ]`, neither of which was
# ever true in the rig, so it always took the else branch and reported PASS
# without looking at anything.
[ -s "${METRICS}" ]
ck $? "the textfile exists and is not empty"

for m in bg_backup_run_exit_code bg_backup_bytes_added bg_backup_files_unreadable; do
  if grep -q "^${m}" "${METRICS}"; then
    ok "${m} is exported"
  else
    bad "${m} is missing from the textfile"
  fi
done

# node_exporter rejects a file without HELP/TYPE, silently, and the metric
# simply never appears in Prometheus.
grep -q '^# HELP bg_backup_' "${METRICS}"
ck $? "the metrics carry HELP lines"
grep -q '^# TYPE bg_backup_' "${METRICS}"
ck $? "the metrics carry TYPE lines"

# Every sample line must end in a number. A label value containing an unescaped
# quote produces a file node_exporter drops whole.
BADLINE="$(grep -E '^bg_backup_' "${METRICS}" | grep -vE '[[:space:]]-?[0-9.eE+]+$' | head -1)"
[ -z "${BADLINE}" ]
ck $? "every sample line ends in a value${BADLINE:+ (offender: ${BADLINE})}"

! grep -q "${BGB_IT_SECRET_KEY}" "${METRICS}"
ck $? "no backend secret in the metrics file"

# -----------------------------------------------------------------------------
sect "6. a FAILING run alerts, and a dead channel does not take the run down"

sink_reset

# A dump command that emits bytes and then fails - the job fails, which is what
# must produce the alert.
cat >/usr/local/bin/bgb-fail <<'EOS'
#!/bin/sh
printf %s PARTIAL
exit 1
EOS
chmod 0755 /usr/local/bin/bgb-fail

cat >/etc/bg-backup/conf.d/60-fail.conf <<'CONF'
JOB_ENABLED=1
JOB_MODE="stdin"
JOB_STDIN_COMMAND=( /usr/local/bin/bgb-fail )
JOB_STDIN_FILENAME="/db/fail.sql"
JOB_KEEP_LAST="5"
JOB_QUIESCE="none"
JOB_PRE_HOOKS=()
CONF
chmod 0640 /etc/bg-backup/conf.d/60-fail.conf

bg-backup backup fail >/tmp/backup-fail.log 2>&1
RC=$?
[ "${RC}" -ne 0 ]
ck $? "the failing job fails (exit ${RC})"

# By event, not by position: the start notification is also in there and it
# always carries rc=0.
FBODY="$(hook_terminal | jq -r '.body')"
[ -n "${FBODY}" ]
ck $? "a terminal event reached the webhook"

[ "$(printf '%s' "${FBODY}" | jq -r '.rc')" != "0" ]
ck $? "the payload reports a non-zero exit code"
printf '%s' "${FBODY}" | jq -e '.severity != "info" or .status != "ok"' >/dev/null
ck $? "the payload is not marked as a success"

printf '%s' "$(sink_for /hook/kuma | head -1)" | jq -r '.query' | grep -q 'status=down'
ck $? "Kuma is pushed status=down on failure"

# A channel pointing nowhere must not change the outcome of the run. This is
# what makes it safe to configure alerting at all.
sink_reset
sed -i "s|^BGB_MONITOR_WEBHOOK_URL=.*|BGB_MONITOR_WEBHOOK_URL=\"http://sink.invalid:9/dead\"|" \
  /etc/bg-backup/bg-backup.conf

bg-backup backup ntf >/tmp/backup-deadhook.log 2>&1
RC=$?
eq "an unreachable webhook does not fail the backup" "${RC}" "0"

eq "the other channels still delivered" "$(sink_count /hook/teams)" "1"

# And the failure has to be visible somewhere, or a broken alerting setup stays
# broken silently - which is the same failure mode as no alerting at all.
grep -qiE 'notif|webhook|deliver' /tmp/backup-deadhook.log
ck $? "the delivery failure is reported in the run log"

# -----------------------------------------------------------------------------
sect "7. BGB_MONITOR_ON=never really means never"

# The control. Without it, a sink that recorded requests from some earlier
# section would let every assertion above pass by accident.
sed -i 's|^BGB_MONITOR_ON=.*|BGB_MONITOR_ON="never"|' /etc/bg-backup/bg-backup.conf
sed -i "s|^BGB_MONITOR_WEBHOOK_URL=.*|BGB_MONITOR_WEBHOOK_URL=\"${SINK}/hook/generic\"|" \
  /etc/bg-backup/bg-backup.conf
sink_reset

bg-backup backup ntf >/tmp/backup-quiet.log 2>&1
ck $? "the backup still succeeds with notifications off"

eq "the webhook received nothing" "$(sink_count /hook/generic)" "0"
eq "Teams received nothing" "$(sink_count /hook/teams)" "0"

# Prometheus is deliberately NOT gated by BGB_MONITOR_ON - it is a state file,
# not an alert, and gating it would leave the exporter serving a stale exit code
# for as long as backups keep succeeding.
[ -s "${METRICS}" ]
ck $? "the metrics file is still maintained when alerting is off"

# -----------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
