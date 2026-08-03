#!/usr/bin/env bash
# =============================================================================
# bg-backup - systemd: generate units, reconcile them with conf.d
# =============================================================================
# The shipped units in share/systemd/ are deliberately GENERIC. Everything that
# depends on a job's configuration - the calendar expression, the I/O priority,
# the runtime cap, whether exit 3 counts as success - is written here as a
# drop-in or as a concrete per-job timer.
#
# Why not put it all in the templates?
#
#   * OnCalendar= cannot be parameterised by %i. A template timer has exactly
#     one schedule for every instance, so a per-job schedule needs a concrete
#     bg-backup@<job>.timer file. The SERVICE stays a template (nothing in it
#     varies per job that a drop-in cannot express); only the timer is generated.
#
#   * A drop-in is reviewable and removable. `systemctl cat bg-backup@system`
#     shows the shipped unit and every generated fragment with its origin, which
#     is a far better debugging story than a single file nobody can diff against
#     upstream.
#
# `sync` is a RECONCILIATION, not an "apply". It removes timers for jobs whose
# configuration file was deleted. Without that, deleting 20-docker.conf leaves
# bg-backup@docker.timer armed forever: it fires, bg-backup exits 4 ("unknown
# job"), the unit fails, and the operator gets an alert every night for a job
# they intentionally removed - the fastest way to teach a team to ignore backup
# alerts entirely.
# =============================================================================

[ -n "${_BGB_SYSTEMD_SOURCED:-}" ] && return 0
_BGB_SYSTEMD_SOURCED=1

# Overridable so tests can point the whole module at a scratch directory.
: "${BGB_SYSTEMD_DIR:=/etc/systemd/system}"
: "${BGB_BIN:=/usr/local/sbin/bg-backup}"

# Set to 1 by any helper that actually changed a file on disk. daemon-reload is
# expensive enough (it re-parses every unit on the host) that running it on a
# no-op sync is worth avoiding, and a sync that reports "nothing changed" is a
# useful signal in itself.
_BGB_SYSTEMD_CHANGED=0

# Timers this run generated or refreshed, so they can be re-armed after reload.
_BGB_SYSTEMD_TIMERS=()

# Outputs of systemd_priority_values(). Globals rather than a printed tuple:
# the caller needs three values and command substitution would fork twice per
# job for no benefit.
BGB_SYSTEMD_NICE=10
BGB_SYSTEMD_IOPRIO=7
BGB_SYSTEMD_PRIORITY="low"

# -----------------------------------------------------------------------------
# Naming
# -----------------------------------------------------------------------------

# systemd_unit_for_job <job> [service|timer]
#
# NOTE ON ESCAPING: the instance name is used raw, and ExecStart= in the shipped
# template uses %i (the instance as written), NOT %I. %I *unescapes* the
# instance, and unescaping turns '-' into '/': a job called "web-data" would
# reach the tool as "web/data" and every run would die with "unknown job". Job
# names are file names to begin with, so the only thing that needs guarding is
# the character set - see systemd_valid_job_name().
systemd_unit_for_job() {
  local job="$1" kind="${2:-service}"
  printf 'bg-backup@%s.%s' "${job}" "${kind}"
}

# systemd_valid_job_name <name>
# '/' is the one character systemd genuinely cannot carry in an instance name;
# everything outside the set below is refused as well, because a unit name with
# a space or a quote in it is a debugging trap nobody needs.
systemd_valid_job_name() {
  case "${1:-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# -----------------------------------------------------------------------------
# File helpers
# -----------------------------------------------------------------------------

systemd_available() { have systemctl; }

systemd_require() {
  have systemctl || die "${EX_PRECOND}" "systemctl not found - this host does not run systemd"
}

# _systemd_install_file <path> [mode] - install stdin at <path>, idempotently.
_systemd_install_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(tmp_file "unit.XXXXXX")"
  cat >"${tmp}"

  # Compare before writing. An unchanged mtime is what lets `schedule sync` run
  # from a config-management tool on every converge without re-arming timers.
  if [ -f "${path}" ] && cmp -s "${tmp}" "${path}"; then
    debug "unchanged: ${path}"
    rm -f "${tmp}"
    return 0
  fi

  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] would write ${path}"
    rm -f "${tmp}"
    _BGB_SYSTEMD_CHANGED=1
    return 0
  fi

  install -o root -g root -m "${mode}" "${tmp}" "${path}"
  rm -f "${tmp}"
  _BGB_SYSTEMD_CHANGED=1
  log "Wrote ${path}"
  return 0
}

# systemd_write_dropin <unit> <name.conf>   (content on stdin)
systemd_write_dropin() {
  local unit="$1" name="$2" dir
  dir="${BGB_SYSTEMD_DIR}/${unit}.d"
  if [ "${BGB_DRY_RUN}" != "1" ]; then
    install -d -m 0755 "${dir}"
  fi
  _systemd_install_file "${dir}/${name}" 0644
}

