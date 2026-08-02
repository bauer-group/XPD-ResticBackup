#!/usr/bin/env bash
# =============================================================================
# bg-backup - usage: single source of truth for --help and docs/cli.md
# =============================================================================
# docs/cli.md is generated from these functions (scripts/generate-docs.sh), so
# help text and documentation cannot drift apart.
# =============================================================================

[ -n "${_BGB_USAGE_SOURCED:-}" ] && return 0
_BGB_USAGE_SOURCED=1

usage_main() {
  cat <<'EOF'
bg-backup - restic-based backup and disaster recovery for Ubuntu servers

USAGE
  bg-backup [global flags] <command> [subcommand] [flags] [args]

SETUP
  init                 Interactive wizard: repository, credentials, first jobs
  discover             Inspect the host: filesystems, compose projects, databases
  doctor               ~30 preflight and health checks (house style: OK / WARN / FAIL)

BACKUP
  backup [JOB...]      Run one, several or --all jobs
  schedule <sub>       enable | disable | list | sync systemd timers
  status               Operator dashboard: per-job state, SLA, repository health
  logs [JOB]           Tail job logs

RESTORE
  restore <sub>        file | dir | volume | project | db | system | preview | rollback
  dump <snap> <path>   Stream a single file out of a snapshot (this is how a DB
                       dump taken with --stdin-from-command is retrieved)
  snapshots            List snapshots
  ls <snap> [path]     Browse a snapshot without restoring
  find <pattern>       Locate a file across snapshots
  diff <a> <b>         What changed between two snapshots
  mount <dir>          Mount the repository read-only (needs fuse3)
  runs <sub>           list | show | diff - complete backup runs, not raw snapshots

MAINTENANCE
  check                Repository integrity (structure, optionally read data)
  verify               Restore a sample and prove it comes back correct
  forget               Apply retention (dry-run by default, guarded by safety rails)
  prune                Reclaim space (primary repository role only)
  copy                 Replicate snapshots to the secondary repository
  unlock               Clear stale restic repository locks
  stats                Repository and per-job size accounting

CONFIG & KEYS
  config <sub>         show | validate | edit | export | import
  secrets <sub>        show | rotate-repo-password | print-recovery-card

DISASTER RECOVERY
  dr <sub>             bootstrap | plan | run | verify | bare-metal

TOOL
  self-update          Upgrade bg-backup (and optionally restic)
  uninstall            Remove the tool (never touches the remote repository)
  version              Version information
  completion bash      Emit the bash completion script

GLOBAL FLAGS
  --config FILE        Alternate main configuration file
  --job NAME           Restrict to a job (repeatable where meaningful)
  --json               Machine-readable output on stdout; messages go to stderr
  --quiet, -q          Suppress informational messages
  --verbose, -v        Increase verbosity (repeatable)
  --dry-run, -n        Show what would happen, change nothing
  --yes, -y            Assume yes for confirmations (required when unattended)
  --no-color           Disable colour (NO_COLOR is honoured automatically)
  --lock-wait SECONDS  How long to wait for a held lock before giving up
  --no-lock            Skip locking - dangerous, documented, never in a timer
  --version            Print version and exit
  --help, -h           This help, or help for a command

EXIT CODES
  0 success        1 fatal          2 usage          3 partial (snapshot ok,
  4 precondition   5 locked         6 repository        some files unreadable)
  7 verify failed  8 hook failed    9 safety rail    130 interrupted

  Exit 3 during a live phase is normal (rotating logs). Exit 3 during a quiesced
  phase means files were unreadable with services stopped - investigate that.

DOCUMENTATION
  https://github.com/bauer-group/XPD-ResticBackup
EOF
}

