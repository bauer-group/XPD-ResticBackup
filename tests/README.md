# Tests

```bash
make test              # hermetic: shellcheck + bats. No Docker, no network.
make integration UBUNTU=22.04|24.04|26.04
make dr-rehearse
```

## Layout

```
tests/
├── unit/                 bats, hermetic, runs on every save
│   ├── helpers/load.bash the sandbox
│   ├── redact.bats       a registered secret must not survive a round trip
│   ├── regressions.bats  one test per bug that actually shipped
│   ├── config.bats       precedence, typo rejection, permission refusal
│   ├── json.bats         emit/escape, including the hyphen regression
│   ├── retention.bats    forget scoping and both counting rails
│   └── restic_args.bats  argv construction, no secret in argv, exit mapping
├── rig/                  BAUER GROUP MinIO + rest-server + victim/phoenix
│   ├── docker-compose.yml
│   ├── minio-init.json   buckets, IAM policies and identities, declaratively
│   └── up.sh             starts the backend AND verifies the init really took
└── e2e/                  installer, maintenance, recovery, docker, DBs, DR
    ├── installer.sh      the curl|bash path on a bare host
    ├── maintenance.sh    check/verify/forget/prune/copy + the ADR-0005 split
    ├── recovery.sh       restore preview/system + dr plan/run/verify
    ├── docker-stack.sh   JOB_MODE=docker against a real daemon
    ├── db-engines.sh     eight engines, dumped consistently
    └── dr-*.sh           seed, destroy the host, restore onto a new one
```

### Proving that a command does nothing

`recovery.sh` is mostly about inertness — `restore preview` must write nothing,
`dr plan` must write nothing, `dr run --dry-run` must change nothing. "Exits 0"
proves none of that, so the suite fingerprints `/srv/payload` and
`/etc/bg-backup` by name, size and mtime around each call and compares. That
matters because preview already shipped one catastrophic failure of exactly this
kind: it set `BGB_RESTORE_PREVIEW=1` and re-dispatched, but only
`restore_path_cmd` ever read the flag, so `preview volume`, `preview project`,
`preview db` and `preview system` performed the real operation.

### The rig backend is the production MinIO stack

`tests/rig/` runs `ghcr.io/bauer-group/cs-minio/{minio,minio-init}` — the same
images the platform runs in production — and declares its buckets, IAM policies
and users in [`minio-init.json`](rig/minio-init.json) instead of in shell. What
gets exercised is therefore the deployment shape we actually ship.

Two things about that container are load-bearing and easy to get wrong:

* **Its exit code is not proof.** `tasks/02_policies.py` logs a failed
  `mc admin policy create` in red and returns normally, so the container exits
  `0` with no policy in place. [`up.sh`](rig/up.sh) reads the users and their
  attached policies back off the server afterwards. Without that check, every
  least-privilege assertion in every suite would be measuring an account with
  whatever permissions it happened to have.
* **Its `${...}` resolver is not comment-aware.** It walks every string in the
  JSON, including the `_readme` and `_comment` keys, so a dollar-brace example
  written in prose aborts the whole rig.

### Each suite gets its own rig

The suites assert exact snapshot counts against one repository prefix, and an
interrupted restic run leaves a lock behind. `make e2e` therefore tears the rig
down between suites; `integration.yml` gets the same isolation for free by
putting each suite on its own runner.

## What is deliberately not tested

A test that asserts a function returns what it obviously returns costs
maintenance and buys nothing. A test that pins down a mistake somebody already
made buys the rest of the project.

So the suite is not comprehensive by design, and
[`regressions.bats`](unit/regressions.bats) is the file to read first — one test
per bug that shipped into this codebase and was caught before release. Every one
of them was **silent**: nothing errored, and the wrong behaviour looked exactly
like the right one.

| Bug | Symptom |
|---|---|
| `local a=1 b="$a"` in `lock_acquire` | every job shared one lock |
| `$'\x00'` in a bracket expression | every hyphen vanished from JSON output |
| a prefix pattern used as a key whitelist | `JOB_KEEP_DIALY` was accepted and retention quietly changed |
| two redaction rules in the wrong order | `Authorization: Bearer <token>` kept the token |
| `job_defaults_reset` without fallbacks | unbound variable, error pointing at the wrong file |

