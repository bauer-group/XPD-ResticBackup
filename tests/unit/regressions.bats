#!/usr/bin/env bats
# =============================================================================
# bg-backup - regression tests
# =============================================================================
# One test per bug that actually shipped into this codebase and was caught
# before release. Each was silent: nothing errored, and the wrong behaviour
# looked exactly like the right one.
#
# These are the tests worth having. A test that asserts a function returns what
# it obviously returns costs maintenance and buys nothing; a test that pins down
# a mistake somebody already made buys the rest of the project.
# =============================================================================

load 'helpers/load'

setup() {
  bgb_setup
  bgb_load_lib core redact json
}

teardown() {
  bgb_teardown
}

# -----------------------------------------------------------------------------
# BUG 1: json_escape ate every hyphen
# -----------------------------------------------------------------------------
# The control-character stripper was written as
#     ${s//[$'\x00'-$'\x08'...]/}
# Bash cannot hold a NUL byte in a string, so $'\x00' expanded to NOTHING and
# the bracket expression degenerated to [-\x08...] - whose LEADING literal '-'
# then matched and removed every hyphen in the input.
#
# Symptoms were nowhere near the cause: timestamps came out as "20260801T..."
# instead of "2026-08-01T...", and the tool reported its own config directory as
# /etc/bgbackup instead of /etc/bg-backup. Both look like a typo somewhere else.
@test "regression: json_escape preserves hyphens in timestamps" {
  run json_escape "2026-08-01T20:34:40Z"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-01T20:34:40Z" ]
}

@test "regression: json_escape preserves hyphens in paths" {
  run json_escape "/etc/bg-backup/conf.d/10-system.conf"
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/bg-backup/conf.d/10-system.conf" ]
}

@test "regression: json_escape still strips real control characters" {
  # The stripper must keep working - the fix narrowed the range, it did not
  # remove the behaviour. ESC (0x1b) arrives via coloured output.
  run json_escape "$(printf 'esc\033code')"
  [ "$status" -eq 0 ]
  [ "$output" = "esccode" ]
}

@test "regression: json_escape escapes quotes, backslashes and newlines" {
  run json_escape 'a"b\c'
  [ "$output" = 'a\"b\\c' ]
  run json_escape "$(printf 'line1\nline2')"
  [ "$output" = 'line1\nline2' ]
}

# -----------------------------------------------------------------------------
# BUG 2: every job shared one lock
# -----------------------------------------------------------------------------
# lock_acquire() opened with
#     local name="$1" dir="${BGB_LOCK_ROOT}/${name}.d"
# Bash evaluates EVERY right-hand side in a single `local` before ANY of the
# declarations take effect, so ${name} expanded to the outer scope's value - or,
# usually, to nothing. Every lock therefore landed in "${BGB_LOCK_ROOT}/.d", so
# the per-job lock and the repository lock were the same directory: two
# different jobs blocked each other, and a job blocked its own repository lock.
@test "regression: separate jobs get separate lock directories" {
  bgb_load_lib lock
  BGB_COMMAND="test"

  run bash -c "
    . '${BGB_LIB_DIR}/core.sh'; . '${BGB_LIB_DIR}/lock.sh'
    BGB_LOCK_ROOT='${BGB_TEST_TMP}/locks'; BGB_NO_LOCK=0; BGB_COMMAND=t
    lock_acquire alpha 0 >/dev/null 2>&1
    lock_acquire beta  0 >/dev/null 2>&1
    ls '${BGB_TEST_TMP}/locks'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.d"* ]]
  [[ "$output" == *"beta.d"*  ]]
  # The tell-tale of the bug: a lock directory named exactly ".d".
  [[ "$output" != *$'\n.d'* ]]
}

@test "regression: a second acquire of the same lock is refused" {
  run bash -c "
    . '${BGB_LIB_DIR}/core.sh'; . '${BGB_LIB_DIR}/lock.sh'
    BGB_LOCK_ROOT='${BGB_TEST_TMP}/locks2'; BGB_NO_LOCK=0; BGB_COMMAND=t
    mkdir -p '${BGB_TEST_TMP}/locks2/held.d'
    echo \$\$ > '${BGB_TEST_TMP}/locks2/held.d/pid'
    # The boot id must come from the SAME function the code uses. Writing a
    # literal here makes the lock look like it came from a previous boot, the
    # stale-reclaim path fires, and the test passes for the wrong reason on any
    # platform without /proc.
    _bgb_boot_id > '${BGB_TEST_TMP}/locks2/held.d/boot'
    echo 'other' > '${BGB_TEST_TMP}/locks2/held.d/cmd'
    lock_acquire held 0
  "
  # EX_LOCKED
  [ "$status" -eq 5 ]
}