usage_init() {
  cat <<'EOF'
bg-backup init - configure the repository and seed job definitions

USAGE
  bg-backup init [flags]

FLAGS
  --repo URL              restic repository URL (s3:..., sftp:..., rest:..., /path)
  --password-file FILE    Read the repository passphrase from FILE
  --generate-password     Generate a 32-character passphrase
  --s3-key KEY            S3 / MinIO access key id
  --s3-secret SECRET      S3 / MinIO secret access key
  --s3-region REGION      S3 region (MinIO ignores it, the AWS SDK requires one)
  --profile NAME          minimal | server | docker  (which jobs to seed)
  --non-interactive       Fail instead of prompting; requires --repo and a password
  --force                 Overwrite an existing configuration

BEHAVIOUR
  Idempotent. Never re-initialises an existing repository and never overwrites an
  existing repository key file. Refuses to finish until the operator confirms the
  recovery card has been stored - a repository whose passphrase exists in exactly
  one place is not a backup.
EOF
}

usage_backup() {
  cat <<'EOF'
bg-backup backup - run one or more backup jobs

USAGE
  bg-backup backup [JOB...] [flags]
  bg-backup backup --all

FLAGS
  --all                 Run every enabled job, sequentially
  --tag TAG             Extra tag for this run (repeatable)
  --skip-hooks          Do not run pre/post hooks
  --force-unlock        Clear a stale restic lock owned by this host first
  --json                Emit a run report on stdout

SEQUENCE (per job)
  acquire locks -> pre-hooks -> quiesce -> restic backup -> un-quiesce (always)
  -> post-hooks -> write state and metrics -> forget (if configured) -> notify

  Un-quiesce is guaranteed three ways: the EXIT trap, a state file in /run
  replayed on the next start, and ExecStopPost= in the systemd unit for the case
  where the process is SIGKILLed and no trap ever runs.

  With --all the worst per-job exit code is returned.
EOF
}

usage_restore() {
  cat <<'EOF'
bg-backup restore - bring data back

USAGE
  bg-backup restore file    --path PATH   [selector] [--to DIR | --in-place]
  bg-backup restore dir     --path PATH   [selector] [--to DIR | --in-place]
  bg-backup restore volume  --name NAME   [selector] [--swap]
  bg-backup restore project --name NAME   [selector] [--config-only|--recreate]
  bg-backup restore db      --db SPEC     [selector] [--into container|scratch|-]
  bg-backup restore system  --profile safe|staged|full
  bg-backup restore preview <any of the above>
  bg-backup restore commit   --token ID   Drop the .bgbk-old-* safety copies
  bg-backup restore rollback --token ID   Undo the most recent swap

SELECTOR (how a point in time is chosen)
  --run ID        A complete backup run - the correct selector, because it keeps
                  database dumps and volume contents from different days apart
  --at TIME       Newest complete run at or before an RFC3339 timestamp
  --snapshot ID   One specific restic snapshot (surgical use)
  --job NAME      Restrict to a job

FLAGS
  --to DIR              Restore into a staging directory (DEFAULT)
  --in-place            Swap into the live location; requires --yes
  --force-unsafe        Permit paths on the unsafe list - see share/dr/unsafe-restore.list
  --overwrite MODE      if-newer | always | never
  --verify              Re-read and hash what was written
  --generate-script F   Write a reviewable shell script instead of acting
  --dry-run             Preview only

SAFETY
  The default target is a staging directory, never the live filesystem. In-place
  restores stage first and then swap by rename, keeping the previous content as
  .bgbk-old-<ts> for seven days. Paths that can make a host unbootable or
  unreachable (/boot, /etc/fstab, /etc/netplan, /etc/machine-id, /etc/crypttab)
  are refused unless --force-unsafe is given.
EOF
}

usage_dr() {
  cat <<'EOF'
bg-backup dr - disaster recovery

USAGE
  bg-backup dr bootstrap [--bundle FILE|--bundle-url URL] [--repo URL --password-file F]
  bg-backup dr plan      [--run ID] [--json] [--out FILE]
  bg-backup dr run       --phase system|docker|databases|all [--dry-run] [--yes]
  bg-backup dr verify
  bg-backup dr bare-metal --target /mnt/target

FLOW ON A FRESHLY INSTALLED HOST
  1. install bg-backup with the one-liner
  2. dr bootstrap   recover credentials, then /etc/bg-backup from the config snapshot
  3. dr plan        read-only: what would be installed, restored, and reconciled
  4. dr run         execute phase by phase, confirming each
  5. dr verify      post-recovery health check

  `dr plan` writes nothing. It prints the reconciliation report - NIC and MAC
  deltas, disk UUID deltas, capacity checks - and the explicit list of paths that
  will NOT be restored automatically because doing so can brick a host.

  `dr bare-metal` refuses outside a rescue environment, generates but never runs
  the partitioning script, and reinstalls the kernel and bootloader from packages
  rather than restoring /boot.
EOF
}