systemd_remove_dropin() {
  local unit="$1" name="$2" f
  f="${BGB_SYSTEMD_DIR}/${unit}.d/${name}"
  [ -e "${f}" ] || return 0
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] would remove ${f}"
    return 0
  fi
  rm -f "${f}"
  rmdir "${BGB_SYSTEMD_DIR}/${unit}.d" 2>/dev/null || true
  _BGB_SYSTEMD_CHANGED=1
  log "Removed ${f}"
  return 0
}

systemd_remove_file() {
  local f="$1"
  [ -e "${f}" ] || return 0
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] would remove ${f}"
    return 0
  fi
  rm -f "${f}"
  _BGB_SYSTEMD_CHANGED=1
  log "Removed ${f}"
  return 0
}

systemd_remove_dir() {
  local d="$1"
  [ -d "${d}" ] || return 0
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] would remove ${d}"
    return 0
  fi
  rm -rf "${d}"
  _BGB_SYSTEMD_CHANGED=1
  log "Removed ${d}"
  return 0
}

systemd_enable_unit() {
  local unit="$1"
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] systemctl enable --now ${unit}"
    return 0
  fi
  # --now on a TIMER only arms it. It does not start the backup, which is why
  # `schedule enable` is safe to run at 14:00 on a production host.
  if systemctl enable --now "${unit}" >/dev/null 2>&1; then
    ok_mark "${unit}"
    return 0
  fi
  bad_mark "${unit} (see: systemctl status ${unit})"
  return 1
}

systemd_disable_unit() {
  local unit="$1"
  have systemctl || return 0
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] systemctl disable --now ${unit}"
    return 0
  fi
  # Disabling a TIMER never touches a backup that is currently running: the
  # service is a separate unit and systemd will not stop it from here. That is
  # deliberate - `schedule disable` must not be able to abort a running backup
  # halfway through and leave Docker paused.
  systemctl disable --now "${unit}" >/dev/null 2>&1 || true
  return 0
}

systemd_daemon_reload() {
  if [ "${_BGB_SYSTEMD_CHANGED}" -ne 1 ]; then
    debug "No unit changed - skipping daemon-reload"
    return 0
  fi
  if [ "${BGB_DRY_RUN}" = "1" ]; then
    log "[dry-run] systemctl daemon-reload"
    return 0
  fi
  have systemctl || return 0
  systemctl daemon-reload || warn "systemctl daemon-reload failed"

  # Re-arm timers we rewrote. daemon-reload re-reads the unit, but restarting
  # an already-running timer is the only way to be certain a changed OnCalendar
  # takes effect immediately instead of at the next boot. It is cheap, and the
  # Persistent= bookkeeping lives in /var/lib/systemd/timers, so restarting does
  # not make systemd forget a missed run.
  local t
  for t in "${_BGB_SYSTEMD_TIMERS[@]:-}"; do
    [ -n "${t}" ] || continue
    if systemctl is-active --quiet "${t}" 2>/dev/null; then
      systemctl restart "${t}" >/dev/null 2>&1 || warn "Could not restart ${t}"
    fi
  done
  return 0
}

# -----------------------------------------------------------------------------
# Resource policy
# -----------------------------------------------------------------------------
# systemd_priority_values <JOB_PRIORITY> [JOB_QUIESCE]
#
# Sets BGB_SYSTEMD_NICE / BGB_SYSTEMD_IOPRIO / BGB_SYSTEMD_PRIORITY.
#
# The I/O class is ALWAYS best-effort (2), never idle (3). IOSchedulingClass=idle
# reads exactly like the right answer for a backup and is a trap: on a host with
# any sustained foreground I/O the idle class can be starved indefinitely, so a
# 40-minute backup turns into a 9-hour one, the next timer fires while it is
# still running, and the job lock (exit 5) starts eating nights. A niced
# best-effort job yields to production without ever being locked out.
#
# The second rule is bigger: a job that holds a service down is NEVER throttled.
# JOB_QUIESCE=docker-stop/docker-pause/service-stop means containers are paused
# or units are stopped for the duration of the read. Throttling that job trades
# host responsiveness for outage length - a 2-minute quiesce window becomes 30
# minutes of downtime, which is the opposite of what "low priority" was meant to
# buy. Such jobs are floored at "normal" whatever the config says.
systemd_priority_values() {
  local prio="${1:-low}" quiesce="${2:-none}"

  case "${quiesce}" in
    docker-pause | docker-stop | service-stop)
      if [ "${prio}" = "low" ]; then
        debug "Raising priority low -> normal: JOB_QUIESCE=${quiesce} holds a service down"
        prio="normal"
      fi
      ;;
  esac

  case "${prio}" in
    high)
      BGB_SYSTEMD_NICE=0
      BGB_SYSTEMD_IOPRIO=0
      ;;
    normal)
      BGB_SYSTEMD_NICE=5
      BGB_SYSTEMD_IOPRIO=4
      ;;
    *)
      prio="low"
      BGB_SYSTEMD_NICE=10
      BGB_SYSTEMD_IOPRIO=7
      ;;
  esac
  BGB_SYSTEMD_PRIORITY="${prio}"
  return 0
}

