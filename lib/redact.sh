#!/usr/bin/env bash
# =============================================================================
# bg-backup - redact: keep credentials out of logs, notifications and metrics
# =============================================================================
# Every string that leaves this process passes through redact(): the journal,
# /var/log/bg-backup/*, notifier payloads, .prom files and `doctor` output.
#
# TWO LAYERS, and the second is the point:
#
#   1. Literal values registered at load time (repository passphrase, S3 secret,
#      webhook URLs). Exact, cheap, but only covers what we know about.
#
#   2. Structural patterns - credentials embedded in a URL, bearer tokens, push
#      tokens, key-shaped strings. This is what protects a secret the tool was
#      never told about: an access key an operator interpolated into a custom
#      endpoint, a password pasted into a hook script's error message.
#
# Layer 1 alone would be security theatre. State that plainly in SECURITY.md
# rather than implying the tool can redact what it has never seen.
# =============================================================================

[ -n "${_BGB_REDACT_SOURCED:-}" ] && return 0
_BGB_REDACT_SOURCED=1

readonly BGB_REDACTED='***REDACTED***'

# Literal secret values, longest first so a secret that contains another is
# masked before its substring is.
_BGB_SECRETS=()

# redact_register <value> [...]
# Values shorter than 8 characters are ignored on purpose: masking every
# occurrence of a 4-character string would shred unrelated log output and make
# the result useless for debugging, without protecting anything worth
# protecting.
redact_register() {
  local v
  for v in "$@"; do
    [ -z "${v}" ] && continue
    [ "${#v}" -lt 8 ] && continue
    _BGB_SECRETS+=("${v}")
  done
  _bgb_sort_secrets
}

_bgb_sort_secrets() {
  local -a sorted=()
  local s
  while IFS= read -r s; do
    [ -n "${s}" ] && sorted+=("${s}")
  done < <(printf '%s\n' "${_BGB_SECRETS[@]:-}" | awk '{ print length"\t"$0 }' | sort -rn | cut -f2-)
  _BGB_SECRETS=("${sorted[@]:-}")
}

# redact_register_env - pull the well-known credential-bearing variables out of
# the current environment. Called after the repository env file is sourced.
redact_register_env() {
  redact_register \
    "${RESTIC_PASSWORD:-}" \
    "${AWS_SECRET_ACCESS_KEY:-}" \
    "${AWS_ACCESS_KEY_ID:-}" \
    "${AWS_SESSION_TOKEN:-}" \
    "${B2_ACCOUNT_KEY:-}" \
    "${B2_ACCOUNT_ID:-}" \
    "${AZURE_ACCOUNT_KEY:-}" \
    "${GOOGLE_APPLICATION_CREDENTIALS:-}" \
    "${OS_PASSWORD:-}" \
    "${SWIFT_PASSWORD:-}" \
    "${BGB_MONITOR_TEAMS_WEBHOOK_URL:-}" \
    "${BGB_MONITOR_KUMA_PUSH_URL:-}" \
    "${BGB_MONITOR_WEBHOOK_URL:-}" \
    "${BGB_ESCROW_PASSPHRASE:-}"
}

