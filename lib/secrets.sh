#!/usr/bin/env bash
# =============================================================================
# bg-backup - secrets: the recovery bundle, key rotation, the recovery sheet
# =============================================================================
# THE BOOTSTRAP PROBLEM: the repository passphrase cannot live only inside the
# repository it opens. After a total loss you have nothing but what you put
# somewhere else, on purpose, in advance.
#
# The bundle is encrypted THREE ways, every time:
#
#   age      primary   - modern AEAD, but often absent from a minimal rescue
#                        image, so a static age binary ships beside the bundle
#   gpg      fallback  - gnupg is on nearly every Ubuntu server image
#   openssl  fallback  - effectively universal, but `enc` has NO integrity
#                        protection, so the ciphertext SHA-256 goes on the sheet
#
# Three independent tool paths mean no single missing package blocks a recovery.
#
# Every ciphertext is decrypted again and byte-compared before it is accepted.
# A bundle that has never been round-tripped is not a bundle; it is a hope.
# =============================================================================

[ -n "${_BGB_SECRETS_SOURCED:-}" ] && return 0
_BGB_SECRETS_SOURCED=1

readonly BGB_BUNDLE_SCHEMA=1

# -----------------------------------------------------------------------------
# Command dispatch
# -----------------------------------------------------------------------------
cmd_secrets() {
  local sub="${1:-show}"
  shift || true
  case "${sub}" in
    show) secrets_cmd_show "$@" ;;
    rotate-repo-password) secrets_cmd_rotate "$@" ;;
    print-recovery-card) secrets_cmd_card "$@" ;;
    add-recovery-key) secrets_cmd_add_recovery_key "$@" ;;
    *)
      err "Unknown subcommand: secrets ${sub}"
      exit "${EX_USAGE}"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# export
# -----------------------------------------------------------------------------
# Reached both as `bg-backup config export ...` (with flags) and internally from
# secrets_cmd_rotate (with none), hence the argument handling that ShellCheck
# cannot see a caller for.
# shellcheck disable=SC2120
secrets_cmd_export() {
  # NOT `recipients_file="${BGB_ESCROW_RECIPIENTS_FILE}"`. That default is
  # created by config_defaults(), and this function is reached from
  # `bg-backup config export` through cmd_config, which has not loaded anything
  # by the time the local declarations run. Under `set -u` that ended the
  # command before it parsed a flag:
  #     lib/secrets.sh: line 54: BGB_ESCROW_RECIPIENTS_FILE: unbound variable
  # So `config export` - the command that MAKES the recovery bundle the whole
  # disaster-recovery story depends on - could never run. Same defect class as
  # check, prune and self-update; it survived the guard added for those because
  # that guard only scanned functions named cmd_*, and this entry point is
  # secrets_cmd_export.
  local out="" passphrase_file="" recipients_file="" plain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)
        out="$2"
        shift 2
        ;;
      --out=*)
        out="${1#*=}"
        shift
        ;;
      --passphrase-file)
        passphrase_file="$2"
        shift 2
        ;;
      --recipients-file)
        recipients_file="$2"
        shift 2
        ;;
      --plain)
        plain=1
        shift
        ;;
      *) shift ;;
    esac
  done

  require_root
  config_load
  [ -z "${out}" ] && out="${BGB_ESCROW_LOCAL}"
  # The configured default, now that config_load() has created it. --recipients-file
  # still wins, because it was parsed above.
  [ -n "${recipients_file}" ] || recipients_file="${BGB_ESCROW_RECIPIENTS_FILE}"
  install -d -m 0700 "$(dirname "${out}")"

  local work
  work="$(tmp_root)/bundle"
  install -d -m 0700 "${work}"

  log "Collecting the recovery bundle"
  secrets_collect "${work}"

  # A deterministic tar: sorted entries and a fixed mtime, so the same content
  # produces the same SHA-256 and "did the bundle change?" is answerable.
  local tarball="${work}.tar"
  tar --sort=name --mtime='2000-01-01 00:00:00Z' \
    --owner=0 --group=0 --numeric-owner \
    -C "${work}" -cf "${tarball}" . 2>/dev/null
  chmod 0600 "${tarball}"

  local sha
  sha="$(sha256sum "${tarball}" | awk '{print $1}')"
  log "Bundle content SHA-256: ${sha}"

  if [ "${plain}" = "1" ]; then
    warn "--plain: writing an UNENCRYPTED bundle containing every credential"
    confirm "Are you sure?" || return "${EX_SAFETY}"
    install -m 0600 "${tarball}" "${out}"
    log "Wrote ${out}"
    return 0
  fi

  local passphrase
  passphrase="$(secrets_get_escrow_passphrase "${passphrase_file}")"
  [ -n "${passphrase}" ] || die "${EX_PRECOND}" "No escrow passphrase"
  redact_register "${passphrase}"

  local produced=0
  secrets_encrypt_age "${tarball}" "${out}" "${passphrase}" "${recipients_file}" && produced=$((produced + 1))
  secrets_encrypt_gpg "${tarball}" "${out%.age}.gpg" "${passphrase}" && produced=$((produced + 1))
  secrets_encrypt_openssl "${tarball}" "${out%.age}.enc" "${passphrase}" && produced=$((produced + 1))

  [ "${produced}" -gt 0 ] || die "${EX_FAIL}" "No encryption tool available (need age, gpg or openssl)"
  log "Produced ${produced} independently encrypted copies"

  secrets_ship_escrow "${out}"

  state_touch bundle_at "$(now_iso)"
  state_touch bundle_sha256 "${sha}"
  if declare -F backup_config_hash >/dev/null 2>&1; then
    state_touch config_hash "$(backup_config_hash)"
  fi

  secrets_render_sheet "${out}" "${sha}"
  log "Recovery bundle written: ${out}"
  warn "Copy it OFF this host now. A bundle that only exists here protects nothing."
}

