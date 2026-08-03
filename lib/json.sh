#!/usr/bin/env bash
# =============================================================================
# bg-backup - json: emit bg-backup's own JSON, parse everyone else's with jq
# =============================================================================
# RULE, enforced in review and by tests/unit/json.bats:
#
#   * bg-backup's OWN output is built with the helpers below - no jq needed, so
#     `status --json` still works on a rescue system with nothing installed.
#   * restic's and docker's output is parsed with jq and ONLY with jq. Never
#     grep, never sed, never a regex over JSON. If jq is missing, the command
#     refuses (exit 4) rather than guessing.
#
# The second half of that rule is why require_jq() exists. A backup tool that
# silently mis-parses a restic summary reports success it did not achieve.
# =============================================================================

[ -n "${_BGB_JSON_SOURCED:-}" ] && return 0
_BGB_JSON_SOURCED=1

# Bumped only on a breaking change to any --json document.
readonly BGB_JSON_SCHEMA=1

# -----------------------------------------------------------------------------
# Emitting
# -----------------------------------------------------------------------------

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Control characters below 0x20 are invalid raw in JSON strings. The three that
  # actually occur are handled above; the rest (ESC from colour codes, mostly)
  # are dropped rather than producing a document jq will reject downstream.
  #
  # The range MUST start at \x01, not \x00: bash cannot hold a NUL in a string,
  # so $'\x00' expands to nothing and the bracket expression degenerates to
  # [-\x08...], whose leading literal '-' then strips every hyphen in the input.
  # That presented as timestamps losing their dashes and /etc/bg-backup being
  # reported as /etc/bgbackup - silent, and wrong in a way that looks like a
  # typo somewhere else entirely.
  if [[ "${s}" == *[$'\x01'-$'\x08'$'\x0b'$'\x0c'$'\x0e'-$'\x1f']* ]]; then
    s="${s//[$'\x01'-$'\x08'$'\x0b'$'\x0c'$'\x0e'-$'\x1f']/}"
  fi
  printf '%s' "${s}"
}

json_str() { printf '"%s"' "$(json_escape "$1")"; }

# json_kv <key> <value>          - string-valued pair
json_kv() { printf '%s:%s' "$(json_str "$1")" "$(json_str "$2")"; }

# json_kvraw <key> <literal>     - number, boolean, object, array or null
json_kvraw() { printf '%s:%s' "$(json_str "$1")" "${2:-null}"; }

# json_num <value> - emit a JSON number, or null when the input is not numeric.
# Guards against `"files_new": ` (invalid) when restic omits a field.
json_num() {
  local v="${1:-}"
  case "${v}" in
    '' | *[!0-9.eE+-]*) printf 'null' ;;
    *) printf '%s' "${v}" ;;
  esac
}

json_bool() { case "${1:-}" in 1 | true | yes | on) printf 'true' ;; *) printf 'false' ;; esac }

# json_array <item...> - array of strings
json_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    [ "${first}" -eq 0 ] && printf ','
    json_str "${item}"
    first=0
  done
  printf ']'
}

# json_envelope <verdict> <body-without-braces>
# Every bg-backup JSON document starts with schema/host/generated so a consumer
# can tell our output apart from restic's and can version-gate on it.
json_envelope() {
  local verdict="$1" body="$2"
  printf '{'
  json_kvraw schema "${BGB_JSON_SCHEMA}"
  printf ','
  json_kv host "$(fqdn)"
  printf ','
  json_kv generated "$(now_iso)"
  printf ','
  json_kv tool_version "${BGB_VERSION}"
  printf ','
  [ -n "${body}" ] && {
    printf '%s' "${body}"
    printf ','
  }
  json_kv verdict "${verdict}"
  printf '}\n'
}

# json_pretty - pass through jq for readability when available, otherwise emit
# the compact document unchanged. Never a hard dependency for our own output.
json_pretty() {
  if have jq; then jq . 2>/dev/null || cat; else cat; fi
}

# -----------------------------------------------------------------------------
# Parsing (jq only)
# -----------------------------------------------------------------------------