# redact_register_file <path> - register every value from a KEY=VALUE file
# without sourcing it. Used for credential files whose contents we must mask but
# whose code we do not want to execute in this context.
redact_register_file() {
  local f="$1" line val
  [ -r "${f}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|\#*) continue ;; esac
    val="${line#*=}"
    val="${val#export }"
    # Strip one layer of matching quotes.
    case "${val}" in
      \'*\') val="${val:1:${#val}-2}" ;;
      \"*\") val="${val:1:${#val}-2}" ;;
    esac
    redact_register "${val}"
  done <"${f}"
}

# redact <string>
redact() {
  local s="$1" secret

  # --- Layer 1: known literals (pure bash, no fork) --------------------------
  # str_replace_all, NOT ${s//${secret}/...}: the latter treats the secret as a
  # GLOB, so a passphrase containing a bracket expression is never matched and
  # goes into the log in full. Measured: `pw[0-9]x` survived redaction intact.
  # A generated passphrase with brackets is exactly the kind nobody re-reads.
  for secret in "${_BGB_SECRETS[@]:-}"; do
    [ -z "${secret}" ] && continue
    s="$(str_replace_all "${s}" "${secret}" "${BGB_REDACTED}")"
  done

  # --- Layer 2: structural patterns ----------------------------------------
  # One sed invocation, guarded by a cheap prefilter. This runs on bg-backup's
  # own messages (tens per run), not on restic's file-by-file output, so the
  # fork is not on a hot path.
  #
  # THE GUARD MUST BE A SUPERSET OF WHAT THE PATTERNS BELOW CAN MATCH. It is an
  # optimisation, and an optimisation that skips a security control is a hole.
  # An earlier version omitted "bearer", so
  #     sent Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig to the api
  # passed through untouched: no "://", no "token", no "authorization" - the sed
  # never ran. Same for a bare "passphrase=" (the guard tested for "password"),
  # a lone AKIA key, and "sig=".
  #
  # Every entry below corresponds to a pattern in the sed. Adding a pattern
  # means adding its trigger here.
  case "${s}" in
    *://*|*[Bb]earer*|*[Tt]oken*|*[Aa]uthorization*|*[Pp]ass*|*[Ss]ecret*|\
    *[Kk]ey*|*hc-ping*|*webhook*|*AKIA*|*[Ss]ig=*|*[Ss]ignature*|*api_key*|*api-key*)
      s="$(printf '%s' "${s}" | sed -E \
        -e 's#(://[^/:@[:space:]]+):[^@[:space:]]+@#\1:***REDACTED***@#g' \
        -e 's#(hc-ping\.com/)[0-9a-fA-F-]{16,}#\1***REDACTED***#g' \
        -e 's#(/api/push/)[A-Za-z0-9_-]{6,}#\1***REDACTED***#g' \
        -e 's#(https://[A-Za-z0-9.-]*(webhook\.office\.com|logic\.azure\.com)[^[:space:]"'"'"']*)#***REDACTED_WEBHOOK***#g' \
        -e 's#([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/=-]{8,}#\1***REDACTED***#g' \
        -e 's#([Aa]uthorization:[[:space:]]*)[^"'"'"',}\r\n]*#\1***REDACTED***#g' \
        -e 's#((api[_-]?key|access[_-]?token|password|passphrase|secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^[:space:]"'"'"',}]{6,}#\1***REDACTED***#gI' \
        -e 's#\bAKIA[0-9A-Z]{16}\b#***REDACTED***#g' \
        -e 's#(\?|&)([Tt]oken|[Ss]ig|[Ss]ignature|[Kk]ey)=[^&[:space:]]+#\1\2=***REDACTED***#g' \
      )"
      ;;
  esac

  printf '%s' "${s}"
}

# redact_stream - filter stdin to stdout. For attaching log excerpts to a
# notification without materialising them unredacted first.
redact_stream() {
  local line
  while IFS= read -r line || [ -n "${line}" ]; do
    redact "${line}"
    printf '\n'
  done
}

# redact_tail <file> <bytes> - the standard way to attach a log excerpt.
# Truncates first, then redacts, so a huge log cannot turn into a huge number of
# sed invocations.
redact_tail() {
  local f="$1" bytes="${2:-60000}"
  [ -r "${f}" ] || return 0
  tail -c "${bytes}" "${f}" | redact_stream
}

# redact_selftest - used by `doctor` and by tests/unit/redact.bats.
# Returns non-zero if any registered secret survives a round trip.
redact_selftest() {
  local secret out rc=0
  for secret in "${_BGB_SECRETS[@]:-}"; do
    [ -z "${secret}" ] && continue
    out="$(redact "value=${secret} trailing")"
    case "${out}" in
      *"${secret}"*) err "Redaction self-test FAILED for a registered secret"; rc=1 ;;
    esac
  done
  return "${rc}"
}
