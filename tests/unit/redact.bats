# =============================================================================
# bg-backup - unit: credential redaction
# =============================================================================
# This is the highest-consequence unit file in the suite. Everything bg-backup
# prints reaches a place it does not control: the journal, a log file shipped to
# Loki, a Teams card, a Prometheus textfile, a support ticket with a pasted
# `doctor` transcript. A single unmasked passphrase in any of those is a
# repository compromise, and it is silent - nothing fails, nothing alerts, the
# secret is simply out.
#
# TWO LAYERS ARE TESTED SEPARATELY, ON PURPOSE.
#
#   Layer 1 - literal values registered at load time. Exact and cheap. Every
#             "registered secret" table row below exercises this.
#   Layer 2 - structural patterns (credentials inside a URL, bearer tokens, push
#             tokens). This is the layer that protects a secret the tool was
#             never told about, and it is the layer that would rot unnoticed if
#             it were only ever tested with values that layer 1 already masks.
#             Its rows therefore use values that are deliberately NOT registered.
#
# The literals used here are the throwaway CI values allowlisted in
# .gitleaks.toml. They exist in an ephemeral MinIO container and nowhere else.
# =============================================================================

setup() {
  load 'helpers/load'
  bgb_setup
  bgb_load_lib core redact
}

teardown() {
  bgb_teardown
}

BGB_TEST_SECRET='bgb-it-ci-throwaway-repo-passphrase'
BGB_TEST_S3_SECRET='bgb-it-ci-throwaway-secret'

# -----------------------------------------------------------------------------
# Layer 1: a registered secret must not survive any framing
# -----------------------------------------------------------------------------

@test "redact: a registered secret survives no context (table)" {
  redact_register "${BGB_TEST_SECRET}"

  # description|template, with the literal SECRET substituted in. Table-driven
  # because the interesting axis is the FRAMING, not the value: a bug in the
  # ordering of the two layers shows up as exactly one of these rows failing.
  local -a rows=(
    "bare value|SECRET"
    "shell assignment|RESTIC_PASSWORD=SECRET"
    "s3 url with inline credentials|s3:https://bgb-it-ci-user:SECRET@minio.rig.invalid:9800/bgb-rig/victim.rig.invalid"
    "json value|{\"passphrase\":\"SECRET\",\"host\":\"victim.rig.invalid\"}"
    "uptime kuma push url|https://kuma.rig.invalid/api/push/SECRET?status=up&msg=OK"
    "teams webhook url|https://acme.webhook.office.com/webhookb2/SECRET/IncomingWebhook/0a1b2c"
    "authorization header|Authorization: Bearer SECRET"
    "restic failure line|Fatal: wrong password for repo (tried SECRET) at 2026-08-01T02:30:00Z"
    "multi word sentence|the key is SECRET and nothing else"
  )

  local row desc input out
  for row in "${rows[@]}"; do
    desc="${row%%|*}"
    input="${row#*|}"
    input="${input//SECRET/${BGB_TEST_SECRET}}"
    out="$(redact "${input}")"
    case "${out}" in
      *"${BGB_TEST_SECRET}"*)
        fail "redaction leaked a registered secret
  case:   ${desc}
  input:  ${input}
  output: ${out}"
        ;;
    esac
  done
}

@test "redact: the replacement marker is what actually lands in the output" {
  redact_register "${BGB_TEST_SECRET}"
  assert_equal "$(redact "key=${BGB_TEST_SECRET}")" "key=${BGB_REDACTED}"
}

@test "redact: a secret containing another is masked before its substring" {
  # Registration order is deliberately the wrong way round here. _bgb_sort_secrets
  # must re-order by length, otherwise the short value is substituted first and
  # the tail of the long one survives as "***REDACTED***-extended-value" - which
  # looks redacted at a glance and is not.
  redact_register "${BGB_TEST_S3_SECRET}" "${BGB_TEST_S3_SECRET}-extended-value"
  assert_equal "$(redact "v=${BGB_TEST_S3_SECRET}-extended-value")" "v=${BGB_REDACTED}"
}

