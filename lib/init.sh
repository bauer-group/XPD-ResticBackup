#!/usr/bin/env bash
# =============================================================================
# bg-backup - init: get from "nothing" to "a verified first snapshot"
# =============================================================================
# Idempotent by construction:
#   * never re-initialises an existing repository
#   * never overwrites an existing repository key file (that would orphan every
#     snapshot ever taken, irreversibly)
#   * never enables a timer
#
# It refuses to finish until the operator confirms the recovery card has been
# stored somewhere other than this host. A repository whose passphrase exists in
# exactly one place, on the machine being backed up, is not a backup.
# =============================================================================

[ -n "${_BGB_INIT_SOURCED:-}" ] && return 0
_BGB_INIT_SOURCED=1

cmd_init() {
  local repo="" password_file="" generate=0 non_interactive=0 force=0
  local s3_key="" s3_secret="" s3_region="" profile="server"

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        repo="$2"
        shift 2
        ;;
      --repo=*)
        repo="${1#*=}"
        shift
        ;;
      --password-file)
        password_file="$2"
        shift 2
        ;;
      --password-file=*)
        password_file="${1#*=}"
        shift
        ;;
      --generate-password)
        generate=1
        shift
        ;;
      --s3-key)
        s3_key="$2"
        shift 2
        ;;
      --s3-key=*)
        s3_key="${1#*=}"
        shift
        ;;
      --s3-secret)
        s3_secret="$2"
        shift 2
        ;;
      --s3-secret=*)
        s3_secret="${1#*=}"
        shift
        ;;
      --s3-region)
        s3_region="$2"
        shift 2
        ;;
      --s3-region=*)
        s3_region="${1#*=}"
        shift
        ;;
      --profile)
        profile="$2"
        shift 2
        ;;
      --profile=*)
        profile="${1#*=}"
        shift
        ;;
      --non-interactive)
        non_interactive=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      -*)
        err "Unknown flag for init: $1"
        usage_init
        exit "${EX_USAGE}"
        ;;
      *) shift ;;
    esac
  done

  require_root
  config_load
  restic_require

  local envfile="${BGB_CONFDIR}/credentials/repo.env"
  local keyfile="${BGB_CONFDIR}/credentials/repo.key"

  install -d -m 0750 "${BGB_CONFDIR}"
  install -d -m 0700 "${BGB_CONFDIR}/credentials"
  install -d -m 0750 "${BGB_CONFDIR}/conf.d"

  # --- Already configured? --------------------------------------------------
  if [ -f "${envfile}" ] && [ "${force}" != "1" ]; then
    log "A repository is already configured at ${envfile}"
    repo_env_load
    if restic_repo_reachable; then
      log "It is reachable and the key works."
      log "Nothing to do. Use --force to reconfigure (the key file is still never overwritten)."
      init_print_next_steps
      return 0
    fi
    err "The configured repository is NOT reachable."
    err "Fix the credentials, or re-run with --force to reconfigure."
    return "${EX_REPO}"
  fi

  # --- Repository URL -------------------------------------------------------
  if [ -z "${repo}" ]; then
    [ "${non_interactive}" = "1" ] && die "${EX_USAGE}" "--non-interactive requires --repo"
    repo="$(init_ask_repository)"
  fi
  [ -n "${repo}" ] || die "${EX_USAGE}" "No repository URL given"

  # A shared bucket makes the prefix load-bearing: it is what keeps this host's
  # snapshots separable from every other host's, and what `forget --host` and
  # `doctor` both rely on.
  local host_fqdn
  host_fqdn="$(fqdn)"
  case "${repo}" in
    *"${host_fqdn}") : ;;
    *)
      warn "The repository path does not end with this host's FQDN (${host_fqdn})."
      warn "In a shared bucket, one repository per host is what keeps retention safe."
      warn "Suggested: ${repo%/}/${host_fqdn}"
      if [ "${non_interactive}" != "1" ]; then
        if confirm "Append /${host_fqdn} to the repository path?"; then
          repo="${repo%/}/${host_fqdn}"
        fi
      fi
      ;;
  esac

  # --- Passphrase -----------------------------------------------------------
  local passphrase=""
  if [ -f "${keyfile}" ]; then
    # This is the one thing init must never do. Replacing the key file while a
    # repository already exists makes every existing snapshot unreadable.
    log "Keeping the existing repository key at ${keyfile}"
  else
    if [ -n "${password_file}" ]; then
      [ -r "${password_file}" ] || die "${EX_PRECOND}" "Cannot read ${password_file}"
      passphrase="$(cat "${password_file}")"
    elif [ -n "${BGB_PASSWORD:-}" ]; then
      passphrase="${BGB_PASSWORD}"
    elif [ "${generate}" = "1" ] || [ "${non_interactive}" = "1" ]; then
      passphrase="$(init_generate_passphrase)"
      log "Generated a 32-character repository passphrase"
    else
      passphrase="$(init_ask_passphrase)"
    fi
    [ -n "${passphrase}" ] || die "${EX_USAGE}" "No repository passphrase"

    printf '%s' "${passphrase}" >"${keyfile}"
    chmod 0400 "${keyfile}"
    chown root:root "${keyfile}"
    redact_register "${passphrase}"
  fi

  # --- Backend credentials --------------------------------------------------
  case "${repo}" in
    s3:*)
      if [ -z "${s3_key}" ] && [ "${non_interactive}" != "1" ]; then
        printf 'S3 / MinIO access key id: ' >&2
        read -r s3_key
      fi
      if [ -z "${s3_secret}" ] && [ "${non_interactive}" != "1" ]; then
        printf 'S3 / MinIO secret access key: ' >&2
        stty -echo 2>/dev/null || true
        read -r s3_secret
        stty echo 2>/dev/null || true
        printf '\n' >&2
      fi
      [ -z "${s3_region}" ] && s3_region="us-east-1"
      ;;
  esac

  # --- Write the environment file -------------------------------------------
  init_write_env "${envfile}" "${repo}" "${keyfile}" "${s3_key}" "${s3_secret}" "${s3_region}"
  log "Wrote ${envfile}"

  # --- Connect --------------------------------------------------------------
  repo_env_load "${envfile}"

  log "Testing the repository connection"
  local rc=0
  restic_exec cat config >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    0) log "Repository exists and the key works" ;;
    12) die "${EX_REPO}" "The repository exists but this passphrase does not open it. Refusing to touch it." ;;
    *)
      log "Repository not found - initialising"
      restic_exec init || die "${EX_REPO}" "restic init failed. Check the URL, credentials and network."
      log "Repository initialised"
      ;;
  esac

  # --- Seed jobs ------------------------------------------------------------
  init_seed_jobs "${profile}"

  # --- Recovery key ---------------------------------------------------------
  # A second, independent key means a host compromise costs one `restic key
  # remove` rather than the repository.
  init_offer_recovery_key "${non_interactive}"

  # --- Recovery card --------------------------------------------------------
  init_print_recovery_card "${repo}"

  if [ "${non_interactive}" != "1" ]; then
    if confirm "Have you stored the recovery card in the team password manager?"; then
      install -d -m 0700 "${BGB_STATE_DIR}"
      printf 'acknowledged=%s\n' "$(now_iso)" >"${BGB_STATE_DIR}/card-ack"
      chmod 0600 "${BGB_STATE_DIR}/card-ack"
      log "Recorded the acknowledgement"
    else
      warn "Not acknowledged. 'bg-backup doctor' will keep reminding you."
      warn "If this passphrase is lost and exists nowhere else, every backup is"
      warn "permanently unreadable. There is no recovery path. None."
    fi
  fi

  init_print_next_steps
  return 0
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
init_generate_passphrase() {
  # 32 characters from a URL/shell-safe alphabet: it ends up in shell files,
  # documentation and occasionally a URL, and a quoting accident in any of those
  # is a worse failure than the entropy difference.
  # Endless producer into `head -c` - see lib/secrets.sh for why the status
  # has to be neutralised before pipefail turns it into a failure.
  { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null || true; } | head -c 32
}