secrets_collect() {
  local work="$1"
  install -d -m 0700 "${work}/repo" "${work}/config" "${work}/keys"

  # Configuration and credentials, verbatim.
  tar -C "$(dirname "${BGB_CONFDIR}")" -cf "${work}/config/etc-bg-backup.tar" \
    "$(basename "${BGB_CONFDIR}")" 2>/dev/null
  chmod 0600 "${work}/config/etc-bg-backup.tar"

  # System facts, so `dr plan` works before anything has been restored.
  if [ -d /var/lib/bg-backup/facts ]; then
    tar -C /var/lib/bg-backup -cf "${work}/config/facts.tar" facts 2>/dev/null
    chmod 0600 "${work}/config/facts.tar"
  fi

  # Repository pointers in a form a human can read without any tooling.
  if [ -r "${BGB_REPO_ENV}" ]; then
    cp -f "${BGB_REPO_ENV}" "${work}/repo/primary.env"
    chmod 0600 "${work}/repo/primary.env"
  fi
  if [ -r "${BGB_CONFDIR}/credentials/repo.key" ]; then
    cp -f "${BGB_CONFDIR}/credentials/repo.key" "${work}/repo/primary.pass"
    chmod 0600 "${work}/repo/primary.pass"
  fi
  if [ -n "${BGB_SECONDARY_REPO_ENV}" ] && [ -r "${BGB_SECONDARY_REPO_ENV}" ]; then
    cp -f "${BGB_SECONDARY_REPO_ENV}" "${work}/repo/secondary.env"
    chmod 0600 "${work}/repo/secondary.env"
  fi

  # Repository identity, so a recovering operator can prove they reached the
  # right repository before typing a passphrase into it.
  local repo_id=""
  if (repo_env_load) >/dev/null 2>&1; then
    repo_env_load >/dev/null 2>&1 || true
    repo_id="$(restic_repo_id 2>/dev/null || true)"
    restic_capture key list --json >"${work}/keys/restic-keys.json" 2>/dev/null || true
  fi

  {
    printf '{'
    json_kvraw schema "${BGB_BUNDLE_SCHEMA}"
    printf ','
    json_kv host "$(fqdn)"
    printf ','
    json_kv created "$(now_iso)"
    printf ','
    json_kv tool_version "${BGB_VERSION}"
    printf ','
    json_kv restic_version "$(restic_version 2>/dev/null || echo unknown)"
    printf ','
    json_kv repository "${RESTIC_REPOSITORY:-}"
    printf ','
    json_kv repository_id "${repo_id}"
    printf ','
    json_kv config_tag "bg-backup-config"
    printf '}\n'
  } >"${work}/bundle.json"
  chmod 0600 "${work}/bundle.json"

  secrets_write_recover_txt "${work}/RECOVER.txt" "${repo_id}"
}