# jq_get <filter> [file]  - read a value, empty string when absent or null.
jq_get() {
  local filter="$1" file="${2:-}"
  require_jq
  if [ -n "${file}" ]; then
    jq -r "${filter} // empty" "${file}" 2>/dev/null || true
  else
    jq -r "${filter} // empty" 2>/dev/null || true
  fi
}

# restic_summary_field <summary-json> <field>
# restic's `backup --json` emits one object per line; the last one with
# message_type=="summary" carries the counters. Anything else in the stream is
# progress noise.
restic_summary_field() {
  local json="$1" field="$2"
  require_jq
  printf '%s' "${json}" | jq -r --arg f "${field}" \
    'select(.message_type=="summary") | .[$f] // empty' 2>/dev/null | tail -n1
}

# restic_parse_summary <jsonl-file>
# Extracts the summary line into shell variables. Sets every variable even when
# the field is absent, so callers can rely on `set -u` not tripping.
restic_parse_summary() {
  local file="$1" line
  require_jq
  RESTIC_SNAPSHOT_ID=""
  RESTIC_FILES_NEW=0
  RESTIC_FILES_CHANGED=0
  RESTIC_FILES_UNMODIFIED=0
  RESTIC_DIRS_NEW=0
  RESTIC_DIRS_CHANGED=0
  RESTIC_DIRS_UNMODIFIED=0
  RESTIC_DATA_ADDED=0
  RESTIC_TOTAL_BYTES=0
  RESTIC_TOTAL_FILES=0
  RESTIC_DURATION=0

  [ -r "${file}" ] || return 0
  line="$(jq -c 'select(.message_type=="summary")' "${file}" 2>/dev/null | tail -n1)"
  [ -z "${line}" ] && return 0

  RESTIC_SNAPSHOT_ID="$(printf '%s' "${line}" | jq -r '.snapshot_id      // ""')"
  RESTIC_FILES_NEW="$(printf '%s' "${line}" | jq -r '.files_new        // 0')"
  RESTIC_FILES_CHANGED="$(printf '%s' "${line}" | jq -r '.files_changed  // 0')"
  RESTIC_FILES_UNMODIFIED="$(printf '%s' "${line}" | jq -r '.files_unmodified // 0')"
  RESTIC_DIRS_NEW="$(printf '%s' "${line}" | jq -r '.dirs_new         // 0')"
  RESTIC_DIRS_CHANGED="$(printf '%s' "${line}" | jq -r '.dirs_changed    // 0')"
  RESTIC_DIRS_UNMODIFIED="$(printf '%s' "${line}" | jq -r '.dirs_unmodified // 0')"
  RESTIC_DATA_ADDED="$(printf '%s' "${line}" | jq -r '.data_added       // 0')"
  RESTIC_TOTAL_BYTES="$(printf '%s' "${line}" | jq -r '.total_bytes_processed // 0')"
  RESTIC_TOTAL_FILES="$(printf '%s' "${line}" | jq -r '.total_files_processed // 0')"
  RESTIC_DURATION="$(printf '%s' "${line}" | jq -r '.total_duration   // 0')"
  return 0
}

# restic_count_errors <jsonl-file> - number of error RECORDS in a backup stream.
# This is what turns restic's exit 3 into an actionable number rather than a
# shrug: it tells you HOW MANY files could not be read.
#
# `jq -r 'select(...)' | grep -c` counts jq's PRETTY-PRINTED LINES, not records:
# two errors came out as 16. The reported unreadable-file count was inflated by
# roughly the number of lines per record - and that number is exactly what an
# operator uses to decide whether an exit 3 matters.
#
# -s slurps the JSONL into one array so length is a record count.
restic_count_errors() {
  local file="$1" n
  require_jq
  [ -r "${file}" ] || {
    printf '0'
    return 0
  }
  n="$(jq -s '[.[] | select(.message_type=="error")] | length' "${file}" 2>/dev/null)"
  case "${n}" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "${n}" ;;
  esac
}

# restic_error_paths <jsonl-file> [limit]
restic_error_paths() {
  local file="$1" limit="${2:-20}"
  require_jq
  [ -r "${file}" ] || return 0
  jq -r 'select(.message_type=="error") | .item // .during // "?"' "${file}" 2>/dev/null \
    | head -n "${limit}"
}