# -----------------------------------------------------------------------------
# Credentials
# -----------------------------------------------------------------------------
# The shipped units declare LoadCredential= for the files that must exist on any
# working installation. This drop-in narrows that list to the files that ACTUALLY
# exist, and adds the optional ones.
#
# Two traps are being avoided at once:
#
#   1. LoadCredential= with a missing source makes the unit fail to START. An
#      optional notify.env in the shipped unit would break every host that does
#      not use one, with an error that says nothing about notifications.
#   2. Drop-ins APPEND to list options. Without the empty `LoadCredential=`
#      reset below, this fragment would add a second copy of every entry rather
#      than replacing the shipped list, and the missing-file problem would
#      survive the fix meant to solve it.
systemd_credential_dropin() {
  local unit="$1"
  shift
  local -a pairs=("$@") # "id:path" entries
  local pair path content

  # Built as a string and fed in with a here-string rather than a pipeline.
  # The right-hand side of a pipeline runs in a SUBSHELL, so
  # `{ ... } | systemd_write_dropin` would set _BGB_SYSTEMD_CHANGED in a child
  # process and throw it away - the file would be written and daemon-reload
  # would then be skipped as "nothing changed".
  content=''
  content+='# Generated by `bg-backup schedule sync` - do not edit.'$'\n'
  content+='#'$'\n'
  content+='# LoadCredential=, never EnvironmentFile=. EnvironmentFile would merge every'$'\n'
  content+='# value of repo.env into the unit environment, and `systemctl show -p'$'\n'
  content+='# Environment bg-backup@<job>.service` renders that environment for ANY'$'\n'
  content+='# local user - no root required. The S3 secret would be one unprivileged'$'\n'
  content+='# command away. LoadCredential puts the same file into a per-invocation,'$'\n'
  content+='# root-only ramfs under $CREDENTIALS_DIRECTORY that systemctl never renders.'$'\n'
  content+='#'$'\n'
  content+='# Only files that exist are listed: LoadCredential= with a missing source'$'\n'
  content+='# makes the unit fail to START, and the list is reset first because drop-ins'$'\n'
  content+='# APPEND to list options.'$'\n'
  content+='[Service]'$'\n'
  content+='LoadCredential='$'\n'

  for pair in "${pairs[@]:-}"; do
    [ -n "${pair}" ] || continue
    path="${pair#*:}"
    [ -n "${path}" ] && [ -f "${path}" ] || continue
    content+="LoadCredential=${pair}"$'\n'
  done

  systemd_write_dropin "${unit}" "10-credentials.conf" <<<"${content}"
}