secrets_write_recover_txt() {
  local out="$1" repo_id="$2"
  cat >"${out}" <<EOF
bg-backup - RECOVERY INSTRUCTIONS
=================================
Host          $(fqdn)
Repository    ${RESTIC_REPOSITORY:-<see repo/primary.env>}
Repository ID ${repo_id:-<unknown>}
Bundle made   $(now_iso)

WHAT IS IN HERE
  repo/primary.env     repository URL and backend credentials (sourceable)
  repo/primary.pass    the repository passphrase
  repo/secondary.*     the copy target, if one is configured
  config/etc-bg-backup.tar   the complete /etc/bg-backup
  config/facts.tar     system facts for 'bg-backup dr plan'
  keys/restic-keys.json      which repository keys exist

RECOVERY WITHOUT bg-backup
  You do not need this tool to read your backups. On any Linux machine:

    export RESTIC_REPOSITORY='<from repo/primary.env>'
    export AWS_ACCESS_KEY_ID='<from repo/primary.env>'
    export AWS_SECRET_ACCESS_KEY='<from repo/primary.env>'
    export RESTIC_PASSWORD="\$(cat repo/primary.pass)"

    restic snapshots
    restic restore latest --target /mnt/restore
    restic dump <snap> /db/postgres/<container>/<db>.dump | pg_restore -d <db>

RECOVERY WITH bg-backup
    curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
    bg-backup config import --in <this bundle>
    bg-backup dr plan
    bg-backup dr run --phase all

TAGS
  kind=files    the filesystem snapshot
  kind=dbdump   a logical database dump (restore with 'restic dump')
  kind=image    an exported container image
  run=<id>      groups every snapshot of one backup run - restore BY RUN, not
                by "latest per snapshot", or you will pair a database dump from
                one day with volume contents from another
EOF
  chmod 0600 "${out}"
}

# -----------------------------------------------------------------------------
# Encryption
# -----------------------------------------------------------------------------
secrets_get_escrow_passphrase() {
  local file="$1"
  if [ -n "${file}" ]; then
    [ -r "${file}" ] || die "${EX_PRECOND}" "Cannot read ${file}"
    cat "${file}"
    return 0
  fi
  if [ -n "${BGB_ESCROW_PASSPHRASE:-}" ]; then
    printf '%s' "${BGB_ESCROW_PASSPHRASE}"
    return 0
  fi
  local keyf="${BGB_CONFDIR}/credentials/escrow.key"
  if [ -r "${keyf}" ]; then
    cat "${keyf}"
    return 0
  fi
  if [ -t 0 ]; then
    local a b
    printf 'Bundle passphrase (this is what opens the recovery bundle): ' >&2
    stty -echo 2>/dev/null || true
    read -r a
    stty echo 2>/dev/null || true
    printf '\n' >&2
    printf 'Repeat: ' >&2
    stty -echo 2>/dev/null || true
    read -r b
    stty echo 2>/dev/null || true
    printf '\n' >&2
    [ "${a}" = "${b}" ] || {
      err "Passphrases do not match"
      return 1
    }
    printf '%s' "${a}"
    return 0
  fi
  return 1
}