# -----------------------------------------------------------------------------
# BUG 3: the "key whitelist" was only a prefix check
# -----------------------------------------------------------------------------
# The linter validated keys against ^(BGB_[A-Z0-9_]+|JOB_[A-Z0-9_]+|...)$, which
# accepts ANY key with the right prefix. The documented protection - "a typo like
# JOB_KEEP_DIALY is an error, not a silently disabled retention policy" - did not
# exist: the misspelled key was set, the real one kept its default, and retention
# quietly did something other than what the file said.
@test "regression: a misspelled JOB_ key is rejected, not accepted by prefix" {
  bgb_load_lib config
  run config_key_known "JOB_KEEP_DIALY"
  [ "$status" -ne 0 ]
}

@test "regression: an invented key with a valid prefix is rejected" {
  bgb_load_lib config
  run config_key_known "JOB_TOTAL_NONSENSE"
  [ "$status" -ne 0 ]
  run config_key_known "BGB_FLURB"
  [ "$status" -ne 0 ]
}

@test "regression: real configuration keys are still accepted" {
  bgb_load_lib config
  local k
  for k in JOB_KEEP_DAILY JOB_PATHS JOB_QUIESCE BGB_HOSTNAME BGB_REPO_ROLE BGB_NOTIFIERS; do
    run config_key_known "$k"
    [ "$status" -eq 0 ] || {
      echo "known key was rejected: $k"
      return 1
    }
  done
}

@test "regression: backend credential variables are accepted by prefix" {
  bgb_load_lib config
  # restic and the cloud SDKs own these namespaces; enumerating them would break
  # the day restic gains a backend.
  local k
  for k in RESTIC_REPOSITORY AWS_SECRET_ACCESS_KEY B2_ACCOUNT_KEY AZURE_ACCOUNT_KEY; do
    run config_key_known "$k"
    [ "$status" -eq 0 ]
  done
}

@test "regression: the linter suggests the intended key on a typo" {
  bgb_load_lib config
  run config_key_suggest "JOB_KEEP_DIALY"
  [ "$output" = "JOB_KEEP_DAILY" ]
}

# -----------------------------------------------------------------------------
# BUG 4: an Authorization header leaked its token
# -----------------------------------------------------------------------------
# Two redaction rules ran in the wrong order. The Authorization rule consumed
# only the first non-space token, so for
#     Authorization: Bearer abcdef1234567890
# it replaced the word "Bearer" and left the token in place. The output looked
# redacted, which is worse than obviously not being redacted.
@test "regression: Authorization: Bearer <token> loses the token" {
  run redact "Authorization: Bearer abcdef1234567890"
  [[ "$output" != *"abcdef1234567890"* ]]
}

@test "regression: a bare bearer token is redacted" {
  run redact "sent Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig to the api"
  [[ "$output" != *"eyJhbGciOiJIUzI1NiJ9"* ]]
}

@test "regression: credentials embedded in a repository URL are redacted" {
  # The point of the structural layer: this secret was never registered.
  run redact "s3:https://AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMIK7MDENGbPxRfiCY@minio.local/b"
  [[ "$output" != *"wJalrXUtnFEMIK7MDENGbPxRfiCY"* ]]
}

@test "regression: an Uptime Kuma push token is redacted" {
  run redact "https://kuma.example.com/api/push/AbCdEf123456?status=up&msg=ok"
  [[ "$output" != *"AbCdEf123456"* ]]
}

# -----------------------------------------------------------------------------
# BUG 7: restic_count_errors counted LINES, not records
# -----------------------------------------------------------------------------
# It was `jq -r 'select(...)' | grep -c '^'`, and jq pretty-prints each record
# across several lines. Two unreadable files were reported as sixteen.
#
# That number is not cosmetic: it is what an operator looks at to decide whether
# an exit 3 is the usual rotating-log noise or something that needs attention,
# and it is exported as bg_backup_files_unreadable.
@test "regression: restic_count_errors counts records, not pretty-printed lines" {
  bgb_skip_without jq
  local f="${BGB_TEST_TMP}/errors.jsonl"
  cat >"${f}" <<'JSONL'
{"message_type":"error","error":{"message":"permission denied"},"during":"archival","item":"/srv/a"}
{"message_type":"status","percent_done":0.5,"files_done":10}
{"message_type":"error","error":{"message":"permission denied"},"during":"archival","item":"/srv/b"}
{"message_type":"summary","files_new":1,"snapshot_id":"abc"}
JSONL
  run restic_count_errors "${f}"
  [ "$output" = "2" ]
}

