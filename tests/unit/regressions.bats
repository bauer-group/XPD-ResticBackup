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

# -----------------------------------------------------------------------------
# BUG 9: every restore subcommand died silently under `set -e`
# -----------------------------------------------------------------------------
# restore_parse_common() ended on an && chain:
#     [ -z "${R_JOB}" ] && [ "${#BGB_JOB_FILTER[@]}" -gt 0 ] && R_JOB=...
# The status of a function's last command IS its return value, and that chain is
# false whenever --job is given (first test fails) OR no global filter is set
# (second test fails) - which is every real invocation. All five callers run it
# as a plain statement under `set -euo pipefail`, so the process exited 1 before
# printing anything at all. `restore file|dir|volume|project|db|system` were
# therefore ALL dead, and the silence is why unit tests and shellcheck missed it.
# Only an end-to-end run against a real repository surfaced it.
@test "regression: restore_parse_common returns 0 with no --job and no filter" {
  bgb_load_lib config restic restore
  BGB_JOB_FILTER=()
  run restore_parse_common --path /srv/data --to /tmp/x
  [ "$status" -eq 0 ]
}

@test "regression: restore_parse_common returns 0 when --job IS given" {
  bgb_load_lib config restic restore
  BGB_JOB_FILTER=()
  run restore_parse_common --job docker --path /srv/data
  [ "$status" -eq 0 ]
}

@test "regression: a restore entry point survives set -e up to its own checks" {
  # The end-to-end shape of the bug: under `set -e`, reaching ANY diagnostic at
  # all was the thing that failed. Exit 2 (usage) proves the parser returned.
  bgb_load_lib config restic restore
  run bash -c "
    set -euo pipefail
    BGB_LIB_DIR='${BGB_LIB_DIR}'
    . '${BGB_LIB_DIR}/core.sh'; . '${BGB_LIB_DIR}/redact.sh'
    . '${BGB_LIB_DIR}/json.sh'; . '${BGB_LIB_DIR}/config.sh'
    . '${BGB_LIB_DIR}/restic.sh'; . '${BGB_LIB_DIR}/restore.sh'
    BGB_JOB_FILTER=()
    usage_restore() { :; }
    restore_path_cmd dir --to /tmp/x
  "
  # --path is missing, so it must be a USAGE error - not a bare, silent 1.
  [ "$status" -eq 2 ]
  [[ "$output" == *"--path"* ]]
}

@test "regression: config_key_suggest returns 0 when nothing is similar" {
  # Same class. The caller does hint=\"\$(config_key_suggest ...)\", so a
  # non-zero return aborted config_lint under `set -e` at precisely the moment
  # it had an unknown key to report - and the key was never printed.
  bgb_load_lib config
  run bash -c "
    set -euo pipefail
    . '${BGB_LIB_DIR}/core.sh'; . '${BGB_LIB_DIR}/config.sh'
    hint=\"\$(config_key_suggest ZZZ_NOTHING_LIKE_THIS)\"
    echo \"ok:[\${hint}]\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok:[]" ]
}

# -----------------------------------------------------------------------------
# BUG 10: repeated --tag is OR, so selectors matched the wrong snapshot
# -----------------------------------------------------------------------------
# restic's --tag is an OR over comma-separated tag LISTS. Measured against
# restic 0.19.1 in the rig, on a snapshot tagged job=e2e but not kind=files:
#     --tag job=e2e --tag kind=files  -> 1 hit   (OR)
#     --tag job=e2e,kind=files        -> 0 hits  (AND)
# Every selector here means AND. The OR form does not fail - it silently returns
# a DIFFERENT snapshot, and `dr` would then `docker load` the wrong image or a
# restore would write the wrong bytes over a live directory.
@test "regression: a tag filter is one comma-joined --tag, not several" {
  bgb_load_lib restic
  local -a a=()
  mapfile -t a < <(restic_tag_filter_args "job=docker" "kind=files")
  [ "${#a[@]}" -eq 2 ]
  [ "${a[0]}" = "--tag" ]
  [ "${a[1]}" = "job=docker,kind=files" ]
}

@test "regression: empty tag terms are dropped, not emitted as commas" {
  bgb_load_lib restic
  local -a a=()
  mapfile -t a < <(restic_tag_filter_args "job=docker" "" "kind=files")
  [ "${a[1]}" = "job=docker,kind=files" ]

  mapfile -t a < <(restic_tag_filter_args "" "" "")
  [ "${#a[@]}" -eq 0 ]
}