usage_config() {
  cat <<'EOF'
bg-backup config - inspect and move the tool's own configuration

USAGE
  bg-backup config show     [--job NAME] [--resolved] [--reveal] [--json]
  bg-backup config validate [--strict]
  bg-backup config edit     [--job NAME]
  bg-backup config export   --out FILE [--passphrase-file F] [--recipients-file F]
  bg-backup config import   --in FILE  [--passphrase-file F] [--force]

THE BOOTSTRAP PROBLEM
  `config export` produces the recovery bundle: repository URL, backend
  credentials, repository passphrase, the independent recovery key, the complete
  configuration, and a printable recovery sheet. It is encrypted three ways
  (age, gpg, openssl) because a rescue system may have only one of them, and each
  ciphertext is decrypted and byte-compared before it is accepted.

  A bundle that has never been round-tripped is not a bundle.
EOF
}

usage_verify() {
  cat <<'EOF'
bg-backup verify - prove the backup restores

USAGE
  bg-backup verify [--job NAME] [--sample N] [--full] [--databases] [--json]

WHAT IT ASSERTS
  files      Restores N sampled files plus a 1 MiB canary written at backup time,
             and compares size and SHA-256 against the snapshot metadata.
  databases  Loads each dump into a throwaway container built from the exact image
             digest recorded in the manifest, on a network with no egress, then
             compares table and row counts against the counts captured at dump
             time. For PostgreSQL those counts are exact: they are taken inside
             the same exported transaction snapshot the dump used.

  Monthly, the OLDEST retained snapshot is tested as well - the one you actually
  depend on in a ransomware scenario, and the one nobody ever tests.

  The result is recorded as the "last proven restore" date shown by `status`.
EOF
}

usage_forget() {
  cat <<'EOF'
bg-backup forget - apply the retention policy

USAGE
  bg-backup forget [--job NAME] [--apply] [--dry-run] [--json]

SAFETY RAILS (this is the only irreversible code path)
  1. Every invocation is scoped with --host <fqdn> AND --tag job=<name> AND
     --group-by host,tags. The repository backend is a shared bucket: without
     --host, one server's forget deletes another server's snapshots, quietly and
     with exit 0.
  2. Dry-run first, always; --apply is required to delete anything.
  3. Refuses if fewer than BGB_FORGET_MIN_SNAPSHOTS would remain (exit 9).
  4. Refuses if more than BGB_FORGET_MAX_DELETE_PERCENT would be removed (exit 9),
     overridable for a one-off with --yes.
  5. Snapshots tagged keep-forever are never removed.
EOF
}

usage_doctor() {
  cat <<'EOF'
bg-backup doctor - preflight and health checks

USAGE
  bg-backup doctor [--json] [--fix]

FLAGS
  --fix     Perform only safe, reversible repairs: create missing directories,
            correct file modes, systemctl daemon-reload, re-link current.

EXIT
  0 when every check passes or only warnings were raised, 4 when any check fails.

NOTABLE CHECKS
  * The repository path ends with this host's FQDN. Getting this wrong in a
    shared bucket is how one host's retention deletes another's backups.
  * /var/lib/docker is on its own mount while --one-file-system is set and it is
    not listed as an explicit source - the backup would silently omit it.
  * Two jobs scheduled closely enough that both would quiesce Docker at once.
  * The recovery card has been acknowledged.
  * Redaction self-test over every registered secret.
EOF
}

usage_for() {
  case "$1" in
    init) usage_init ;;
    backup) usage_backup ;;
    restore) usage_restore ;;
    dr) usage_dr ;;
    config) usage_config ;;
    verify) usage_verify ;;
    forget) usage_forget ;;
    doctor) usage_doctor ;;
    *) usage_main ;;
  esac
}