@test "redact: values shorter than 8 characters are deliberately not registered" {
  # Masking every occurrence of a 4-character string shreds unrelated output and
  # protects nothing worth protecting. This is a documented decision, so it gets
  # a test rather than a comment that drifts.
  redact_register 'short'
  assert_equal "$(redact 'a short word in a longer line')" 'a short word in a longer line'
}

# -----------------------------------------------------------------------------
# Layer 2: structural patterns, on values the tool was never told about
# -----------------------------------------------------------------------------

@test "redact: an unregistered credential is still caught by shape (table)" {
  # NOTHING is registered in this test. Every row must be masked purely by the
  # structural pass. All values are placeholder-shaped so gitleaks stays quiet
  # and so no reviewer is ever trained to skim past a key-shaped string.
  #
  # NOTE ON THE ROW SHAPES: layer 2 is gated by a cheap `case` on trigger words
  # ("://", token, authorization, password, secret, key, webhook, hc-ping) so
  # the sed fork stays off the hot path. Every row below therefore contains one
  # of those words, exactly as a real log line from restic, curl or the AWS SDK
  # would. A bare key-shaped string in an otherwise neutral sentence is NOT
  # covered by design - that limitation belongs in SECURITY.md, not in a test
  # that pretends otherwise.
  local -a rows=(
    "credentials in a url|s3:https://someuser:PLACEHOLDER_pw_value@minio.rig.invalid/bgb-rig|PLACEHOLDER_pw_value"
    "kuma push token|https://kuma.rig.invalid/api/push/PLACEHOLDERtoken123|PLACEHOLDERtoken123"
    "teams webhook|https://acme.webhook.office.com/webhookb2/PLACEHOLDER-1/IncomingWebhook/x|PLACEHOLDER-1"
    "authorization header|Authorization: PLACEHOLDER_HEADER_VALUE|PLACEHOLDER_HEADER_VALUE"
    "bearer token|curl -H 'Bearer PLACEHOLDER_BEARER_VALUE' https://api.rig.invalid|PLACEHOLDER_BEARER_VALUE"
    "aws access key id|access key AKIAPLACEHOLDER12345 rejected by the bucket|AKIAPLACEHOLDER12345"
    "password assignment|password = PLACEHOLDER_pw|PLACEHOLDER_pw"
    "signed query parameter|https://blob.rig.invalid/x?sig=PLACEHOLDERsignature|PLACEHOLDERsignature"
  )

  local row desc input needle out
  for row in "${rows[@]}"; do
    desc="${row%%|*}"
    input="${row#*|}"
    needle="${input##*|}"
    input="${input%|*}"
    out="$(redact "${input}")"
    case "${out}" in
      *"${needle}"*)
        fail "structural redaction missed an unregistered credential
  case:   ${desc}
  input:  ${input}
  output: ${out}"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# False positives - the other half of the contract
# -----------------------------------------------------------------------------
# Redaction that eats ordinary text is not "safe by default", it is a debugging
# tool that lies. A destroyed timestamp or a mangled path in an incident log
# costs exactly as much as the secret it was protecting.

@test "redact: ordinary operational output is left byte for byte alone" {
  redact_register "${BGB_TEST_SECRET}" "${BGB_TEST_S3_SECRET}"

  local -a plain=(
    '/etc/bg-backup/conf.d/10-system.conf'
    '2026-08-01T02:30:00Z rc=3 files=18328 dirs=2841'
    'snapshot 3f7a1c9e created in 0h 01m 37s'
    'run=20260801T023000Z-a1b2c3 job=system host=victim.rig.invalid'
    's3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
  )
  local v
  for v in "${plain[@]}"; do
    assert_equal "$(redact "${v}")" "${v}"
  done
}

# -----------------------------------------------------------------------------
# Registration sources
# -----------------------------------------------------------------------------

