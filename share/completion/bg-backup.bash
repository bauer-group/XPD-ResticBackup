# shellcheck shell=bash
# =============================================================================
# bg-backup - bash completion
# =============================================================================
# Installed to /etc/bash_completion.d/bg-backup, or emitted on demand with
#   bg-backup completion bash
#
# Job names are read from the configuration directory at completion time rather
# than from a cached list: adding a job is a file drop, and a completion that
# needs a re-login after every change is a completion nobody trusts.
#
# Nothing here shells out to bg-backup itself. Completion runs on every TAB, and
# a completion function that starts a process which parses configuration,
# validates it and may print warnings makes a shell feel broken.
# =============================================================================

# The jobs defined in conf.d, with the numeric ordering prefix stripped -
# "10-system.conf" is the job "system", which is what every command takes.
_bg_backup_jobs() {
  local dir f base
  dir="${BGB_CONFDIR:-/etc/bg-backup}/conf.d"
  [ -d "${dir}" ] || return 0
  for f in "${dir}"/*.conf; do
    [ -e "${f}" ] || continue
    base="${f##*/}"
    base="${base%.conf}"
    printf '%s\n' "${base#[0-9][0-9]-}"
  done
}

_bg_backup() {
  local cur prev cmd sub word i skip
  local commands global_flags opts

  cur="${COMP_WORDS[COMP_CWORD]}"
  prev=""
  [ "${COMP_CWORD}" -gt 0 ] && prev="${COMP_WORDS[COMP_CWORD - 1]}"

  commands="init discover doctor backup schedule status logs restore dump
            snapshots ls find diff mount runs check verify forget prune copy
            unlock stats config secrets dr self-update uninstall version
            completion help"

  global_flags="--config --job --json --quiet --verbose --dry-run --yes
                --no-color --color --lock-wait --no-lock --version --help"

  # Flags whose NEXT word is a value, not a command. Without this list the
  # value would be mistaken for the command word and every suggestion after
  # `bg-backup --job system <TAB>` would be wrong.
  local value_flags=" --config --job --lock-wait --color --tag --path --name
                      --db --to --profile --sample --overwrite --out --in
                      --repo --password-file --s3-key --s3-secret --s3-region
                      --run --at --snapshot --generate-script --bundle
                      --bundle-url --phase --target --passphrase-file
                      --recipients-file --token --unit --exclude "

  # --- locate the command and subcommand words -------------------------------
  cmd=""
  sub=""
  skip=0
  for ((i = 1; i < COMP_CWORD; i++)); do
    word="${COMP_WORDS[i]}"
    if [ "${skip}" -eq 1 ]; then
      skip=0
      continue
    fi
    case "${word}" in
      --*=*) continue ;;
      -*)
        case "${value_flags}" in
          *" ${word} "*) skip=1 ;;
        esac
        continue
        ;;
    esac
    if [ -z "${cmd}" ]; then
      cmd="${word}"
    elif [ -z "${sub}" ]; then
      sub="${word}"
    fi
  done

  # --- complete the VALUE of the flag just typed ------------------------------
  case "${prev}" in
    --job)
      mapfile -t COMPREPLY < <(compgen -W "$(_bg_backup_jobs)" -- "${cur}")
      return 0
      ;;
    --config | --out | --in | --password-file | --passphrase-file | --recipients-file | --bundle | --generate-script | --to | --target)
      # Hand back to readline's own filename completion: it knows about
      # directories, trailing slashes and quoting, and re-implementing that here
      # only produces a worse version of it.
      if declare -F compopt >/dev/null 2>&1 || type compopt >/dev/null 2>&1; then
        compopt -o default 2>/dev/null || true
      fi
      COMPREPLY=()
      return 0
      ;;
    --color)
      mapfile -t COMPREPLY < <(compgen -W "auto always never" -- "${cur}")
      return 0
      ;;
    --profile)
      case "${cmd}" in
        restore) mapfile -t COMPREPLY < <(compgen -W "safe staged full" -- "${cur}") ;;
        *) mapfile -t COMPREPLY < <(compgen -W "minimal server docker" -- "${cur}") ;;
      esac
      return 0
      ;;
    --phase)
      mapfile -t COMPREPLY < <(compgen -W "system docker databases all" -- "${cur}")
      return 0
      ;;
    --overwrite)
      mapfile -t COMPREPLY < <(compgen -W "if-newer always never" -- "${cur}")
      return 0
      ;;
    --into)
      mapfile -t COMPREPLY < <(compgen -W "container scratch -" -- "${cur}")
      return 0
      ;;
  esac

  # --- the command word itself ------------------------------------------------
  if [ -z "${cmd}" ]; then
    if [ "${cur:0:1}" = "-" ]; then
      mapfile -t COMPREPLY < <(compgen -W "${global_flags}" -- "${cur}")
    else
      mapfile -t COMPREPLY < <(compgen -W "${commands}" -- "${cur}")
    fi
    return 0
  fi

  # --- subcommands and per-command flags -------------------------------------
  opts=""
  case "${cmd}" in
    backup)
      opts="--all --tag --skip-hooks --force-unlock --json ${global_flags}"
      if [ "${cur:0:1}" != "-" ]; then
        mapfile -t COMPREPLY < <(compgen -W "--all $(_bg_backup_jobs)" -- "${cur}")
        return 0
      fi
      ;;
    logs | status)
      if [ "${cur:0:1}" != "-" ]; then
        mapfile -t COMPREPLY < <(compgen -W "$(_bg_backup_jobs)" -- "${cur}")
        return 0
      fi
      opts="--follow --lines --json ${global_flags}"
      ;;
    schedule)
      if [ -z "${sub}" ]; then
        mapfile -t COMPREPLY < <(compgen -W "enable disable list sync" -- "${cur}")
        return 0
      fi
      case "${sub}" in
        enable | disable)
          if [ "${cur:0:1}" != "-" ]; then
            mapfile -t COMPREPLY < <(compgen -W "$(_bg_backup_jobs)" -- "${cur}")
            return 0
          fi
          ;;
        list) opts="--json" ;;
      esac
      opts="${opts} ${global_flags}"
      ;;
    restore)
      if [ -z "${sub}" ]; then
        mapfile -t COMPREPLY < <(compgen -W "file dir volume project db system preview commit rollback" -- "${cur}")
        return 0
      fi
      opts="--path --name --db --into --run --at --snapshot --job --to --in-place
            --force-unsafe --overwrite --verify --generate-script --profile
            --config-only --recreate --swap --token --dry-run ${global_flags}"
      ;;
    runs)
      if [ -z "${sub}" ]; then
        mapfile -t COMPREPLY < <(compgen -W "list show diff" -- "${cur}")
        return 0
      fi
      opts="--job --json ${global_flags}"
      ;;
    config)
      if [ -z "${sub}" ]; then
        mapfile -t COMPREPLY < <(compgen -W "show validate edit export import" -- "${cur}")
        return 0
      fi
      opts="--job --resolved --reveal --strict --out --in --passphrase-file
            --recipients-file --force --json ${global_flags}"
      ;;
    secrets)
      if [ -z "${sub}" ]; then
        mapfile -t COMPREPLY < <(compgen -W "show rotate-repo-password print-recovery-card" -- "${cur}")
        return 0
      fi
      opts="--json ${global_flags}"
      ;;
    dr)
      if [ -z "${sub}" ]; then
        mapfile -t COMPREPLY < <(compgen -W "bootstrap plan run verify bare-metal" -- "${cur}")
        return 0
      fi
      opts="--bundle --bundle-url --repo --password-file --run --phase --target
            --out --json --dry-run ${global_flags}"
      ;;
    completion)
      mapfile -t COMPREPLY < <(compgen -W "bash" -- "${cur}")
      return 0
      ;;
    help)
      mapfile -t COMPREPLY < <(compgen -W "${commands}" -- "${cur}")
      return 0
      ;;
    init)
      opts="--repo --password-file --generate-password --s3-key --s3-secret
            --s3-region --profile --non-interactive --force ${global_flags}"
      ;;
    doctor)
      opts="--json --fix ${global_flags}"
      ;;
    discover)
      opts="--write --json ${global_flags}"
      ;;
    verify)
      opts="--job --sample --full --databases --json ${global_flags}"
      ;;
    check)
      opts="--read-data --read-data-subset --json ${global_flags}"
      ;;
    forget)
      opts="--job --apply --dry-run --json ${global_flags}"
      ;;
    prune | copy | unlock | stats)
      opts="--job --json ${global_flags}"
      ;;
    snapshots | ls | find | diff | mount | dump)
      opts="--job --tag --host --json ${global_flags}"
      ;;
    self-update)
      opts="--channel --version --restic --rollback --check ${global_flags}"
      ;;
    uninstall)
      opts="--purge --yes ${global_flags}"
      ;;
    *)
      opts="${global_flags}"
      ;;
  esac

  mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
  return 0
}

complete -F _bg_backup bg-backup
complete -F _bg_backup bg-backup.sh