# -----------------------------------------------------------------------------
# Per-job units
# -----------------------------------------------------------------------------
# Expects config_load_job() to have already populated JOB_* for this job.
systemd_job_units() {
  local job="$1"
  local service timer desc source_file partial timeout schedule
  service="$(systemd_unit_for_job "${job}" service)"
  timer="$(systemd_unit_for_job "${job}" timer)"
  source_file="${BGB_JOB_FILE:-${BGB_CONFDIR}/conf.d/${job}.conf}"

  systemd_priority_values "${JOB_PRIORITY}" "${JOB_QUIESCE}"

  desc="${JOB_DESCRIPTION:-backup job ${job}}"
  desc="${desc//$'\n'/ }"

  timeout="${JOB_TIMEOUT:-infinity}"
  [ -n "${timeout}" ] || timeout="infinity"

  # Exit 3 means "snapshot created, some source files were unreadable". Whether
  # that is a failure is a property of the JOB, not of the tool: on a live root
  # filesystem it is rotating logs and sockets, and marking the unit failed for
  # it produces a nightly alert nobody can act on. On a quiesced job it means
  # files were unreadable WITH THE SERVICE STOPPED, which is a real finding.
  if [ "${JOB_PARTIAL_IS_FAILURE}" = "1" ]; then
    partial="# JOB_PARTIAL_IS_FAILURE=1 - exit 3 stays a unit failure and alerts."
  else
    partial="SuccessExitStatus=3"
  fi

  systemd_write_dropin "${service}" "10-job.conf" <<EOF
# Generated by \`bg-backup schedule sync\` from ${source_file} - do not edit.
# Change the job's configuration and run \`bg-backup schedule sync\` again;
# every sync overwrites this file.

[Unit]
Description=bg-backup job ${job} - ${desc}

[Service]
# JOB_PRIORITY=${BGB_SYSTEMD_PRIORITY} (JOB_QUIESCE=${JOB_QUIESCE}).
# best-effort, never idle: an idle-class backup can be starved indefinitely on a
# busy host, and the next timer then collides with the still-running previous run.
Nice=${BGB_SYSTEMD_NICE}
IOSchedulingClass=best-effort
IOSchedulingPriority=${BGB_SYSTEMD_IOPRIO}

# JOB_TIMEOUT. A hung run holds the repository lock and blocks every other job
# on this host, so an upper bound is worth the risk of killing a slow one. The
# kill path is safe: SIGTERM reaches the tool's signal trap, and ExecStopPost=
# undoes the quiesce even if the trap never gets to run.
RuntimeMaxSec=${timeout}

${partial}
EOF

  # --- timer ------------------------------------------------------------------
  if [ "${JOB_ENABLED}" != "1" ]; then
    debug "${job}: JOB_ENABLED=0 - no timer"
    systemd_disable_unit "${timer}"
    systemd_remove_file "${BGB_SYSTEMD_DIR}/${timer}"
    return 0
  fi

  schedule="${JOB_SCHEDULE:-}"
  if [ -z "${schedule}" ]; then
    debug "${job}: no JOB_SCHEDULE - manual runs only"
    systemd_disable_unit "${timer}"
    systemd_remove_file "${BGB_SYSTEMD_DIR}/${timer}"
    return 0
  fi

  # config_validate_job() already ran systemd-analyze over JOB_SCHEDULE; this is
  # the second line of defence for a host where systemd-analyze is unavailable
  # at validation time but systemd is running.
  if have systemd-analyze && ! systemd-analyze calendar "${schedule}" >/dev/null 2>&1; then
    err "${job}: JOB_SCHEDULE is not a valid OnCalendar expression: ${schedule}"
    err "Refusing to write a timer that would silently never fire."
    return "${EX_PRECOND}"
  fi

  _systemd_install_file "${BGB_SYSTEMD_DIR}/${timer}" 0644 <<EOF
# Generated by \`bg-backup schedule sync\` from ${source_file} - do not edit.
#
# This is a CONCRETE unit for one instance of the bg-backup@.service template.
# It exists because OnCalendar= cannot be parameterised by %i: a template timer
# carries one schedule for every job. A concrete bg-backup@${job}.timer takes
# precedence over the shipped bg-backup@.timer template, so the service stays a
# template while the schedule stays per job.

[Unit]
Description=bg-backup timer for job ${job} - ${desc}
Documentation=https://github.com/bauer-group/XPD-ResticBackup

[Timer]
Unit=${service}
OnCalendar=${schedule}

# Fleet-wide de-synchronisation. Without it every host with the same
# configuration hits the same S3 endpoint on the same second.
RandomizedDelaySec=${JOB_RANDOM_DELAY:-900}

# Run a missed backup after the host comes back up. This is what makes
# Restart=no safe in the service: a laptop, a maintenance window or a reboot
# does not silently cost a night.
Persistent=true

# The default accuracy is 1 min already; stating it keeps systemd from batching
# this timer with unrelated ones into a wider window.
AccuracySec=60

[Install]
WantedBy=timers.target
EOF

  _BGB_SYSTEMD_TIMERS+=("${timer}")
  return 0
}

# -----------------------------------------------------------------------------
# Maintenance timers
# -----------------------------------------------------------------------------
# The shipped bg-backup-<name>.timer files carry the same defaults as
# config_defaults(); this rewrites them from the live configuration.
_systemd_maint_timer() {
  local name="$1" schedule="$2" delay="${3:-1800}"
  local unit="bg-backup-${name}.timer"

  if [ -z "${schedule}" ]; then
    debug "${name}: no schedule configured - timer stays disabled"
    systemd_disable_unit "${unit}"
    systemd_remove_dropin "${unit}" "10-schedule.conf"
    return 0
  fi

  if have systemd-analyze && ! systemd-analyze calendar "${schedule}" >/dev/null 2>&1; then
    err "${name}: not a valid OnCalendar expression: ${schedule}"
    return "${EX_PRECOND}"
  fi

  systemd_write_dropin "${unit}" "10-schedule.conf" <<EOF
# Generated by \`bg-backup schedule sync\` - do not edit.
#
# OnCalendar= is reset before being set: drop-ins APPEND to list options, and a
# timer with two OnCalendar= entries fires on BOTH. Changing the schedule
# without the reset would add a run rather than move one.
[Timer]
OnCalendar=
OnCalendar=${schedule}
RandomizedDelaySec=${delay}
EOF

  _BGB_SYSTEMD_TIMERS+=("${unit}")
  return 0
}