@test "regression: restic_count_errors is 0 for a clean run and a missing file" {
  bgb_skip_without jq
  local f="${BGB_TEST_TMP}/clean.jsonl"
  printf '%s\n' '{"message_type":"summary","files_new":3,"snapshot_id":"abc"}' >"${f}"
  run restic_count_errors "${f}"
  [ "$output" = "0" ]

  run restic_count_errors "${BGB_TEST_TMP}/does-not-exist.jsonl"
  [ "$output" = "0" ]
}

# -----------------------------------------------------------------------------
# BUG 8: the shipped example configuration failed our own linter
# -----------------------------------------------------------------------------
# The command-substitution check inspected the whole line, comment included, so
#     JOB_VERIFY_SAMPLE=5   # files restored and hashed by `verify`
# was rejected for the backticks in its COMMENT. A fresh install seeds exactly
# that file, so `bg-backup config validate` failed on a untouched installation.
@test "regression: every shipped example configuration lints clean" {
  bgb_load_lib config
  local f
  for f in "${BGB_SHARE_DIR}"/config/*.example "${BGB_SHARE_DIR}"/config/conf.d/*.example; do
    [ -e "${f}" ] || continue
    run config_lint "${f}"
    [ "$status" -eq 0 ] || {
      echo "shipped example failed to lint: ${f}"
      echo "${output}"
      return 1
    }
  done
}

@test "regression: backticks in a comment are allowed, in a value are not" {
  bgb_load_lib config
  local ok="${BGB_TEST_TMP}/ok.conf" bad="${BGB_TEST_TMP}/bad.conf"

  printf '%s\n' 'JOB_ENABLED=1   # documented in `verify`' >"${ok}"
  run config_lint "${ok}"
  [ "$status" -eq 0 ]

  printf '%s\n' 'JOB_DESCRIPTION="x`id`y"' >"${bad}"
  run config_lint "${bad}"
  [ "$status" -ne 0 ]

  # A '#' inside quotes is part of the value, not the start of a comment, and
  # must not be used to smuggle a substitution past the check.
  printf '%s\n' 'JOB_DESCRIPTION="a # b `id`"' >"${bad}"
  run config_lint "${bad}"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# BUG 6: the redaction prefilter skipped whole pattern classes
# -----------------------------------------------------------------------------
# redact() guards its sed with a cheap `case` so it does not fork on every
# message. That guard has to be a SUPERSET of what the sed can match, and it was
# not: it tested for "password" but not "passphrase", and had no entry at all
# for "bearer", a lone AKIA key, or "sig=".
#
# The result was a redactor that worked in every example anyone tried - because
# examples tend to contain the word "token" or a URL - and silently passed a
# bare `Bearer <jwt>` straight through.
#
# One case per pattern class, each with NO other trigger word in the string.
@test "regression: every redaction pattern fires without a helper trigger word" {
  local -a cases=(
    "sent Bearer eyJhbGciOiJIUzI1NiJ9.abc.def onwards|eyJhbGciOiJIUzI1NiJ9"
    "passphrase=hunter2hunter2hunter2 done|hunter2hunter2hunter2"
    "using AKIAIOSFODNN7EXAMPLE now|AKIAIOSFODNN7EXAMPLE"
    "call ?sig=abcdef1234567890 end|abcdef1234567890"
    "api_key=zzzzzzzzzzzzzzzz end|zzzzzzzzzzzzzzzz"
  )
  local c input needle out
  for c in "${cases[@]}"; do
    input="${c%%|*}"
    needle="${c##*|}"
    out="$(redact "${input}")"
    if [[ "${out}" == *"${needle}"* ]]; then
      echo "NOT redacted: ${input}"
      echo "         got: ${out}"
      return 1
    fi
  done
}

@test "regression: harmless text survives redaction unchanged" {
  # A redactor that mangles ordinary output makes logs useless and gets turned
  # off, which is the real failure mode.
  local msg="job docker finished ok in 0h 04m 12s, /etc/bg-backup, 2026-08-02"
  run redact "$msg"
  [ "$output" = "$msg" ]
}

# -----------------------------------------------------------------------------
# BUG 5: job defaults depended on load order
# -----------------------------------------------------------------------------
# job_defaults_reset() referenced ${BGB_DEFAULT_ONE_FILE_SYSTEM} without a
# fallback, so calling it before config_defaults() aborted under `set -u` with
# "unbound variable" - a failure whose message points at the wrong file.
@test "regression: job_defaults_reset works without config_defaults having run" {
  run bash -c "
    set -u
    . '${BGB_LIB_DIR}/core.sh'
    . '${BGB_LIB_DIR}/config.sh'
    job_defaults_reset
    echo \"\${JOB_ONE_FILE_SYSTEM}:\${JOB_EXCLUDE_CACHES}:\${JOB_ALERT_MAX_AGE_HOURS}\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "1:1:30" ]
}
