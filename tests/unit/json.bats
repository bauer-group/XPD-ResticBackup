# =============================================================================
# bg-backup - unit: JSON emission (ours) and JSON parsing (everyone else's)
# =============================================================================
# Two rules are under test here, and they point in opposite directions:
#
#   * bg-backup's OWN output is built with pure-bash helpers, so `status --json`
#     still works on a rescue system with nothing installed. Those helpers must
#     therefore be correct on their own, with no jq to catch their mistakes.
#   * restic's and docker's output is parsed with jq and ONLY with jq, against
#     recorded fixtures.
#
# The first rule is why the json_escape regression below matters so much: there
# is no downstream validator to notice when it goes wrong.
# =============================================================================

setup() {
  load 'helpers/load'
  bgb_setup
  bgb_load_lib core redact json
}

teardown() {
  bgb_teardown
}

# bats-assert has no "this string is not empty" assertion for a value that did
# not come from `run`, and several checks below compare against jq output.
bgb_assert_not_empty() {
  if [ -z "${1:-}" ]; then
    fail "expected a non-empty value${2:+ for ${2}}"
  fi
}

# -----------------------------------------------------------------------------
# THE REGRESSION
# -----------------------------------------------------------------------------
# json_escape strips the control characters that JSON cannot carry raw. The
# original bracket expression started at $'\x00'.
#
# bash cannot hold a NUL byte in a string, so $'\x00' expanded to NOTHING and
# the class silently degenerated from
#     [\x00-\x08\x0b\x0c\x0e-\x1f]
# to
#     [-\x08\x0b\x0c\x0e-\x1f]
# whose LEADING LITERAL '-' matched every hyphen in the input and deleted it.
#
# How it presented in production:
#     "generated": "20260801T000000Z"     (timestamps lost their dashes)
#     "config_dir": "/etc/bgbackup"       (the product's own path, mangled)
#     "tags": ["bgbackup=1","job=system"] (the identity tag, unmatchable)
#
# Nothing failed. The documents stayed valid JSON. Every consumer that keyed off
# a path or a timestamp just quietly stopped matching. These assertions exist so
# that never happens twice, and they are deliberately literal rather than clever.

@test "json: json_escape does not eat hyphens (NUL-in-bracket-expression regression)" {
  local -a plain=(
    '2026-08-01T00:00:00Z'
    '/etc/bg-backup'
    '/etc/bg-backup/conf.d/10-system.conf'
    '/opt/bg-backup/current/bin/bg-backup.sh'
    'bg-backup=1'
    'keep-forever'
    '--exclude-caches'
    'run=20260801T023000Z-a1b2c3'
    'victim.rig.invalid'
    's3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
    '-'
    '---'
    'a-b-c'
    '2026-08-01'
  )

  local v out
  for v in "${plain[@]}"; do
    out="$(json_escape "${v}")"
    if [ "${out}" != "${v}" ]; then
      fail "json_escape mangled a plain string
  input:  ${v}
  output: ${out}"
    fi
  done
}