# The prune marker. Only a "primary" host may prune: prune rewrites pack files,
# and two hosts pruning the same bucket concurrently can remove data out from
# under each other. ConditionPathExists= makes a secondary SKIP the unit (which
# systemd records as "condition failed", not as a failure), so a secondary never
# alerts about a maintenance job it is not supposed to run.
systemd_prune_marker() {
  local marker="${BGB_CONFDIR}/.prune-allowed"

  if [ "${BGB_REPO_ROLE}" = "primary" ]; then
    if [ ! -f "${marker}" ]; then
      if [ "${BGB_DRY_RUN}" = "1" ]; then
        log "[dry-run] would create ${marker}"
      else
        printf '%s\n' \
          "# Written by \`bg-backup schedule sync\` because BGB_REPO_ROLE=primary." \
          "# bg-backup-prune.service refuses to start without this file." \
          "# Delete it (or set BGB_REPO_ROLE=secondary and re-sync) to stop pruning." \
          | atomic_write "${marker}" 0644
        log "Created ${marker} (BGB_REPO_ROLE=primary)"
      fi
    fi
  else
    if [ -f "${marker}" ]; then
      warn "BGB_REPO_ROLE=${BGB_REPO_ROLE} - removing ${marker}; this host will not prune"
      [ "${BGB_DRY_RUN}" = "1" ] || rm -f "${marker}"
    fi
  fi

  # The shipped unit hard-codes /etc/bg-backup/.prune-allowed. A host using a
  # non-default BGB_CONFDIR would otherwise never satisfy the condition and its
  # prune timer would silently do nothing for years.
  if [ "${BGB_CONFDIR}" != "/etc/bg-backup" ]; then
    systemd_write_dropin "bg-backup-prune.service" "10-confdir.conf" <<EOF
# Generated by \`bg-backup schedule sync\` - do not edit.
# BGB_CONFDIR is not the default, so the shipped ConditionPathExists= would
# never match. Conditions are a list option: reset before setting.
[Unit]
ConditionPathExists=
ConditionPathExists=${marker}
EOF
  else
    systemd_remove_dropin "bg-backup-prune.service" "10-confdir.conf"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Orphan removal
# -----------------------------------------------------------------------------
_systemd_known_job() {
  local want="$1"
  shift
  local j
  for j in "$@"; do
    [ "${j}" = "${want}" ] && return 0
  done
  return 1
}

# systemd_prune_orphans <job...> - remove units for jobs that no longer exist.
systemd_prune_orphans() {
  local -a known=("$@")
  local f base job

  for f in "${BGB_SYSTEMD_DIR}"/bg-backup@*.timer; do
    [ -e "${f}" ] || continue
    base="${f##*/}"
    job="${base#bg-backup@}"
    job="${job%.timer}"
    # The glob also matches the TEMPLATE, bg-backup@.timer, whose instance part
    # is empty. Deleting that would take the fallback unit with it and leave
    # every hand-typed `systemctl enable bg-backup@x.timer` failing with "unit
    # not found" - so an empty instance is never an orphan.
    [ -n "${job}" ] || continue
    _systemd_known_job "${job}" "${known[@]:-}" && continue

    warn "Orphaned timer for job '${job}' (its configuration file is gone) - removing"
    systemd_disable_unit "bg-backup@${job}.timer"
    systemd_remove_file "${f}"
    systemd_remove_dir "${BGB_SYSTEMD_DIR}/bg-backup@${job}.service.d"
  done

  # Drop-in directories can outlive their timer (a job with no JOB_SCHEDULE has
  # a drop-in and no timer), so they need their own sweep.
  for f in "${BGB_SYSTEMD_DIR}"/bg-backup@*.service.d; do
    [ -d "${f}" ] || continue
    base="${f##*/}"
    job="${base#bg-backup@}"
    job="${job%.service.d}"
    [ -n "${job}" ] || continue
    _systemd_known_job "${job}" "${known[@]:-}" && continue
    warn "Orphaned drop-in for job '${job}' - removing"
    systemd_remove_dir "${f}"
  done
  return 0
}

# -----------------------------------------------------------------------------
# Reconciliation
# -----------------------------------------------------------------------------
# Returns 0 when everything reconciled, EX_PRECOND when some part was skipped.
# It deliberately does NOT die(): config_cmd_edit() calls it as
# `systemd_sync || warn ...`, and a die() there would take the editor session's
# process with it after the file was already installed.
systemd_sync() {
  local rc=0 jrc=0 job
  local -a jobs=()

  if ! systemd_available; then
    warn "systemd is not present - nothing to synchronise"
    return 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    err "schedule sync must run as root (it writes ${BGB_SYSTEMD_DIR})"
    return "${EX_PRECOND}"
  fi

  config_load

  _BGB_SYSTEMD_CHANGED=0
  _BGB_SYSTEMD_TIMERS=()

  # --- credentials ------------------------------------------------------------
  local repo_key="${BGB_CONFDIR}/credentials/repo.key"
  local notify_env="${BGB_CONFDIR}/credentials/notify.env"
  local -a creds=(
    "repo.env:${BGB_REPO_ENV}"
    "repo.key:${repo_key}"
    "notify.env:${notify_env}"
  )
  local u
  for u in bg-backup@.service bg-backup-check.service bg-backup-prune.service \
    bg-backup-verify.service; do
    systemd_credential_dropin "${u}" "${creds[@]}"
  done

  # copy also needs the secondary repository's environment.
  local -a copy_creds=("${creds[@]}")
  if [ -n "${BGB_SECONDARY_REPO_ENV}" ]; then
    copy_creds+=("secondary.env:${BGB_SECONDARY_REPO_ENV}")
  fi
  systemd_credential_dropin "bg-backup-copy.service" "${copy_creds[@]}"

  # The failure notifier gets ONLY the notification credential. It must never
  # fail to start for want of a repository key: the whole reason it exists is to
  # report failures the in-process notifier could not.
  systemd_credential_dropin "bg-backup-failure@.service" "notify.env:${notify_env}"

  # --- jobs -------------------------------------------------------------------
  mapfile -t jobs < <(config_list_jobs)

  local -a valid=()
  for job in "${jobs[@]:-}"; do
    [ -n "${job}" ] || continue

    if ! systemd_valid_job_name "${job}"; then
      warn "Skipping '${job}': a systemd instance name cannot carry those characters"
      rc="${EX_PRECOND}"
      continue
    fi

    # Validate in a subshell first. config_load_job() calls die() on an invalid
    # file, and one broken job must not stop the other jobs' timers from being
    # reconciled - least of all the removal of an orphan. The second, real call
    # is what populates JOB_* in THIS shell; the subshell's assignments are
    # discarded with its process.
    if ! (config_load_job "${job}") >/dev/null 2>&1; then
      warn "Skipping '${job}': its configuration does not validate (bg-backup config validate)"
      rc="${EX_PRECOND}"
      continue
    fi
    config_load_job "${job}"

    valid+=("${job}")
    jrc=0
    systemd_job_units "${job}" || jrc=$?
    if [ "${jrc}" -ne 0 ]; then rc="${jrc}"; fi
  done

  # --- maintenance ------------------------------------------------------------
  systemd_prune_marker
  _systemd_maint_timer check "${BGB_CHECK_SCHEDULE}" "${BGB_MAINT_RANDOM_DELAY}" || rc="${EX_PRECOND}"
  _systemd_maint_timer prune "${BGB_PRUNE_SCHEDULE}" "${BGB_MAINT_RANDOM_DELAY}" || rc="${EX_PRECOND}"
  _systemd_maint_timer verify "${BGB_VERIFY_SCHEDULE}" "${BGB_MAINT_RANDOM_DELAY}" || rc="${EX_PRECOND}"
  _systemd_maint_timer copy "${BGB_COPY_SCHEDULE}" "${BGB_MAINT_RANDOM_DELAY}" || rc="${EX_PRECOND}"

  # --- orphans ----------------------------------------------------------------
  # Deliberately AFTER the job loop and using only the jobs that survived
  # validation... except that a job whose file merely fails to lint still EXISTS,
  # and removing its timer because of a typo would be a silent downgrade. Hence
  # the orphan list is built from the file names (jobs[]), not from valid[].
  systemd_prune_orphans "${jobs[@]:-}"

  systemd_daemon_reload

  if [ "${_BGB_SYSTEMD_CHANGED}" -eq 1 ]; then
    log "Units synchronised (${#valid[@]} job(s))"
  else
    log "Units already in sync (${#valid[@]} job(s))"
  fi
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Timer state
# -----------------------------------------------------------------------------
_systemd_usec_to_iso() {
  local usec="${1:-}" secs
  case "${usec}" in
    '' | 0 | infinity | n/a | *[!0-9]*)
      printf ''
      return 0
      ;;
  esac
  secs=$((usec / 1000000))
  [ "${secs}" -gt 0 ] || {
    printf ''
    return 0
  }
  date -u -d "@${secs}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
}

# systemd_timer_state <timer-unit>
# Emits: unit <TAB> enabled <TAB> active <TAB> next-run <TAB> last-run
systemd_timer_state() {
  local unit="$1" enabled active next last
  enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
  active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  [ -n "${enabled}" ] || enabled="not-found"
  [ -n "${active}" ] || active="unknown"
  next="$(_systemd_usec_to_iso "$(systemctl show "${unit}" -p NextElapseUSecRealtime --value 2>/dev/null || true)")"
  last="$(_systemd_usec_to_iso "$(systemctl show "${unit}" -p LastTriggerUSec --value 2>/dev/null || true)")"
  printf '%s\t%s\t%s\t%s\t%s\n' "${unit}" "${enabled}" "${active}" "${next:--}" "${last:--}"
}

# -----------------------------------------------------------------------------
# Command: schedule
# -----------------------------------------------------------------------------
schedule_usage() {
  cat <<'EOF'
bg-backup schedule - systemd timers for jobs and maintenance

USAGE
  bg-backup schedule sync                 Reconcile units with /etc/bg-backup/conf.d
  bg-backup schedule enable  [JOB...]     Arm timers (implies sync)
  bg-backup schedule disable [JOB...]     Disarm timers
  bg-backup schedule list    [--json]     What is armed, and when it next fires

BEHAVIOUR
  `sync` is a reconciliation. It writes a concrete bg-backup@<job>.timer for
  every job with a JOB_SCHEDULE, writes the per-job resource drop-in, and
  REMOVES timers and drop-ins for jobs whose configuration file was deleted.
  Without that removal a deleted job keeps firing and failing every night.

  Enabling or disabling a timer never starts or stops a backup: `--now` on a
  timer only arms or disarms it.

  Maintenance timers (check, prune, verify, copy) follow BGB_*_SCHEDULE. The
  prune timer additionally requires BGB_REPO_ROLE=primary - `sync` writes
  /etc/bg-backup/.prune-allowed only for a primary, and the unit refuses to
  start without it.
EOF
}

cmd_schedule() {
  local sub="${1:-list}"
  [ $# -gt 0 ] && shift
  case "${sub}" in
    sync) schedule_cmd_sync "$@" ;;
    enable) schedule_cmd_enable "$@" ;;
    disable) schedule_cmd_disable "$@" ;;
    list | status) schedule_cmd_list "$@" ;;
    help | --help | -h) schedule_usage ;;
    *)
      err "Unknown subcommand: schedule ${sub}"
      schedule_usage
      exit "${EX_USAGE}"
      ;;
  esac
}