@test "redact: redact_register_env picks up the well known credential variables" {
  RESTIC_PASSWORD="${BGB_TEST_SECRET}"
  AWS_SECRET_ACCESS_KEY="${BGB_TEST_S3_SECRET}"
  AWS_ACCESS_KEY_ID='bgb-it-ci-user'
  BGB_MONITOR_KUMA_PUSH_URL='https://kuma.rig.invalid/api/push/PLACEHOLDERtoken123'
  redact_register_env

  local out
  out="$(redact "repo=${RESTIC_PASSWORD} s3=${AWS_SECRET_ACCESS_KEY} id=${AWS_ACCESS_KEY_ID} kuma=${BGB_MONITOR_KUMA_PUSH_URL}")"
  assert bgb_refute_secret "${out}" \
    "${RESTIC_PASSWORD}" "${AWS_SECRET_ACCESS_KEY}" "${AWS_ACCESS_KEY_ID}" "${BGB_MONITOR_KUMA_PUSH_URL}"
}

@test "redact: redact_register_file registers values WITHOUT sourcing the file" {
  local f="${BGB_TEST_TMP}/repo.env"
  cat >"${f}" <<EOF
# a comment line that must be ignored
export RESTIC_REPOSITORY='s3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
export RESTIC_PASSWORD='${BGB_TEST_SECRET}'
export AWS_SECRET_ACCESS_KEY="${BGB_TEST_S3_SECRET}"
BGB_TEST_SOURCING_CANARY=1
EOF

  redact_register_file "${f}"

  # The point of this function is that a credential file can be masked without
  # its code being executed in this context. If the canary is set, the file was
  # sourced, and every future "we only read it" claim in SECURITY.md is false.
  assert_equal "${BGB_TEST_SOURCING_CANARY:-unset}" 'unset'

  local out
  out="$(redact "pass=${BGB_TEST_SECRET} secret=${BGB_TEST_S3_SECRET}")"
  assert bgb_refute_secret "${out}" "${BGB_TEST_SECRET}" "${BGB_TEST_S3_SECRET}"
}

@test "redact: redact_register_file on a missing file is a no-op, not an error" {
  run redact_register_file "${BGB_TEST_TMP}/does-not-exist.env"
  assert_success
}

# -----------------------------------------------------------------------------
# Streams
# -----------------------------------------------------------------------------

@test "redact: redact_stream filters a pipeline line by line" {
  redact_register "${BGB_TEST_SECRET}"

  # Called directly rather than through `run bash -c`: redact_stream is a shell
  # function, so a fresh bash would not have it and the test would silently
  # exercise nothing. The pipeline subshell inherits it from this shell.
  local out
  out="$(printf 'first\nkey=%s\nthird\n' "${BGB_TEST_SECRET}" | redact_stream)"

  assert bgb_refute_secret "${out}" "${BGB_TEST_SECRET}"
  assert_equal "$(printf '%s' "${out}" | head -n1)" 'first'
  assert_equal "$(printf '%s' "${out}" | tail -n1)" 'third'
}

@test "redact: redact_tail truncates first, then redacts" {
  redact_register "${BGB_TEST_SECRET}"
  local log="${BGB_TEST_TMP}/job.log"
  printf 'line one\nAWS_SECRET_ACCESS_KEY=%s\nline three\n' "${BGB_TEST_SECRET}" >"${log}"

  run redact_tail "${log}" 60000
  assert_success
  refute_output --partial "${BGB_TEST_SECRET}"
  assert_output --partial 'line three'
}

# -----------------------------------------------------------------------------
# Self test - what `doctor` runs on a live host
# -----------------------------------------------------------------------------

@test "redact: redact_selftest passes for every registered secret" {
  redact_register "${BGB_TEST_SECRET}" "${BGB_TEST_S3_SECRET}" 'bgb-it-ci-user'
  run redact_selftest
  assert_success
}

@test "redact: redact_selftest is a no-op when nothing is registered" {
  run redact_selftest
  assert_success
}

@test "redact: log output routed through the emitter is redacted too" {
  # _bgb_emit() calls redact() when the module is loaded. That indirection is
  # the reason nothing in the codebase has to remember to redact by hand, so it
  # is asserted here rather than trusted.
  redact_register "${BGB_TEST_SECRET}"
  run err "failed to open repository with ${BGB_TEST_SECRET}"
  assert_success
  refute_output --partial "${BGB_TEST_SECRET}"
  assert_output --partial "${BGB_REDACTED}"
}