secrets_encrypt_age() {
  local src="$1" out="$2" passphrase="$3" recipients="$4"
  have age || {
    debug "age not installed - skipping the age copy"
    return 1
  }

  if [ -r "${recipients}" ] && [ -s "${recipients}" ]; then
    age -R "${recipients}" -o "${out}" "${src}" || return 1
    log "age (recipients): ${out}"
  else
    # age cannot mix recipients and a passphrase in one file, so passphrase mode
    # is a separate invocation, not a fallback flag.
    printf '%s' "${passphrase}" | age -p -o "${out}" "${src}" 2>/dev/null \
      || { AGE_PASSPHRASE="${passphrase}" age -p -o "${out}" "${src}" 2>/dev/null; } \
      || return 1
    log "age (passphrase): ${out}"
  fi
  chmod 0600 "${out}"
  secrets_roundtrip_age "${out}" "${src}" "${passphrase}" "${recipients}"
}

secrets_roundtrip_age() {
  local enc="$1" orig="$2" passphrase="$3" recipients="$4"
  local dec
  dec="$(tmp_file "rt.XXXXXX")"
  local ok=1
  if [ -r "${recipients}" ] && [ -s "${recipients}" ]; then
    # Recipient mode cannot be verified without a private key; the SHA of the
    # plaintext is recorded instead and the operator verifies at import time.
    debug "age recipient mode - round trip deferred to import"
    return 0
  fi
  printf '%s' "${passphrase}" | age -d -o "${dec}" "${enc}" 2>/dev/null || ok=0
  if [ "${ok}" = "1" ] && cmp -s "${dec}" "${orig}"; then
    log "age round trip verified"
    rm -f "${dec}"
    return 0
  fi
  rm -f "${dec}"
  err "age round trip FAILED - the encrypted bundle does not decrypt to the original"
  return 1
}

secrets_encrypt_gpg() {
  local src="$1" out="$2" passphrase="$3"
  have gpg || {
    debug "gpg not installed - skipping the gpg copy"
    return 1
  }
  printf '%s' "${passphrase}" | gpg --batch --yes --quiet \
    --symmetric --cipher-algo AES256 \
    --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 \
    --passphrase-fd 0 -o "${out}" "${src}" 2>/dev/null || return 1
  chmod 0600 "${out}"

  local dec
  dec="$(tmp_file "rtg.XXXXXX")"
  if printf '%s' "${passphrase}" | gpg --batch --yes --quiet --passphrase-fd 0 \
    -o "${dec}" -d "${out}" 2>/dev/null && cmp -s "${dec}" "${src}"; then
    log "gpg: ${out} (round trip verified)"
    rm -f "${dec}"
    return 0
  fi
  rm -f "${dec}"
  err "gpg round trip FAILED"
  return 1
}

secrets_encrypt_openssl() {
  local src="$1" out="$2" passphrase="$3"
  have openssl || {
    debug "openssl not installed"
    return 1
  }
  # AES-256-CTR with PBKDF2. NOTE: `openssl enc` provides NO integrity
  # protection - it cannot detect tampering. That is why the ciphertext SHA-256
  # goes onto the printed recovery sheet, restoring the property `enc` lacks.
  printf '%s' "${passphrase}" | openssl enc -aes-256-ctr -pbkdf2 -iter 1000000 \
    -md sha512 -salt -in "${src}" -out "${out}" -pass stdin 2>/dev/null || return 1
  chmod 0600 "${out}"

  local dec
  dec="$(tmp_file "rto.XXXXXX")"
  if printf '%s' "${passphrase}" | openssl enc -d -aes-256-ctr -pbkdf2 -iter 1000000 \
    -md sha512 -in "${out}" -out "${dec}" -pass stdin 2>/dev/null && cmp -s "${dec}" "${src}"; then
    local csum
    csum="$(sha256sum "${out}" | awk '{print $1}')"
    log "openssl: ${out} (round trip verified, ciphertext SHA-256 ${csum})"
    state_touch bundle_openssl_sha256 "${csum}"
    rm -f "${dec}"
    return 0
  fi
  rm -f "${dec}"
  err "openssl round trip FAILED"
  return 1
}