schedule_cmd_sync() {
  require_root
  systemd_require
  local rc=0
  systemd_sync || rc=$?
  return "${rc}"
}

# _schedule_require_jobs <job...> - fail early on a typo.
#
# Kept OUT of _schedule_target_timers on purpose: that one is consumed through
# `mapfile < <(...)`, which runs it in a subshell, and a die() there would kill
# only the subshell. The parent would carry on with an empty timer list and
# report success for a job name that does not exist.
_schedule_require_jobs() {
  local job
  for job in "$@"; do
    [ -n "${job}" ] || continue
    config_job_file "${job}" >/dev/null 2>&1 \
      || die "${EX_PRECOND}" "Unknown job: ${job} (see: bg-backup config show)"
  done
  return 0
}

# _schedule_target_timers <job...> - the timers a given argument list refers to.
# With no arguments: every job that has a schedule, plus the maintenance timers
# the configuration actually asks for.
_schedule_target_timers() {
  local -a want=("$@")
  local -a jobs=()
  local job

  if [ "${#want[@]}" -gt 0 ] && [ -n "${want[0]:-}" ]; then
    for job in "${want[@]}"; do
      [ -n "${job}" ] || continue
      printf '%s\n' "$(systemd_unit_for_job "${job}" timer)"
    done
    return 0
  fi

  mapfile -t jobs < <(config_list_jobs)
  for job in "${jobs[@]:-}"; do
    [ -n "${job}" ] || continue
    [ -f "${BGB_SYSTEMD_DIR}/$(systemd_unit_for_job "${job}" timer)" ] || continue
    printf '%s\n' "$(systemd_unit_for_job "${job}" timer)"
  done

  [ -n "${BGB_CHECK_SCHEDULE}" ] && printf 'bg-backup-check.timer\n'
  [ -n "${BGB_VERIFY_SCHEDULE}" ] && printf 'bg-backup-verify.timer\n'
  # prune only where it is allowed, copy only where there is a second repository
  if [ -n "${BGB_PRUNE_SCHEDULE}" ] && [ "${BGB_REPO_ROLE}" = "primary" ]; then
    printf 'bg-backup-prune.timer\n'
  fi
  if [ -n "${BGB_COPY_SCHEDULE}" ] && [ -n "${BGB_SECONDARY_REPO_ENV}" ]; then
    printf 'bg-backup-copy.timer\n'
  fi
  return 0
}

