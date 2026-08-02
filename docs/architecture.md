# Architecture

## Shape

```
bin/bg-backup.sh            dispatcher: global flags, module loading, routing
lib/
  core.sh      exit codes, logging, cleanup registry, temp files, helpers
  redact.sh    credential redaction - everything leaving the process passes it
  json.sh      emit our own JSON without jq; parse everyone else's WITH jq
  config.sh    lint-then-source, the job model, the key whitelist
  restic.sh    argv construction, execution, exit-code mapping
  lock.sh      mkdir locks with boot-id-aware stale reclaim
  state.sh     per-job state, run IDs, the event log
  backup.sh    the run orchestrator
  quiesce.sh   freeze and - guaranteed - thaw
  docker.sh    compose discovery, volumes, manifests
  db.sh        engine detection and dispatch  → share/db/<engine>.sh
  restore.sh   staging, the safety classification, atomic swap
  dr.sh        bootstrap / plan / run / verify / bare-metal
  secrets.sh   the recovery bundle, key rotation, the recovery sheet
  verify.sh    check, canary, sampled restore, scratch-container DB restore
  retention.sh forget/prune/copy with five safety rails
  monitor.sh   → lib/notify/<provider>.sh
  metrics.sh   Prometheus textfile
  systemd.sh   unit generation and reconciliation
  discover.sh  what does this host actually have
  doctor.sh    ~30 preflight and health checks
  internal.sh  entry points for ExecStopPost= and OnFailure=
```

Modules are sourced **on demand** by the dispatcher, so `--help` and `version`
stay instant and do not require a readable `/etc/bg-backup`.

## Why bash

The tool's most important execution context is a freshly installed or
rescue-booted machine where nothing is installed and the operator is under
pressure. A tool whose source can be read, understood and hand-executed step by
step there is a feature of a disaster-recovery product, not a compromise.

Python was rejected on packaging: 22.04's 3.10 has no `tomllib`, PyYAML is not
installed by default, and 26.04 is PEP-668 externally-managed so `pip install`
into the system interpreter fails. Making one product behave identically across
those three would be actively hard.

Go was rejected on distribution: `curl … | bash` from the repository is the
required install path, and a Go binary means the repository alone is not
runnable.

The discipline that makes bash acceptable here: shellcheck at warning level in
CI, `set -euo pipefail` in the entrypoint (never in a module), never
`local x=$(cmd)`, and — the load-bearing one — **never hand-parse restic or
docker JSON**. Only jq. If jq is missing, the command refuses rather than
guessing. See [ADR-0001](adr/0001-bash-cli-instead-of-resticprofile.md).

## The run

```
recover a stale quiesce  ← FIRST: never start on top of a frozen host
      ↓
acquire job lock, then repository lock
      ↓
load repository env, verify the restic version
      ↓
notify start                      (dead-man's-switch monitors)
      ↓
pre-hooks                         (scrubbed environment)
      ↓
┌─ mode: files ──────┬─ mode: docker ─────────────────────────────┐
│ restic backup      │ manifest → DB dumps → image export         │
│                    │ → quiesce → file backup → un-quiesce       │
└────────────────────┴────────────────────────────────────────────┘
      ↓
un-quiesce                        ← BEFORE releasing locks
      ↓
post-hooks → state → metrics → forget → notify result
```

Three orderings are load-bearing:

**Stale-quiesce recovery runs first.** A previous run killed mid-freeze leaves a
state file; a new backup must undo that before doing anything else.

**Un-quiesce happens before the locks are released.** Otherwise a waiting job
could start while services are still down.

**`forget` runs only after a snapshot exists.** Applying retention after a failed
run is how a bad night becomes data loss.

## Quiesce reversal

The single most dangerous thing this tool does is stop something. Three
independent mechanisms guarantee it starts again:

| Mechanism | Covers |
|---|---|
| `trap … EXIT INT TERM` | ordinary errors, Ctrl-C |
| state file in `/run/bg-backup/`, replayed at the start of the next run | SIGKILL, OOM, `RuntimeMaxSec`, reboot |
| `ExecStopPost=` in the systemd unit | the process was killed and no trap fired |

The state file is written **before** the freeze, not after: if the process dies
between write and freeze we perform a harmless unpause of a running container; the
other order would leave containers paused forever.

## Runs, not snapshots

One backup produces several snapshots — the file tree, one per database dump,
one per exported image. Resolving "latest" per snapshot independently would
cheerfully pair Monday's database dump with Tuesday's volume contents.

Every snapshot of one backup therefore carries `run=<id>`, and `bg-backup runs`
is the object operators work with. `restore --run <id>` is the correct selector;
`--snapshot` exists for surgical work.

Tags: `bg-backup=1`, `job=<name>`, `run=<id>`, `kind=files|dbdump|image`,
`db=<engine>`.

## Locking

Two levels, neither of them systemd:

| Lock | Prevents |
|---|---|
| `job-<name>` | a job overlapping itself when a run exceeds its interval |
| `repo-<id>` | backup / forget / prune / check / copy overlapping each other |

systemd's `Conflicts=` is deliberately unused: it **kills** the other unit, which
for a job holding Docker down turns a scheduling collision into an outage.

`/run/lock` is tmpfs, so locks cannot survive a reboot — the entire class of
"stale lock after a crash, cleared by hand at 3am" does not exist. Within a boot,
staleness is decided by PID liveness plus a stored `boot_id`, which guards
against PID reuse.

## Layers

| Layer | Why it is a separate concern |
|---|---|
| **system** | files plus a machine-readable host manifest — package selections, APT sources, enabled units, users/UIDs, NIC MACs, disk UUIDs. Files alone do not make a host restorable: a fresh Ubuntu has different UIDs, different interface names and different disk UUIDs. |
| **docker** | application-level, never `/var/lib/docker`. See [ADR-0004](adr/0004-application-level-docker-backup.md). |
| **databases** | logical dumps — the only mechanism that is transactionally consistent |
| **config** | `/etc/bg-backup` itself, which is what makes bootstrapping from nothing possible |

## The bootstrap problem

The repository passphrase cannot live only inside the repository it opens.

```
recovery card (printed)  →  repository URL + passphrase + backend keys
        ↓
bg-backup dr bootstrap   →  writes credentials, tests the repository
        ↓
config snapshot (tag bg-backup-config)  →  /etc/bg-backup restored in full
        ↓
bg-backup dr plan        →  read-only reconciliation report
```

The bundle is encrypted three ways — age, gpg, openssl — because a rescue system
may only have one of them, and every ciphertext is decrypted again and
byte-compared before it is accepted. A bundle that has never been round-tripped
is not a bundle; it is a hope.

## Trust boundaries

bg-backup runs as root and has no privilege boundary of its own. Its security
property is narrower and more useful: **a credential it holds cannot destroy
history.**

- the host credential is scoped to its own prefix and may delete only under
  `locks/` (restic needs that, or every run leaves a stale lock)
- `prune` runs only from a `primary` role, and the prune identity is never on a
  backed-up host
- an independent recovery key means a host compromise costs one
  `restic key remove` rather than the repository

Honest limitation, stated in [SECURITY.md](../SECURITY.md): `PutObject` without
delete still allows **overwrite**. `check --read-data` detects it; nothing
prevents it short of versioning or a pull-side copy repository.
