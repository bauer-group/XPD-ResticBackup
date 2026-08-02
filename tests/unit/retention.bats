#!/usr/bin/env bats
# =============================================================================
# bg-backup - retention
# =============================================================================
# forget is the only irreversible code path, and the repository backend is a
# bucket shared across hosts. These tests pin down the two things that would be
# catastrophic and silent:
#
#   * a forget that is not scoped to this host and this job
#   * a configuration with no keep-* read as "keep nothing"
# =============================================================================

load 'helpers/load'

setup() {
  bgb_setup
  bgb_load_lib core redact json config restic state

  BGB_HOSTNAME="test-host.example.invalid"
  BGB_KEEP_TAG="keep-forever"
  BGB_FORGET_MIN_SNAPSHOTS=5
  BGB_FORGET_MAX_DELETE_PERCENT=50

  config_defaults
  job_defaults_reset
  BGB_JOB="docker"

  bgb_load_lib retention
}

teardown() {
  bgb_teardown
}

_args() {
  local -a a=()
  mapfile -t a < <(retention_forget_args "${1:-docker}")
  printf '%s\n' "${a[@]}"
}

# -----------------------------------------------------------------------------
# Scoping - the part that must never be optional
# -----------------------------------------------------------------------------

@test "forget is scoped to this host" {
  JOB_KEEP_DAILY=7
  local -a argv=()
  mapfile -t argv < <(retention_forget_args docker)
  bgb_argv_has_pair --host "test-host.example.invalid" "${argv[@]}"
}

@test "forget is scoped to this job" {
  # Without this, the docker job's policy silently applies to the system job's
  # snapshots too.
  JOB_KEEP_DAILY=7
  local -a argv=()
  mapfile -t argv < <(retention_forget_args docker)
  bgb_argv_has_pair --tag "job=docker" "${argv[@]}"
}

@test "forget groups by host and tags" {
  JOB_KEEP_DAILY=7
  local -a argv=()
  mapfile -t argv < <(retention_forget_args docker)
  bgb_argv_has_pair --group-by "host,tags" "${argv[@]}"
}

@test "forget always honours the manual pin tag" {
  JOB_KEEP_DAILY=7
  local -a argv=()
  mapfile -t argv < <(retention_forget_args docker)
  bgb_argv_has_pair --keep-tag "keep-forever" "${argv[@]}"
}

@test "the three scoping arguments are present together" {
  # Individually each is easy to reintroduce and hard to notice missing, so this
  # asserts the set rather than the parts.
  JOB_KEEP_DAILY=7
  run _args docker
  [[ "$output" == *"--host"* ]]
  [[ "$output" == *"job=docker"* ]]
  [[ "$output" == *"host,tags"* ]]
}

# -----------------------------------------------------------------------------
# Policy translation
# -----------------------------------------------------------------------------

@test "job retention values win over the global defaults" {
  BGB_DEFAULT_KEEP_DAILY=30
  JOB_KEEP_DAILY=14
  local -a argv=()
  mapfile -t argv < <(retention_forget_args docker)
  bgb_argv_has_pair --keep-daily "14" "${argv[@]}"
}

@test "an unset job value inherits the global default" {
  BGB_DEFAULT_KEEP_MONTHLY=6
  JOB_KEEP_MONTHLY=""
  local -a argv=()
  mapfile -t argv < <(retention_forget_args docker)
  bgb_argv_has_pair --keep-monthly "6" "${argv[@]}"
}

@test "a zero keep value is omitted rather than passed as 0" {
  # restic reads --keep-yearly 0 as "keep no yearly snapshots", which is what we
  # mean, but emitting it makes the argv harder to read and the intent unclear.
  JOB_KEEP_DAILY=7
  JOB_KEEP_YEARLY=0
  BGB_DEFAULT_KEEP_YEARLY=0
  run _args docker
  [[ "$output" != *"--keep-yearly"* ]]
}

# -----------------------------------------------------------------------------
# Rail 1: a configuration with no policy is not "keep nothing"
# -----------------------------------------------------------------------------

@test "no keep-* at all is detected as no policy" {
  JOB_KEEP_LAST=""; JOB_KEEP_DAILY=""; JOB_KEEP_WEEKLY=""
  JOB_KEEP_MONTHLY=""; JOB_KEEP_YEARLY=""; JOB_KEEP_WITHIN=""
  BGB_DEFAULT_KEEP_LAST=""; BGB_DEFAULT_KEEP_DAILY=""; BGB_DEFAULT_KEEP_WEEKLY=""
  BGB_DEFAULT_KEEP_MONTHLY=""; BGB_DEFAULT_KEEP_YEARLY=""; BGB_DEFAULT_KEEP_WITHIN=""

  run retention_has_policy docker
  [ "$status" -ne 0 ]
}

@test "--keep-tag alone does not count as a policy" {
  # It is always present, so a naive "does the argv mention keep" check would
  # treat every empty configuration as valid.
  JOB_KEEP_LAST=""; JOB_KEEP_DAILY=""; JOB_KEEP_WEEKLY=""
  JOB_KEEP_MONTHLY=""; JOB_KEEP_YEARLY=""; JOB_KEEP_WITHIN=""
  BGB_DEFAULT_KEEP_LAST=""; BGB_DEFAULT_KEEP_DAILY=""; BGB_DEFAULT_KEEP_WEEKLY=""
  BGB_DEFAULT_KEEP_MONTHLY=""; BGB_DEFAULT_KEEP_YEARLY=""; BGB_DEFAULT_KEEP_WITHIN=""

  run _args docker
  [[ "$output" == *"--keep-tag"* ]]

  run retention_has_policy docker
  [ "$status" -ne 0 ]
}