schedule_cmd_enable() {
  require_root
  systemd_require
  config_load
  _schedule_require_jobs "$@"

  # Sync first, always. Enabling a timer that was generated from a configuration
  # three edits ago is how a host ends up backing up at the old time, or not at
  # all because the timer file was never written.
  local rc=0
  systemd_sync || rc=$?
  if [ "${rc}" -ne 0 ]; then
    warn "Continuing with the units that did synchronise"
  fi

  local -a timers=()
  mapfile -t timers < <(_schedule_target_timers "$@")

  if [ "${#timers[@]}" -eq 0 ] || [ -z "${timers[0]:-}" ]; then
    warn "No timer to enable - no job has a JOB_SCHEDULE and no maintenance schedule is set"
    return 0
  fi

  local t frc=0
  for t in "${timers[@]}"; do
    [ -n "${t}" ] || continue
    systemd_enable_unit "${t}" || frc="${EX_FAIL}"
  done
  [ "${frc}" -eq 0 ] || rc="${frc}"

  log "Run 'bg-backup schedule list' to see when each timer next fires"
  return "${rc}"
}

schedule_cmd_disable() {
  require_root
  systemd_require
  config_load
  _schedule_require_jobs "$@"

  local -a timers=()
  mapfile -t timers < <(_schedule_target_timers "$@")

  local t
  for t in "${timers[@]:-}"; do
    [ -n "${t}" ] || continue
    systemd_disable_unit "${t}"
    ok_mark "disabled ${t}"
  done
  warn "Timers are disarmed. A backup that does not run produces no alert either -"
  warn "set BGB_MONITOR_KUMA_PUSH_URL so something still notices the silence."
  return 0
}