init_ask_repository() {
  local kind url endpoint bucket
  cat >&2 <<'EOF'

Repository backend:
  1) S3 / MinIO      (the BAUER GROUP default)
  2) SFTP
  3) REST server     (supports --append-only, the strongest ransomware control)
  4) Local directory (useful for a first test, NOT a backup on its own)
EOF
  printf 'Choice [1]: ' >&2
  read -r kind
  case "${kind:-1}" in
    2) printf 'sftp:user@host:/path/%s' "$(fqdn)" ;;
    3)
      printf 'Base URL (https://backup.example.com/): ' >&2
      read -r endpoint
      printf 'rest:%s%s' "${endpoint%/}/" "$(fqdn)"
      ;;
    4) printf '/var/backups/restic/%s' "$(fqdn)" ;;
    *)
      printf 'S3 endpoint (e.g. https://eu-north1.s3.example.com): ' >&2
      read -r endpoint
      printf 'Bucket name: ' >&2
      read -r bucket
      printf 's3:%s/%s/%s' "${endpoint%/}" "${bucket}" "$(fqdn)"
      ;;
  esac
}

init_ask_passphrase() {
  local a b
  printf 'Repository passphrase (empty to generate a strong one): ' >&2
  stty -echo 2>/dev/null || true
  read -r a
  stty echo 2>/dev/null || true
  printf '\n' >&2
  if [ -z "${a}" ]; then
    init_generate_passphrase
    return 0
  fi
  printf 'Repeat: ' >&2
  stty -echo 2>/dev/null || true
  read -r b
  stty echo 2>/dev/null || true
  printf '\n' >&2
  if [ "${a}" != "${b}" ]; then
    err "The passphrases do not match"
    return 1
  fi
  if [ "${#a}" -lt 16 ]; then
    warn "That passphrase is shorter than 16 characters."
    warn "It is the only thing between an attacker with the ciphertext and your data."
  fi
  printf '%s' "${a}"
}