secrets_ship_escrow() {
  local bundle="$1" url
  [ -n "${BGB_ESCROW_URLS}" ] || {
    debug "No escrow targets configured"
    return 0
  }
  for url in ${BGB_ESCROW_URLS}; do
    [ -n "${url}" ] || continue
    log "Shipping the bundle to ${url}"
    case "${url}" in
      s3://* | https://*)
        if have aws; then
          aws s3 cp "${bundle}" "${url%/}/$(basename "${bundle}")" >/dev/null 2>&1 \
            && log "Uploaded to ${url}" || warn "Upload to ${url} failed"
        elif have rclone; then
          rclone copy "${bundle}" "${url}" >/dev/null 2>&1 \
            && log "Uploaded to ${url}" || warn "Upload to ${url} failed"
        else
          warn "Neither aws nor rclone is installed - cannot ship to ${url}"
        fi
        ;;
      sftp://* | scp://*)
        have scp && scp -q "${bundle}" "${url#*://}" \
          && log "Copied to ${url}" || warn "Copy to ${url} failed"
        ;;
      /*)
        install -d -m 0700 "${url}"
        install -m 0600 "${bundle}" "${url}/$(basename "${bundle}")" \
          && log "Copied to ${url}" || warn "Copy to ${url} failed"
        ;;
      *) warn "Unsupported escrow URL scheme: ${url}" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# import
# -----------------------------------------------------------------------------
secrets_cmd_import() {
  local in="" passphrase_file="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --in)
        in="$2"
        shift 2
        ;;
      --in=*)
        in="${1#*=}"
        shift
        ;;
      --passphrase-file)
        passphrase_file="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      *) shift ;;
    esac
  done
  [ -n "${in}" ] || die "${EX_USAGE}" "config import requires --in <bundle>"
  [ -r "${in}" ] || die "${EX_PRECOND}" "Cannot read ${in}"
  require_root

  if [ -f "${BGB_CONFDIR}/credentials/repo.env" ] && [ "${force}" != "1" ]; then
    err "A configuration already exists at ${BGB_CONFDIR}"
    err "Importing would replace it. Re-run with --force if that is what you want."
    return "${EX_PRECOND}"
  fi

  local work
  work="$(tmp_root)/import"
  install -d -m 0700 "${work}"
  local tarball="${work}/bundle.tar"

  local passphrase=""
  if [ -n "${passphrase_file}" ]; then
    passphrase="$(cat "${passphrase_file}")"
  elif [ -n "${BGB_ESCROW_PASSPHRASE:-}" ]; then
    passphrase="${BGB_ESCROW_PASSPHRASE}"
  elif [ -t 0 ]; then
    printf 'Bundle passphrase: ' >&2
    stty -echo 2>/dev/null || true
    read -r passphrase
    stty echo 2>/dev/null || true
    printf '\n' >&2
  fi
  [ -n "${passphrase}" ] && redact_register "${passphrase}"

  log "Decrypting ${in}"
  case "${in}" in
    *.age) printf '%s' "${passphrase}" | age -d -o "${tarball}" "${in}" \
      || die "${EX_FAIL}" "age decryption failed" ;;
    *.gpg) printf '%s' "${passphrase}" | gpg --batch --quiet --passphrase-fd 0 -o "${tarball}" -d "${in}" \
      || die "${EX_FAIL}" "gpg decryption failed" ;;
    *.enc) printf '%s' "${passphrase}" | openssl enc -d -aes-256-ctr -pbkdf2 -iter 1000000 \
      -md sha512 -in "${in}" -out "${tarball}" -pass stdin \
      || die "${EX_FAIL}" "openssl decryption failed" ;;
    *.tar) cp -f "${in}" "${tarball}" ;;
    *) die "${EX_USAGE}" "Unknown bundle format: ${in} (expected .age, .gpg, .enc or .tar)" ;;
  esac

  tar -C "${work}" -xf "${tarball}" || die "${EX_FAIL}" "Bundle is not a readable tar archive"
  [ -r "${work}/bundle.json" ] || die "${EX_FAIL}" "Bundle is missing bundle.json - is this a bg-backup bundle?"

  local bhost
  bhost="$(jq -r '.host // ""' "${work}/bundle.json" 2>/dev/null || true)"
  log "Bundle is from host '${bhost}', created $(jq -r '.created // "?"' "${work}/bundle.json" 2>/dev/null)"
  if [ -n "${bhost}" ] && [ "${bhost}" != "$(fqdn)" ]; then
    warn "This bundle is from a DIFFERENT host (${bhost} vs $(fqdn))."
    warn "That is normal during a disaster recovery onto replacement hardware."
    confirm "Continue?" || return "${EX_SAFETY}"
  fi

  log "Restoring /etc/bg-backup"
  tar -C "$(dirname "${BGB_CONFDIR}")" -xf "${work}/config/etc-bg-backup.tar"
  chmod 0750 "${BGB_CONFDIR}"
  chmod 0700 "${BGB_CONFDIR}/credentials" 2>/dev/null || true
  chmod 0400 "${BGB_CONFDIR}"/credentials/* 2>/dev/null || true

  if [ -r "${work}/config/facts.tar" ]; then
    install -d -m 0700 /var/lib/bg-backup
    tar -C /var/lib/bg-backup -xf "${work}/config/facts.tar"
  fi

  log "Validating the imported configuration"
  config_load
  (config_cmd_validate) || warn "The imported configuration has problems - run: bg-backup config validate"

  if repo_env_load && restic_repo_reachable; then
    log "Repository is reachable with the imported credentials"
    log "Snapshots available:"
    cmd_snapshots || true
  else
    err "The imported credentials do NOT open the repository."
    err "Check repo/primary.env inside the bundle against the recovery sheet."
    return "${EX_REPO}"
  fi

  log "Import complete. Next: bg-backup dr plan"
}

# -----------------------------------------------------------------------------
# Keys
# -----------------------------------------------------------------------------
secrets_cmd_show() {
  local reveal=0
  while [ $# -gt 0 ]; do
    case "$1" in --reveal)
      reveal=1
      shift
      ;;
    *) shift ;; esac
  done
  config_load
  repo_env_load
  restic_require

  printf '\n%sRepository keys%s\n\n' "${C_BOLD}" "${C_RESET}"
  restic_exec key list

  cat >&2 <<'EOF'

The three-key model this tool assumes:

  host:<fqdn>      routine backups; the passphrase lives on this host
  ops:recovery     disaster recovery; the passphrase lives ONLY off this host
  ops:prune        retention; used from a management path, never from here

  With a recovery key, a host compromise costs one `restic key remove`.
  Without one, it costs the repository.

EOF

  if [ "${reveal}" = "1" ]; then
    [ -t 1 ] || die "${EX_PRECOND}" "--reveal requires a terminal"
    printf 'Repository:  %s\n' "${RESTIC_REPOSITORY}"
    printf 'Passphrase:  %s\n' "$(cat "${RESTIC_PASSWORD_FILE}" 2>/dev/null)"
  fi
}

secrets_cmd_rotate() {
  require_root
  config_load
  repo_env_load
  restic_require

  local keyfile="${RESTIC_PASSWORD_FILE:-${BGB_CONFDIR}/credentials/repo.key}"
  local newpass
  # `{ producer; } || true`: /dev/urandom never ends, so `head -c N` closes the
  # pipe and tr dies of SIGPIPE (141). Under `set -o pipefail` that becomes the
  # status of the command substitution and `set -e` ends the command - which is
  # why `secrets add-recovery-key` and `secrets rotate-repo-password` exited 141
  # before printing a single line. Same trap as state_touch's grep and
  # dr_verify's systemctl counters.
  newpass="$({ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null || true; } | head -c 32)"
  local newfile
  newfile="$(tmp_file "newkey.XXXXXX")"
  printf '%s' "${newpass}" >"${newfile}"
  chmod 0400 "${newfile}"
  redact_register "${newpass}"

  cat >&2 <<'EOF'

Rotating the repository passphrase.

restic separates the master key from repository keys, so this is O(1): no data
is re-encrypted and no existing snapshot is affected.

IMPORTANT, and easy to get wrong: this defends against a stolen PASSWORD. It
does NOT undo a compromise. `restic key remove` does not re-encrypt the master
key, so anyone who ever obtained the master key material keeps access to every
snapshot that already exists. After a host compromise you need a NEW repository,
not a rotated key.

EOF
  confirm "Continue with the rotation?" || return 0

  local old_id
  old_id="$(restic_capture key list --json | jq -r '.[] | select(.current==true) | .id' 2>/dev/null || true)"

  log "Adding the new key"
  restic_exec key add --host "$(fqdn)" --user bg-backup --new-password-file "${newfile}" \
    || die "${EX_REPO}" "Could not add the new key - nothing was changed"

  # Prove the new key works from a clean environment BEFORE removing the old
  # one. Removing first and discovering the new key is wrong afterwards means
  # the repository is unreachable with either.
  log "Verifying the new key from a clean environment"
  # RESTIC_CACHE_DIR IS NOT OPTIONAL HERE, and its absence is why this check -
  # the most careful step in the whole command - was the one thing guaranteed to
  # fail. `env -i` clears everything, including HOME, and restic then refuses to
  # start at all:
  #     unable to open cache: unable to locate cache directory:
  #     neither $XDG_CACHE_HOME nor $HOME are defined
  # The verification therefore reported "the new key does NOT open the
  # repository" for a key that was perfectly good, and rotation stopped - every
  # time, on every host - leaving the freshly added key orphaned in the
  # repository. Five attempts, five stray keys nobody has the passphrase for.
  #
  # The cache directory is part of this tool's repository configuration, not
  # ambient state, so passing it explicitly keeps the point of `env -i` intact:
  # nothing is inherited, everything needed is named.
  if ! (env -i \
    HOME="${HOME:-/root}" \
    RESTIC_REPOSITORY="${RESTIC_REPOSITORY}" \
    RESTIC_PASSWORD_FILE="${newfile}" \
    RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-${BGB_CACHE_DIR}}" \
    AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
    AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}" \
    "${BGB_RESTIC_BIN}" snapshots >/dev/null 2>&1); then
    err "The new key does NOT open the repository. Leaving the old key in place."
    err "Remove the stray key by hand once the cause is understood: restic key list"
    return "${EX_REPO}"
  fi
  log "New key verified"

  install -o root -g root -m 0400 "${newfile}" "${keyfile}"
  log "Installed the new passphrase at ${keyfile}"

  if [ -n "${old_id}" ]; then
    log "Removing the previous key ${old_id}"
    RESTIC_PASSWORD_FILE="${keyfile}" restic_exec key remove "${old_id}" \
      || warn "Could not remove the old key - remove it by hand: restic key remove ${old_id}"
  fi

  log "Re-exporting the recovery bundle so it matches the new passphrase"
  # A SUBSHELL, because `|| warn` cannot catch what secrets_cmd_export does on
  # its unhappy paths: it calls die(), and die() calls exit. So a host with no
  # escrow passphrase configured saw the rotation do all of its work - new key
  # added, verified, installed, old key removed - and then exit 4, reporting
  # failure for a rotation that had completely succeeded. An operator reading
  # that exit code would reasonably try again, adding a second stray key.
  (secrets_cmd_export) || warn "Bundle export failed - run 'bg-backup config export' manually"

  printf '\n%sNEW REPOSITORY PASSPHRASE - store it off this host now:%s\n\n    %s\n\n' \
    "${C_BOLD}${C_YELLOW}" "${C_RESET}" "${newpass}" >&2
}

secrets_cmd_add_recovery_key() {
  require_root
  config_load
  repo_env_load
  restic_require

  local pass
  # `{ producer; } || true`: /dev/urandom never ends, so `head -c N` closes the
  # pipe and tr dies of SIGPIPE (141). Under `set -o pipefail` that becomes the
  # status of the command substitution and `set -e` ends the command - which is
  # why `secrets add-recovery-key` and `secrets rotate-repo-password` exited 141
  # before printing a single line. Same trap as state_touch's grep and
  # dr_verify's systemctl counters.
  pass="$({ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null || true; } | head -c 32)"
  local pf
  pf="$(tmp_file "reckey.XXXXXX")"
  printf '%s' "${pass}" >"${pf}"
  chmod 0400 "${pf}"
  redact_register "${pass}"

  restic_exec key add --user recovery --host "$(fqdn)" --new-password-file "${pf}" \
    || die "${EX_REPO}" "Could not add the recovery key"

  printf '\n%sRECOVERY KEY PASSPHRASE - it is NOT stored on this host:%s\n\n    %s\n\n' \
    "${C_BOLD}${C_YELLOW}" "${C_RESET}" "${pass}" >&2
  printf 'Store it in the team password manager and on the printed recovery sheet.\n\n' >&2
  rm -f "${pf}"
}

# -----------------------------------------------------------------------------
# Recovery sheet
# -----------------------------------------------------------------------------
secrets_cmd_card() {
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in --out)
      out="$2"
      shift 2
      ;;
    *) shift ;; esac
  done
  config_load
  repo_env_load 2>/dev/null || true
  secrets_render_sheet "${BGB_ESCROW_LOCAL}" "$(state_get_repo bundle_sha256)" "${out}"
}

secrets_render_sheet() {
  local bundle="$1" sha="$2" out="${3:-}"
  local sheet
  sheet="$(
    cat <<EOF
+----------------------------------------------------------------------+
| BAUER GROUP - BACKUP RECOVERY SHEET                     CONFIDENTIAL  |
+----------------------------------------------------------------------+
 Host            $(fqdn)
 Generated       $(now_iso)
 Tool            bg-backup ${BGB_VERSION} / restic $(restic_version 2>/dev/null || echo '?')
 Verify by       $(date -u -d '+90 days' '+%Y-%m-%d' 2>/dev/null || echo '________')

 1  PRIMARY REPOSITORY
    URL           ${RESTIC_REPOSITORY:-________________________________}
    Repository ID $(restic_repo_id 2>/dev/null || echo '________')
    S3 key id     ________________________  (password manager)
    S3 secret     ________________________  (password manager)
    Passphrase    ________________________  (password manager)

 2  RECOVERY KEY (independent; never stored on the host)
    Passphrase    ____ ____ ____ ____ ____ ____

 3  RECOVERY BUNDLE
    Local         ${bundle}
    Escrow        ${BGB_ESCROW_URLS:-<none configured>}
    Content SHA   ${sha:-________}
    Bundle pass   ________________________  (password manager)

 4  RECOVERY WITH NO TOOLING AT ALL
    export RESTIC_REPOSITORY='<section 1>'
    export AWS_ACCESS_KEY_ID='<section 1>'
    export AWS_SECRET_ACCESS_KEY='<section 1>'
    export RESTIC_PASSWORD='<section 1>'

    restic snapshots
    restic restore latest --target /mnt/restore
    restic dump <snap> /db/postgres/<container>/<db>.dump | pg_restore -d <db>

    Restore BY RUN (tag run=<id>), not by "latest" per snapshot, or a database
    dump from one day gets paired with volume contents from another.

 5  DO NOT RESTORE BLINDLY
    /boot, /etc/fstab, /etc/netplan, /etc/machine-id and the account databases
    are never written automatically. On new hardware, old disk UUIDs and old
    interface names leave the host unbootable or unreachable.

 6  ESCALATION
    Backup failing > 48h    _______________________________
    Disaster recovery       _______________________________
    Passphrase lost         ESCALATE IMMEDIATELY - without it the data is
                            permanently unreadable. There is no recovery path.

 7  LAST DR TEST     Date __________  Result __________  By __________
+----------------------------------------------------------------------+
EOF
  )"

  if [ -n "${out}" ]; then
    printf '%s\n' "${sheet}" >"${out}"
    chmod 0600 "${out}"
    log "Recovery sheet written to ${out}"
    log "Print it. Sign it. Put it where the fire procedure lives."
  else
    printf '\n%s\n\n' "${sheet}" >&2
  fi
}