schedule_cmd_list() {
  config_load
  systemd_require

  local -a jobs=()
  local job timer line first=1
  mapfile -t jobs < <(config_list_jobs)

  if [ "${BGB_JSON}" = "1" ]; then
    local body="["
    for job in "${jobs[@]:-}"; do
      [ -n "${job}" ] || continue
      timer="$(systemd_unit_for_job "${job}" timer)"
      line="$(systemd_timer_state "${timer}")"
      [ "${first}" -eq 0 ] && body+=","
      body+="$(_schedule_json_row "${job}" "${line}")"
      first=0
    done
    for timer in bg-backup-check.timer bg-backup-prune.timer \
      bg-backup-verify.timer bg-backup-copy.timer; do
      line="$(systemd_timer_state "${timer}")"
      [ "${first}" -eq 0 ] && body+=","
      body+="$(_schedule_json_row "" "${line}")"
      first=0
    done
    body+="]"
    json_envelope ok "$(json_kvraw timers "${body}")"
    return 0
  fi

  printf '%s%-28s %-9s %-8s %-22s %s%s\n' \
    "${C_BOLD}" "UNIT" "ENABLED" "ACTIVE" "NEXT (UTC)" "SCHEDULE" "${C_RESET}"

  for job in "${jobs[@]:-}"; do
    [ -n "${job}" ] || continue
    timer="$(systemd_unit_for_job "${job}" timer)"
    if (config_load_job "${job}") >/dev/null 2>&1; then
      config_load_job "${job}"
      _schedule_print_row "${timer}" "${JOB_SCHEDULE:-<none>}"
    else
      _schedule_print_row "${timer}" "<invalid config>"
    fi
  done

  _schedule_print_row bg-backup-check.timer "${BGB_CHECK_SCHEDULE:-<none>}"
  _schedule_print_row bg-backup-prune.timer "${BGB_PRUNE_SCHEDULE:-<none>}"
  _schedule_print_row bg-backup-verify.timer "${BGB_VERIFY_SCHEDULE:-<none>}"
  _schedule_print_row bg-backup-copy.timer "${BGB_COPY_SCHEDULE:-<none>}"

  if [ "${BGB_REPO_ROLE}" != "primary" ] && [ -n "${BGB_PRUNE_SCHEDULE}" ]; then
    printf '\n'
    warn_mark "BGB_REPO_ROLE=${BGB_REPO_ROLE}: prune is inhibited on this host by design"
  fi
  return 0
}

_schedule_print_row() {
  local unit="$1" schedule="$2" line enabled active next
  line="$(systemd_timer_state "${unit}")"
  IFS=$'\t' read -r _ enabled active next _ <<<"${line}"
  printf '%-28s %-9s %-8s %-22s %s\n' \
    "${unit}" "${enabled}" "${active}" "${next}" "${schedule}"
}

_schedule_json_row() {
  local job="$1" line unit enabled active next last
  line="$2"
  IFS=$'\t' read -r unit enabled active next last <<<"${line}"
  printf '{'
  json_kv unit "${unit}"
  printf ','
  json_kv job "${job}"
  printf ','
  json_kv enabled "${enabled}"
  printf ','
  json_kv active "${active}"
  printf ','
  json_kv next_run "${next}"
  printf ','
  json_kv last_run "${last}"
  printf '}'
}