init_write_env() {
  local envfile="$1" repo="$2" keyfile="$3" key="$4" secret="$5" region="$6"
  {
    cat <<EOF
# =============================================================================
# bg-backup - primary repository credentials
# Generated by 'bg-backup init' on $(now_iso)
# =============================================================================
# Sourceable by hand during a disaster recovery:
#     source ${envfile} && restic snapshots
#
# The passphrase is NOT here. It lives in ${keyfile} (0400) and is reached via
# RESTIC_PASSWORD_FILE, so it is not inherited by the database dump commands and
# hooks that this environment IS inherited by.
# =============================================================================

export RESTIC_REPOSITORY='${repo}'
export RESTIC_PASSWORD_FILE='${keyfile}'
EOF
    if [ -n "${key}" ]; then
      cat <<EOF

export AWS_ACCESS_KEY_ID='${key}'
export AWS_SECRET_ACCESS_KEY='${secret}'
export AWS_DEFAULT_REGION='${region}'
EOF
    fi
    cat <<EOF

export RESTIC_COMPRESSION='auto'
export RESTIC_CACHE_DIR='${BGB_CACHE_DIR}'
EOF
  } >"${envfile}"
  chmod 0400 "${envfile}"
  chown root:root "${envfile}"
}

init_seed_jobs() {
  local profile="$1" src="${BGB_SHARE_DIR}/config/conf.d"
  local -a jobs=()
  case "${profile}" in
    minimal) jobs=(90-config) ;;
    server) jobs=(10-system 90-config) ;;
    docker) jobs=(10-system 20-docker 90-config) ;;
    *)
      warn "Unknown profile '${profile}', using 'server'"
      jobs=(10-system 90-config)
      ;;
  esac

  local base f target
  for base in "${jobs[@]}"; do
    f="${src}/${base}.conf.example"
    target="${BGB_CONFDIR}/conf.d/${base}.conf"
    [ -e "${f}" ] || continue
    if [ -e "${target}" ]; then
      debug "Job file already present: ${target}"
      continue
    fi
    install -m 0640 "${f}" "${target}"
    log "Seeded job: $(basename "${target}")"
  done

  # Excludes come from the payload, not from the operator's memory.
  local ex
  for ex in "${BGB_SHARE_DIR}"/excludes/*.exclude; do
    [ -e "${ex}" ] || continue
    [ -e "${BGB_CONFDIR}/excludes/$(basename "${ex}")" ] && continue
    install -d -m 0755 "${BGB_CONFDIR}/excludes"
    install -m 0644 "${ex}" "${BGB_CONFDIR}/excludes/$(basename "${ex}")"
  done
}

init_offer_recovery_key() {
  local non_interactive="$1"
  local existing
  existing="$(restic_capture key list --json 2>/dev/null | jq -r '.[]? | select(.username=="recovery") | .id' 2>/dev/null || true)"
  if [ -n "${existing}" ]; then
    debug "A recovery key already exists"
    return 0
  fi
  [ "${non_interactive}" = "1" ] && return 0

  cat >&2 <<'EOF'

A second, independent repository key is strongly recommended. Its passphrase is
never stored on this host, so if this machine is compromised you can remove the
host key without losing access to the repository.

EOF
  confirm "Create an independent recovery key now?" || return 0

  local pass
  pass="$(init_generate_passphrase)"
  local pf
  pf="$(tmp_file "newkey.XXXXXX")"
  printf '%s' "${pass}" >"${pf}"
  chmod 0400 "${pf}"

  if restic_exec key add --user recovery --host "$(fqdn)" --new-password-file "${pf}"; then
    redact_register "${pass}"
    printf '\n%sRECOVERY KEY PASSPHRASE - store this OFF this host, now:%s\n\n' "${C_BOLD}${C_YELLOW}" "${C_RESET}" >&2
    printf '    %s\n\n' "${pass}" >&2
    printf 'It is not written to disk anywhere on this machine.\n\n' >&2
    [ -t 0 ] && {
      printf 'Press Enter once it is stored. ' >&2
      read -r _
    }
  else
    warn "Could not add the recovery key (continuing)"
  fi
  rm -f "${pf}"
}

init_print_recovery_card() {
  local repo="$1"
  cat >&2 <<EOF

${C_BOLD}================ RECOVERY CARD - store off this host ================${C_RESET}

  Host              $(fqdn)
  Repository        ${repo}
  Repository ID     $(restic_repo_id 2>/dev/null || echo '<unavailable>')
  Passphrase        ${BGB_CONFDIR}/credentials/repo.key  (on THIS host only)
  Backend keys      ${BGB_CONFDIR}/credentials/repo.env  (on THIS host only)
  Created           $(now_iso)

  To recover with NO bg-backup at all, on any Linux machine:

      export RESTIC_REPOSITORY='${repo}'
      export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...
      restic snapshots
      restic restore latest --target /tmp/restore

${C_YELLOW}  If the passphrase is lost and exists nowhere else, every backup in this
  repository is permanently unreadable. There is no recovery path.${C_RESET}

  Run 'bg-backup config export' to produce the full encrypted recovery bundle
  and a printable one-page sheet.

${C_BOLD}=====================================================================${C_RESET}

EOF
}

init_print_next_steps() {
  cat >&2 <<'EOF'

Next steps:

  bg-backup discover                 see what this host actually has
  bg-backup backup --all             run a first backup by hand
  bg-backup snapshots                confirm it arrived
  bg-backup restore preview file --path /etc/hostname
                                     prove you can get something back
  bg-backup config export --out /root/bg-backup-recovery.age
                                     produce the recovery bundle
  bg-backup schedule sync && bg-backup schedule enable
                                     only now arm the timers

EOF
}