## The sandbox

`helpers/load.bash` points every path-shaped `BGB_*` global inside a per-test
temporary directory before any library is sourced. Unconditional, because a
test that forgot even one of them would either need root or would quietly write
into the developer's real installation — and that failure looks like flakiness,
never like a harness bug.

It also shims `stat` so **both** configuration permission gates are reachable
from any uid. `config_require_perms` checks ownership before mode, which
otherwise makes one of the two gates untestable *and silently so*: as an
unprivileged user the ownership gate always fires first and a test asserting
"0644 is refused" would pass for entirely the wrong reason.

Libraries are sourced directly rather than driven through `bin/bg-backup.sh`,
because the entrypoint sets `set -euo pipefail` and the modules must not. This
is the only way to prove they behave under the shell options bats itself uses.

## Integration rig

```bash
make rig-up
make integration UBUNTU=22.04
make rig-down
```

MinIO on port **9800**, not 9000 — a rig that steals a developer's default MinIO
port is a rig nobody starts twice.

The init container mints a **least-privilege, prefix-scoped** user using the
production policy, including `DeleteObject` only under `<prefix>/locks/*`. An
over-broad test policy would hide exactly the class of permission bug that only
appears in production — most obviously that restic must be able to delete its own
lock objects, or every run leaves a stale lock behind.

A `restic/rest-server` in `--append-only` mode is included so that path is
exercised rather than only documented.

### What `installer.sh` asserts

A vacuous pass is the real failure mode for an installer test, so:

1. `install.sh` exits 0 on a bare image and installs a symlink into the release directory
2. restic is the **pinned** version and the installer reported a verified download
3. `systemd-analyze verify` accepts the unit, and it uses `LoadCredential=` rather than `EnvironmentFile=`
4. re-running is recognised as an upgrade; a second `init` does not silently reconfigure
5. a backup produces **exactly one** snapshot
6. a deliberately unreadable file yields exit **3, not 1**
7. `forget` with no retention policy is **refused** and deletes nothing
8. a restore reproduces content **and** metadata — symlink, empty file, mode, owner, binary hash
9. neither the S3 secret nor the passphrase appears in `doctor` output or the logs
10. `uninstall` removes the tool, keeps the configuration, and **does not touch the repository**

## DR rehearsal

```bash
make dr-rehearse
```

`victim` seeds PostgreSQL, MariaDB and a file tree, backs up, and is then
destroyed. `phoenix` — a container that has never seen the data — recovers using
**only** what the recovery sheet lists.

Databases run natively, not in docker-in-docker: it proves the same property
without a privileged DinD that will be flaky in CI.

The file tree is chosen for what actually goes wrong in a restore: 0 B / 1 B /
4 KiB / 100 MiB files, a sparse file, a symlink, a hardlink pair, a UTF-8 name, a
restrictive mode with a non-root owner, and an xattr. Content checksums alone
would miss every one of those.

Fingerprints are order- and layout-insensitive: PostgreSQL uses
`md5(string_agg(t::text, '|' ORDER BY id))`, MariaDB uses `CHECKSUM TABLE …
EXTENDED` **plus** an ordered `MD5(GROUP_CONCAT(...))` — CHECKSUM alone can differ
across storage-engine internals and would produce a false negative.

**The negative control:** a file created *after* the snapshot must be **absent**
from the restore. Without it, a rehearsal that accidentally reads from a live
mount passes every other assertion.

## CI

| Workflow | |
|---|---|
| `ci.yml` | shellcheck, workflow lint, shfmt, bats — hermetic |
| `integration.yml` | matrix over 22.04 / 24.04 / 26.04, **22.04 first** |

22.04 runs first because it has the oldest bash (5.1) and systemd (249). A pass
on 26.04 with a failure on 22.04 means somebody used newer syntax.

## Adding a test

Ask what would break silently if this were wrong. If the answer is "nothing —
it would fail loudly", the test is probably not worth its maintenance. If the
answer is "a backup would quietly not work", write it.