@test "json: the whole envelope keeps its hyphens and its ISO timestamp" {
  # The end-to-end version of the same regression: an assertion on json_escape
  # alone would still pass if a future refactor moved the stripping elsewhere.
  BGB_VERSION='1.2.3-rc1'
  run json_envelope ok "$(json_kv config_dir '/etc/bg-backup')"
  assert_success
  assert_output --partial '"config_dir":"/etc/bg-backup"'
  assert_output --partial '"tool_version":"1.2.3-rc1"'

  local generated="${output#*\"generated\":\"}"
  generated="${generated%%\"*}"
  if [[ ! "${generated}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    fail "generated timestamp lost its structure: ${generated}"
  fi
}

# -----------------------------------------------------------------------------
# Escaping
# -----------------------------------------------------------------------------

@test "json: json_escape escapes the six characters JSON requires" {
  assert_equal "$(json_escape 'a"b')" 'a\"b'
  assert_equal "$(json_escape 'a\b')" 'a\\b'
  assert_equal "$(json_escape "$(printf 'a\nb')")" 'a\nb'
  assert_equal "$(json_escape "$(printf 'a\tb')")" 'a\tb'
  assert_equal "$(json_escape "$(printf 'a\rb')")" 'a\rb'
  # Backslash before quote: proves the backslash pass runs FIRST, otherwise the
  # escape it introduces would itself be escaped and the document would be wrong.
  assert_equal "$(json_escape '\"')" '\\\"'
}

@test "json: control characters JSON cannot carry raw are dropped, not emitted" {
  # ESC arrives here whenever a colourised message from a hook or from restic is
  # embedded in a document. Emitting it raw produces a document jq rejects, and
  # the rejection surfaces three layers downstream in the notifier.
  local coloured
  coloured="$(printf '\033[0;32m[bg-backup]\033[0m finished')"
  assert_equal "$(json_escape "${coloured}")" '[0;32m[bg-backup][0m finished'
}

@test "json: json_str output survives a jq round trip unchanged" {
  bgb_skip_without jq
  local -a values=(
    '2026-08-01T00:00:00Z'
    '/etc/bg-backup'
    'a "quoted" value'
    'a\backslash\path'
    's3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
  )
  local v
  for v in "${values[@]}"; do
    assert_equal "$(json_str "${v}" | jq -r '.')" "${v}"
  done

  # Whitespace forms, kept out of the loop so a failure names the right one.
  assert_equal "$(json_str "$(printf 'a\tb')" | jq -r '.')" "$(printf 'a\tb')"
  assert_equal "$(json_str "$(printf 'a\nb')" | jq -r '.')" "$(printf 'a\nb')"
}

# -----------------------------------------------------------------------------
# Scalars
# -----------------------------------------------------------------------------

@test "json: json_num emits null rather than an empty value" {
  # `"files_new": ` is not a JSON document. restic omits fields, so the guard
  # has to be here rather than at every call site.
  assert_equal "$(json_num 0)" '0'
  assert_equal "$(json_num 18328)" '18328'
  assert_equal "$(json_num 97.412)" '97.412'
  assert_equal "$(json_num '')" 'null'
  assert_equal "$(json_num 'unknown')" 'null'
  assert_equal "$(json_num 'NaN')" 'null'
}

@test "json: json_bool maps the shell's truth values, not just 1" {
  assert_equal "$(json_bool 1)" 'true'
  assert_equal "$(json_bool true)" 'true'
  assert_equal "$(json_bool yes)" 'true'
  assert_equal "$(json_bool on)" 'true'
  assert_equal "$(json_bool 0)" 'false'
  assert_equal "$(json_bool '')" 'false'
  assert_equal "$(json_bool no)" 'false'
  assert_equal "$(json_bool anything)" 'false'
}

@test "json: json_kv, json_kvraw and json_array build well formed fragments" {
  assert_equal "$(json_kv job system)" '"job":"system"'
  assert_equal "$(json_kv path '/etc/bg-backup')" '"path":"/etc/bg-backup"'
  assert_equal "$(json_kvraw rc 3)" '"rc":3'
  assert_equal "$(json_kvraw missing '')" '"missing":null'
  assert_equal "$(json_array)" '[]'
  assert_equal "$(json_array system docker)" '["system","docker"]'
  assert_equal "$(json_array 'a"b')" '["a\"b"]'
}

@test "json: json_envelope is a valid document with schema, host and verdict" {
  bgb_skip_without jq
  run json_envelope partial "$(
    json_kv job system
    printf ','
    json_kvraw rc 3
  )"
  assert_success

  local doc="${output}"
  assert_equal "$(printf '%s' "${doc}" | jq -r '.verdict')" 'partial'
  assert_equal "$(printf '%s' "${doc}" | jq -r '.schema')" "${BGB_JSON_SCHEMA}"
  assert_equal "$(printf '%s' "${doc}" | jq -r '.job')" 'system'
  assert_equal "$(printf '%s' "${doc}" | jq -r '.rc')" '3'
  assert_equal "$(printf '%s' "${doc}" | jq -r '.host')" "$(fqdn)"
  assert_equal "$(printf '%s' "${doc}" | jq -r '.tool_version')" "${BGB_VERSION}"
}

@test "json: an envelope carrying a secret-shaped value stays parseable" {
  bgb_skip_without jq
  # A value containing quotes and backslashes is exactly what a badly quoted
  # error message from a hook looks like. It must not be able to break the
  # document open - that would be a JSON injection into a monitoring pipeline.
  local nasty='he said "run \x" and exited'
  run json_envelope failed "$(json_kv reason "${nasty}")"
  assert_success
  assert_equal "$(printf '%s' "${output}" | jq -r '.reason')" "${nasty}"
}

# -----------------------------------------------------------------------------
# Parsing restic (fixtures, jq only)
# -----------------------------------------------------------------------------

@test "json: restic_parse_summary reads the summary line, not the progress noise" {
  bgb_skip_without jq
  # Called directly, not via `run`: the function's whole job is to set shell
  # variables, and `run` would set them in a subshell that is then discarded.
  restic_parse_summary "$(bgb_fixture restic-backup-summary.jsonl)"

  assert_equal "${RESTIC_FILES_NEW}" '812'
  assert_equal "${RESTIC_FILES_CHANGED}" '94'
  assert_equal "${RESTIC_FILES_UNMODIFIED}" '17422'
  assert_equal "${RESTIC_DIRS_NEW}" '63'
  assert_equal "${RESTIC_DATA_ADDED}" '268435456'
  assert_equal "${RESTIC_TOTAL_BYTES}" '734003200'
  assert_equal "${RESTIC_TOTAL_FILES}" '18328'
  assert_equal "${RESTIC_SNAPSHOT_ID}" '3f7a1c9e5b2d4086a1c7e9f30b5d6284c19af7e3b0d84c6215fa93e7dc408b51'
}

@test "json: restic_parse_summary zeroes every field when there is no summary" {
  bgb_skip_without jq
  # A backup killed by RuntimeMaxSec produces a stream with no summary line.
  # Every variable must still be set, or the caller trips over `set -u` while
  # building the very state file that would have explained the failure.
  printf '%s\n' '{"message_type":"status","percent_done":0.1}' >"${BGB_TEST_TMP}/truncated.jsonl"
  restic_parse_summary "${BGB_TEST_TMP}/truncated.jsonl"

  assert_equal "${RESTIC_SNAPSHOT_ID}" ''
  assert_equal "${RESTIC_FILES_NEW}" '0'
  assert_equal "${RESTIC_DATA_ADDED}" '0'
  assert_equal "${RESTIC_DURATION}" '0'
}

@test "json: restic_parse_summary on a missing file does not explode" {
  bgb_skip_without jq
  run restic_parse_summary "${BGB_TEST_TMP}/never-written.jsonl"
  assert_success
}

@test "json: restic_count_errors counts error RECORDS" {
  bgb_skip_without jq
  # This number is what turns restic's exit 3 into something actionable: it
  # says HOW MANY files could not be read. It must count records, not the lines
  # a pretty-printer happened to spread them over.
  run restic_count_errors "$(bgb_fixture restic-backup-summary.jsonl)"
  assert_success
  assert_output '2'
}

@test "json: restic_count_errors reports 0 for a clean run and for a missing file" {
  bgb_skip_without jq
  printf '%s\n' '{"message_type":"summary","files_new":1,"snapshot_id":"abc"}' >"${BGB_TEST_TMP}/clean.jsonl"
  run restic_count_errors "${BGB_TEST_TMP}/clean.jsonl"
  assert_output '0'
  run restic_count_errors "${BGB_TEST_TMP}/absent.jsonl"
  assert_output '0'
}

@test "json: restic_error_paths lists the unreadable items" {
  bgb_skip_without jq
  run restic_error_paths "$(bgb_fixture restic-backup-summary.jsonl)"
  assert_success
  assert_line '/var/lib/private/keyring.sock'
  assert_line '/proc/12/task/12/fd/5'
  assert_equal "${#lines[@]}" '2'
}

@test "json: restic_error_paths honours its limit" {
  bgb_skip_without jq
  run restic_error_paths "$(bgb_fixture restic-backup-summary.jsonl)" 1
  assert_success
  assert_equal "${#lines[@]}" '1'
}

@test "json: jq_get returns an empty string for an absent or null field" {
  bgb_skip_without jq
  printf '%s\n' '{"id":"3f7a1c9e","parent":null}' >"${BGB_TEST_TMP}/one.json"
  assert_equal "$(jq_get '.id' "${BGB_TEST_TMP}/one.json")" '3f7a1c9e'
  assert_equal "$(jq_get '.parent' "${BGB_TEST_TMP}/one.json")" ''
  assert_equal "$(jq_get '.nothing' "${BGB_TEST_TMP}/one.json")" ''
}

@test "json: the docker fixtures parse and expose what a docker job needs" {
  bgb_skip_without jq
  # Guards the fixtures themselves. A recorded sample that stops being valid
  # JSON, or that loses the fields the docker module reads, turns every test
  # built on it into a test of nothing.
  local ls_json inspect_json
  ls_json="$(bgb_fixture docker-compose-ls.json)"
  inspect_json="$(bgb_fixture docker-inspect.json)"

  assert_equal "$(jq -r 'length' "${ls_json}")" '3'
  assert_equal "$(jq -r '.[0].Name' "${ls_json}")" 'acme-shop'
  assert_equal "$(jq -r '[.[] | select(.Status | startswith("running"))] | length' "${ls_json}")" '2'

  assert_equal "$(jq -r 'length' "${inspect_json}")" '2'
  assert_equal "$(jq -r '.[0].Config.Labels["com.docker.compose.project"]' "${inspect_json}")" 'acme-shop'
  # Named volumes and bind mounts are backed up differently, so the module has
  # to be able to tell them apart from the same document.
  assert_equal "$(jq -r '[.[].Mounts[] | select(.Type=="volume")] | length' "${inspect_json}")" '2'
  assert_equal "$(jq -r '[.[].Mounts[] | select(.Type=="bind")] | length' "${inspect_json}")" '2'
  # Image digests are what makes `compose pull` on the recovery host reproduce
  # the same images; a tag alone does not.
  bgb_assert_not_empty "$(jq -r '.[0].Image' "${inspect_json}")" '.[0].Image'
  bgb_assert_not_empty \
    "$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"]' "${inspect_json}")" \
    'compose config_files label'
}