@test "forget with no policy exits 9 and never reaches restic" {
  JOB_KEEP_LAST=""; JOB_KEEP_DAILY=""; JOB_KEEP_WEEKLY=""
  JOB_KEEP_MONTHLY=""; JOB_KEEP_YEARLY=""; JOB_KEEP_WITHIN=""
  BGB_DEFAULT_KEEP_LAST=""; BGB_DEFAULT_KEEP_DAILY=""; BGB_DEFAULT_KEEP_WEEKLY=""
  BGB_DEFAULT_KEEP_MONTHLY=""; BGB_DEFAULT_KEEP_YEARLY=""; BGB_DEFAULT_KEEP_WITHIN=""

  # A restic that fails loudly if it is ever called: the rail must fire before
  # any repository access.
  BGB_RESTIC_BIN="${BGB_TEST_TMP}/restic-must-not-run"
  cat >"${BGB_RESTIC_BIN}" <<'STUB'
#!/usr/bin/env bash
echo "restic was invoked despite an empty retention policy" >&2
exit 111
STUB
  chmod +x "${BGB_RESTIC_BIN}"

  run retention_forget docker 1
  [ "$status" -eq 9 ]
  [[ "$output" != *"restic was invoked"* ]]
}

@test "a valid policy passes the policy check" {
  JOB_KEEP_DAILY=7
  run retention_has_policy docker
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Rails 2 and 3: floor and ceiling
# -----------------------------------------------------------------------------

_stub_restic_forget() {
  # Emits a restic-shaped forget --dry-run --json document with the requested
  # keep/remove counts.
  local keep="$1" remove="$2"
  BGB_RESTIC_BIN="${BGB_TEST_TMP}/restic-stub"
  cat >"${BGB_RESTIC_BIN}" <<STUB
#!/usr/bin/env bash
keep_n=${keep}
rm_n=${remove}
printf '[{"keep":['
for i in \$(seq 1 \${keep_n}); do
  [ "\${i}" -gt 1 ] && printf ','
  printf '{"short_id":"k%s","time":"2026-08-0%sT00:00:00Z","tags":["job=docker"]}' "\${i}" "\$(( i % 9 + 1 ))"
done
printf '],"remove":['
for i in \$(seq 1 \${rm_n}); do
  [ "\${i}" -gt 1 ] && printf ','
  printf '{"short_id":"r%s","time":"2026-07-0%sT00:00:00Z","tags":["job=docker"]}' "\${i}" "\$(( i % 9 + 1 ))"
done
printf ']}]'
STUB
  chmod +x "${BGB_RESTIC_BIN}"
}

@test "forget refuses when too few snapshots would remain" {
  bgb_skip_without jq
  JOB_KEEP_DAILY=7
  BGB_FORGET_MIN_SNAPSHOTS=5
  _stub_restic_forget 2 3          # 2 would remain, floor is 5

  run retention_forget docker 1
  [ "$status" -eq 9 ]
  [[ "$output" == *"floor"* ]] || [[ "$output" == *"leave"* ]]
}

@test "forget refuses when too large a share would be removed" {
  bgb_skip_without jq
  JOB_KEEP_DAILY=7
  BGB_FORGET_MIN_SNAPSHOTS=1
  BGB_FORGET_MAX_DELETE_PERCENT=50
  BGB_YES=0
  _stub_restic_forget 2 8          # 80 % removed

  run retention_forget docker 1
  [ "$status" -eq 9 ]
}

@test "the deletion ceiling can be overridden deliberately with --yes" {
  bgb_skip_without jq
  JOB_KEEP_DAILY=7
  BGB_FORGET_MIN_SNAPSHOTS=1
  BGB_FORGET_MAX_DELETE_PERCENT=50
  BGB_YES=1
  _stub_restic_forget 2 8

  run retention_forget docker 0    # dry run, so nothing is deleted either way
  [ "$status" -eq 0 ]
}

@test "a dry run never deletes even when every rail is satisfied" {
  bgb_skip_without jq
  JOB_KEEP_DAILY=7
  BGB_FORGET_MIN_SNAPSHOTS=1
  _stub_restic_forget 10 2

  run retention_forget docker 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run"* ]] || [[ "$output" == *"would remove"* ]]
}

@test "nothing to remove is a success, not an error" {
  bgb_skip_without jq
  JOB_KEEP_DAILY=7
  _stub_restic_forget 10 0

  run retention_forget docker 1
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# prune
# -----------------------------------------------------------------------------

@test "prune refuses on a secondary repository role" {
  # Two hosts pruning one repository can remove packs the other still
  # references, so the role gate is a correctness control.
  BGB_REPO_ROLE="secondary"
  bgb_require_fn "the prune command" cmd_prune
  run cmd_prune
  [ "$status" -ne 0 ]
}