@test "regression: restore selectors emit a single AND filter" {
  bgb_load_lib config restic restore
  BGB_HOSTNAME="h.example.invalid"
  local -a a=()
  mapfile -t a < <(restic_tag_filter_args "job=docker" "run=R1" "kind=files")
  [ "${#a[@]}" -eq 2 ]
  [ "${a[1]}" = "job=docker,run=R1,kind=files" ]
}

# -----------------------------------------------------------------------------
# BUG 11: a files-mode snapshot carried no kind= tag
# -----------------------------------------------------------------------------
# restore, `runs diff`, the DR planner and the PRINTED RECOVERY SHEET all select
# on kind=files, and lib/docker.sh already tagged its file snapshot that way -
# but restic_build_backup_args() did not. A JOB_MODE=files snapshot was written
# correctly and could never be selected by name again. The recovery sheet
# instructed operators to use a tag that did not exist.
@test "regression: a files-mode backup is tagged kind=files" {
  bgb_load_lib config restic
  config_defaults
  job_defaults_reset
  BGB_HOSTNAME="h.example.invalid"
  JOB_PATHS=(/srv/data)

  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args files R1)
  bgb_argv_has_pair --tag "kind=files" "${argv[@]}"
}

# -----------------------------------------------------------------------------
# BUG 12: the dispatcher sourced a module that was never written
# -----------------------------------------------------------------------------
# `bg-backup dr` ran `lib_source facts.sh`, and lib/facts.sh does not exist:
# fact COLLECTION is the standalone hook share/hooks/collect-system-facts.sh and
# CONSUMPTION is dr.sh reading BGB_FACTS_DIR directly. Every `bg-backup dr`
# subcommand therefore aborted on its first line - including `dr bootstrap`,
# which is the first command a recovered host runs, so disaster recovery could
# not start at all. bash reported only
#     lib/core.sh: line 356: lib/facts.sh: No such file or directory
# naming neither the command nor the fact that it had died.
#
# This is a static check: it needs no repository, no container and no restic,
# and it would have caught the bug at `make test-unit`.
@test "regression: every module the dispatcher sources actually exists" {
  local root missing=""
  root="$(cd "${BGB_LIB_DIR}/.." && pwd)"
  local m
  while read -r m; do
    [ -n "${m}" ] || continue
    [ -r "${root}/lib/${m}" ] || missing="${missing} ${m}"
  done < <(grep -ohE 'lib_source [a-z_]+\.sh' "${root}/bin/bg-backup.sh" "${root}"/lib/*.sh \
           | awk '{print $2}' | sort -u)
  [ -z "${missing}" ] || {
    echo "modules sourced but absent from lib/:${missing}"
    false
  }
}

@test "regression: lib_source names the missing module instead of dying bare" {
  bgb_load_lib core
  run bash -c "
    set -uo pipefail
    BGB_LIB_DIR='${BGB_LIB_DIR}'
    . '${BGB_LIB_DIR}/core.sh'
    BGB_COMMAND=dr
    lib_source definitely_not_a_module.sh
  "
  [ "$status" -eq 4 ]
  [[ "$output" == *"definitely_not_a_module.sh"* ]]
  [[ "$output" == *"Installation incomplete"* ]]
}

# -----------------------------------------------------------------------------
# BUG 13: restore materialised sparse files
# -----------------------------------------------------------------------------
# restic writes holes as real zero blocks unless told otherwise. The DR
# rehearsal's 1 GiB sparse file came back apparent 1073741824 / actual
# 1073745920 - fully allocated. On a recovery host a sparse VM image or database
# can then exhaust the disk during the restore that is supposed to save you.
# --sparse is injected centrally because there are eight restore call sites.
@test "regression: a restore argv gets --sparse" {
  bgb_load_lib restic
  local -a argv=(restore abc123 --target /tmp/x --include /srv)
  _restic_restore_defaults argv
  local joined="${argv[*]}"
  [[ "${joined}" == *"--sparse"* ]]
}

@test "regression: --sparse is not added twice" {
  bgb_load_lib restic
  local -a argv=(restore abc123 --sparse --target /tmp/x)
  _restic_restore_defaults argv
  local n=0 x
  for x in "${argv[@]}"; do [ "${x}" = "--sparse" ] && n=$(( n + 1 )); done
  [ "${n}" -eq 1 ]
}

@test "regression: --sparse is added ONLY to restore, not to other commands" {
  # backup, forget and check reject it, so a blanket injection would break
  # every other command instead.
  bgb_load_lib restic
  local -a argv=(backup --host h /srv)
  _restic_restore_defaults argv
  [[ "${argv[*]}" != *"--sparse"* ]]

  local -a argv2=(forget --host h --keep-daily 7)
  _restic_restore_defaults argv2
  [[ "${argv2[*]}" != *"--sparse"* ]]
}

# -----------------------------------------------------------------------------
# BUG 14: a secret containing a glob metacharacter was never redacted
# -----------------------------------------------------------------------------
# Layer 1 of redact() used ${s//${secret}/...}, where the needle is a GLOB
# PATTERN, not literal text. A passphrase containing a bracket expression is
# therefore not found and goes into the log, the notifier payload and the
# doctor output in full. Measured: `pw[0-9]x` passed through untouched.
@test "regression: a secret with a bracket expression is still redacted" {
  bgb_load_lib redact
  redact_register 'pw[0-9]x'
  run redact "repo password is pw[0-9]x here"
  [[ "$output" != *"pw[0-9]x"* ]]
  [[ "$output" == *"${BGB_REDACTED}"* ]]
}

@test "regression: a secret with a star does not over-redact the whole line" {
  bgb_load_lib redact
  # At least 8 characters, or redact_register() drops it by design and the test
  # would pass without ever exercising anything.
  redact_register 'key*value123'
  run redact "before key*value123 after"
  [[ "$output" != *"key*value123"* ]]
  # As a glob, key*value123 would have swallowed everything from "key" onwards.
  [[ "$output" == *"before"* ]]
  [[ "$output" == *"after"* ]]
}

@test "regression: str_replace_all treats both sides literally" {
  bgb_load_lib core
  run str_replace_all "a [x] b [x] c" "[x]" "Q"
  [ "$output" = "a Q b Q c" ]

  # The replacement must NOT be backslash-processed: a four-backslash run has to
  # come out as four backslashes, not two.
  run str_replace_all "pre|MARK|post" "MARK" 's/\\/\\\\/g'
  [ "$output" = 'pre|s/\\/\\\\/g|post' ]

  # Absent needle, empty needle and empty haystack must all be safe.
  run str_replace_all "unchanged" "zzz" "Q"; [ "$output" = "unchanged" ]
  run str_replace_all "unchanged" "" "Q";    [ "$output" = "unchanged" ]
  run str_replace_all "" "x" "Q";            [ "$output" = "" ]
}

# -----------------------------------------------------------------------------
# BUG 15: splicing shell code through ${x//m/r} halved every backslash
# -----------------------------------------------------------------------------
# The credential preamble spliced into the MySQL/MariaDB dump script contains
#     sed 's/\/\\/g; s/"/\\"/g'
# and arrived in the container as
#     sed 's/\/\/g; s/"/\"/g'
# because bash processes backslashes in a substitution's REPLACEMENT. sed then
# refused the expression and EVERY MySQL and MariaDB dump failed - visible only
# from inside the container.
@test "regression: the db credential preamble survives splicing intact" {
  bgb_load_lib core
  # shellcheck disable=SC1090
  . "${BGB_LIB_DIR}/../share/db/mysql.sh"
  local out
  out="$(_db_mysql_script '__CREDS__')"

  # grep -F, not [[ == pattern ]]: the string under test is made of backslashes
  # and slashes, which is precisely the input that makes glob patterns and shell
  # quoting unreadable. -F compares bytes.
  printf '%s' "${out}" | grep -qF 's/\\/\\\\/g'
  printf '%s' "${out}" | grep -qF 's/"/\\"/g'

  # And the corrupted, backslash-halved form must NOT appear.
  ! printf '%s' "${out}" | grep -qF 's/\/\\/g'
}

# -----------------------------------------------------------------------------
# BUG 16: every notifier was dead - loaded inside a command substitution
# -----------------------------------------------------------------------------
# monitor_load_notifier() sources lib/notify/<name>.sh, which is a SIDE EFFECT
# on the current shell. It was called as fn="$(monitor_load_notifier x)", so the
# sourcing happened in a subshell: `declare -F` succeeded there, the name was
# printed, and the definition died with the subshell. The parent then called a
# name it had never seen:
#     monitor.sh: line 501: bgb_notify_prometheus: command not found
# No e-mail, no Teams card, no Kuma push, no metrics - ever.
@test "regression: loading a notifier defines it in THIS shell" {
  bgb_load_lib core config monitor
  ! declare -F bgb_notify_prometheus >/dev/null 2>&1

  monitor_load_notifier prometheus
  [ "$?" -eq 0 ]
  declare -F bgb_notify_prometheus >/dev/null 2>&1
  [ "${_BGB_NOTIFY_FN}" = "bgb_notify_prometheus" ]
}

@test "regression: a hyphenated notifier name maps to an underscored function" {
  bgb_load_lib core config monitor
  monitor_load_notifier uptime-kuma
  [ "$?" -eq 0 ]
  [ "${_BGB_NOTIFY_FN}" = "bgb_notify_uptime_kuma" ]
  declare -F bgb_notify_uptime_kuma >/dev/null 2>&1
}

@test "regression: every shipped notifier actually loads" {
  # One file whose function name does not match its file name would silence that
  # channel permanently, and nothing else would ever say so.
  bgb_load_lib core config monitor
  local f name
  for f in "${BGB_LIB_DIR}"/notify/*.sh; do
    name="$(basename "${f}" .sh)"
    monitor_load_notifier "${name}" || {
      echo "notifier ${name} did not load"
      false
    }
  done
}

# -----------------------------------------------------------------------------
# BUG 17: metrics_write_job / _check / _verify were never defined
# -----------------------------------------------------------------------------
# backup.sh and verify.sh called three functions that do not exist, each behind
# `|| true`, so the only symptom was a "command not found" nobody reads - and
# the Prometheus textfile was never written by any job. Same class as the
# dispatcher sourcing lib/facts.sh.
#
# This is the general check: every function this codebase calls must exist.
@test "regression: no lib function is called but never defined" {
  local root; root="$(cd "${BGB_LIB_DIR}/.." && pwd)"
  local files defs calls guarded missing=""
  files="$(cd "${root}" && git ls-files '*.sh' | grep -v '^tests/helper/')"

  defs="$(cd "${root}" && grep -hoE '^[[:space:]]*(function[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' ${files} \
          | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)//' | sort -u)"

  # `declare -F name` is this codebase's idiom for OPTIONAL dispatch - a call
  # site that deliberately works whether or not the function exists, with a
  # fallback (see internal.sh and quiesce_replay_state). Probing for a name is
  # an explicit statement that its absence is expected, so it is not a defect.
  guarded="$(cd "${root}" && grep -hoE 'declare -F [a-zA-Z_][a-zA-Z0-9_]*' ${files} \
             | awk '{print $3}' | sort -u)"

  local prefix='bgb|core|config|lock|json|redact|restic|state|usage|backup|restore|quiesce|docker|db|facts|retention|verify|secrets|dr|discover|doctor|monitor|systemd|selfupdate|metrics|query|internal|status|init|str'

  # Only the FIRST token of a line, and only when that line actually starts a
  # command. Both restrictions are load-bearing:
  #   * extracting every matching token on the line turned arguments into
  #     "calls" - `json_kv config_dir "..."` reported config_dir as undefined;
  #   * a line whose predecessor ends in a backslash is a CONTINUATION, not a
  #     command. The metric-name lists in metrics.sh are exactly that shape.
  calls="$(cd "${root}" && awk -v pre="^[[:space:]]*(${prefix})_[a-z0-9_]+([[:space:]]|\$)" '
      FNR == 1 { cont = 0 }
      {
        if (!cont && $0 ~ pre && $0 !~ /declare -F/) {
          line = $0
          sub(/^[[:space:]]+/, "", line)
          sub(/[^a-zA-Z0-9_].*$/, "", line)
          print line
        }
        cont = ($0 ~ /\\[[:space:]]*$/)
      }' ${files} | sort -u)"

  local c
  for c in ${calls}; do
    printf '%s\n' "${defs}"    | grep -qx "${c}" && continue
    printf '%s\n' "${guarded}" | grep -qx "${c}" && continue
    missing="${missing} ${c}"
  done
  [ -z "${missing}" ] || { echo "called but never defined:${missing}"; false; }
}

@test "regression: restic exit 130 and 143 have a human explanation" {
  bgb_load_lib restic
  run restic_explain_rc 130
  [[ "$output" != *"unknown restic exit code"* ]]
  run restic_explain_rc 143
  [[ "$output" != *"unknown restic exit code"* ]]
}
