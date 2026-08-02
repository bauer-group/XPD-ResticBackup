#!/usr/bin/env bats
# =============================================================================
# bg-backup - restic argv construction and exit-code mapping
# =============================================================================
# The argv is where a secret would leak into /proc/<pid>/cmdline, and the exit
# mapping is what turns restic's codes into something a scheduler can act on.
# =============================================================================

load 'helpers/load'

setup() {
  bgb_setup
  bgb_load_lib core redact json config restic

  BGB_HOSTNAME="test-host.example.invalid"
  config_defaults
  job_defaults_reset

  JOB_PATHS=( /srv/data /etc )
  JOB_TAGS=( tier=test )
  JOB_ONE_FILE_SYSTEM=1
  JOB_EXCLUDE_CACHES=1
  JOB_EXCLUDE_FILE=""
}

teardown() {
  bgb_teardown
}

_backup_argv() {
  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args "${1:-docker}" "${2:-run-1}")
  printf '%s\n' "${argv[@]}"
}

# -----------------------------------------------------------------------------
# No secret in argv
# -----------------------------------------------------------------------------

@test "no credential appears in the backup argv" {
  # /proc/<pid>/cmdline is world-readable; /proc/<pid>/environ is not. The
  # passphrase travels via RESTIC_PASSWORD_FILE and the S3 secret via the
  # environment, so neither may ever be built into an argument.
  RESTIC_PASSWORD="super-secret-passphrase"
  AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMIK7MDENGbPxRfiCY"

  local out
  out="$(_backup_argv docker run-1)"

  bgb_refute_secret "${out}" "super-secret-passphrase" "wJalrXUtnFEMIK7MDENGbPxRfiCY"
}

@test "the argv references the password FILE, never the password" {
  RESTIC_PASSWORD_FILE="/etc/bg-backup/credentials/repo.key"
  RESTIC_PASSWORD="should-not-appear"
  local out
  out="$(_backup_argv docker run-1)"
  bgb_refute_secret "${out}" "should-not-appear"
}

# -----------------------------------------------------------------------------
# Identity tags
# -----------------------------------------------------------------------------

@test "every snapshot carries the four identity tags" {
  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args docker run-42)

  bgb_argv_has_pair --tag "bg-backup=1" "${argv[@]}"
  bgb_argv_has_pair --tag "job=docker"  "${argv[@]}"
  bgb_argv_has_pair --tag "run=run-42"  "${argv[@]}"
  bgb_argv_has_pair --host "test-host.example.invalid" "${argv[@]}"
}

@test "the run tag is what makes a restore-by-run possible" {
  # One backup produces several snapshots; without run= they can only be
  # resolved individually, which pairs a database dump from one day with volume
  # contents from another.
  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args system 20260802T031500Z-a7f3k2)
  bgb_argv_has_pair --tag "run=20260802T031500Z-a7f3k2" "${argv[@]}"
}

@test "configured job tags are added alongside the identity tags" {
  JOB_TAGS=( tier=os legacy-stopped )
  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args system run-1)
  bgb_argv_has_pair --tag "tier=os" "${argv[@]}"
  # Legacy tags must survive: existing snapshots stop matching a forget filter
  # if the tag set changes, and are then never pruned.
  bgb_argv_has_pair --tag "legacy-stopped" "${argv[@]}"
}

# -----------------------------------------------------------------------------
# Flags and sources
# -----------------------------------------------------------------------------

@test "one-file-system and exclude-caches are emitted when enabled" {
  local out
  out="$(_backup_argv docker run-1)"
  [[ "${out}" == *"--one-file-system"* ]]
  [[ "${out}" == *"--exclude-caches"* ]]
}

@test "one-file-system is omitted when disabled" {
  JOB_ONE_FILE_SYSTEM=0
  local out
  out="$(_backup_argv docker run-1)"
  [[ "${out}" != *"--one-file-system"* ]]
}

@test "sources appear last so restic does not read them as flag values" {
  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args docker run-1)
  local last="${argv[${#argv[@]}-1]}"
  [ "${last}" = "/etc" ]
}

@test "extra paths are included" {
  JOB_EXTRA_PATHS=( /var/lib/docker )
  local out
  out="$(_backup_argv docker run-1)"
  [[ "${out}" == *"/var/lib/docker"* ]]
}

@test "a path containing spaces survives as ONE argument" {
  # The reason the configuration uses bash arrays rather than a string.
  JOB_PATHS=( "/srv/my data" )
  local -a argv=()
  mapfile -t argv < <(restic_build_backup_args docker run-1)
  bgb_argv_has "/srv/my data" "${argv[@]}"
}

@test "an exclude file is referenced only when it is readable" {
  JOB_EXCLUDE_FILE="${BGB_TEST_TMP}/does-not-exist.exclude"
  local out
  out="$(_backup_argv docker run-1)"
  [[ "${out}" != *"--exclude-file"* ]]

  printf '/tmp\n' >"${BGB_TEST_TMP}/real.exclude"
  JOB_EXCLUDE_FILE="${BGB_TEST_TMP}/real.exclude"
  out="$(_backup_argv docker run-1)"
  [[ "${out}" == *"--exclude-file"* ]]
}

# -----------------------------------------------------------------------------
# Exit-code mapping
# -----------------------------------------------------------------------------

@test "restic exit codes map to the documented bg-backup codes" {
  restic_map_rc 0;  [ "$?" -eq 0 ]
  run restic_map_rc 3;  [ "$status" -eq 3 ]   # partial
  run restic_map_rc 10; [ "$status" -eq 6 ]   # no repository
  run restic_map_rc 11; [ "$status" -eq 6 ]   # locked
  run restic_map_rc 12; [ "$status" -eq 6 ]   # wrong password
  run restic_map_rc 1;  [ "$status" -eq 1 ]
  run restic_map_rc 99; [ "$status" -eq 1 ]
}

@test "each restic exit code has a human explanation" {
  local c
  for c in 0 1 3 10 11 12; do
    run restic_explain_rc "${c}"
    [ -n "$output" ]
  done
  run restic_explain_rc 12
  [[ "$output" == *"password"* ]] || [[ "$output" == *"key"* ]]
}

# -----------------------------------------------------------------------------
# Version gate
# -----------------------------------------------------------------------------

@test "version comparison handles the versions that matter" {
  run version_ge "0.19.1" "0.17.0"; [ "$status" -eq 0 ]
  run version_ge "0.17.0" "0.17.0"; [ "$status" -eq 0 ]
  run version_ge "0.16.4" "0.17.0"; [ "$status" -ne 0 ]   # Ubuntu 24.04
  run version_ge "0.12.1" "0.17.0"; [ "$status" -ne 0 ]   # Ubuntu 22.04
  run version_ge "1.0.0"  "0.17.0"; [ "$status" -eq 0 ]
}

@test "a version with a suffix still compares correctly" {
  run version_ge "0.19.1-dev" "0.17.0"
  [ "$status" -eq 0 ]
}
