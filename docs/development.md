# Development

```bash
make              # self-documenting help
make test         # hermetic: shellcheck + bats units. No Docker, no network.
make check-all    # everything CI runs
make integration UBUNTU=22.04|24.04|26.04
make dr-rehearse
```

`make test` is meant to run on every save, which is why it needs nothing
installed beyond shellcheck and bats.

## Rules

1. **Bash 5.1** — Ubuntu 22.04 is the floor. No 5.2+ syntax.
2. Modules never set `set -euo pipefail`; the entrypoint does. Every module opens
   with a double-source guard.
3. shellcheck-clean at `-S warning`. Never `local x=$(cmd)` (SC2155).
4. **Never hand-parse restic or docker JSON.** Only `jq`, and call `require_jq`
   first. Our *own* JSON is built with the `json_*` helpers so `--json` works on
   a rescue system with nothing installed.
5. **Never put a secret in argv.** `/proc/<pid>/cmdline` is world-readable.
6. Comments explain **why**, at length where a trap is being avoided. That
   verbose "here is the mistake this prevents" style is the house marker.
7. Real Unicode, never escape sequences.

### Two bash traps this codebase has already hit

```bash
local name="$1" dir="/lock/${name}.d"      # WRONG - dir becomes "/lock/.d"
```

Bash evaluates every right-hand side in one `local` **before** any declaration
takes effect, so `${name}` expands to the outer scope's value or nothing. Every
job shared one lock. Use two `local` statements.

```bash
s="${s//[$'\x00'-$'\x08']/}"               # WRONG - strips every hyphen
```

Bash cannot hold a NUL in a string, so `$'\x00'` expands to nothing and the
bracket expression degenerates to `[-\x08]` with a leading literal `-`.
Timestamps lost their dashes and `/etc/bg-backup` became `/etc/bgbackup`.

Both are pinned by [tests/unit/regressions.bats](../tests/unit/regressions.bats).

## Layout

```
bin/bg-backup.sh     dispatcher
lib/*.sh             one module per concern, sourced on demand
lib/notify/*.sh      one file per notification provider
share/db/*.sh        one file per database engine
share/systemd/       unit templates
share/dr/            the restore safety classification
tests/unit/*.bats    hermetic
tests/rig/           MinIO + victim/phoenix containers
tests/e2e/           installer and DR rehearsal
```

## Tests

### Unit

```bash
make test-unit
tests/helper/bats-core/bin/bats tests/unit/redact.bats
```

The suite is deliberately not comprehensive. A test that asserts a function
returns what it obviously returns costs maintenance and buys nothing; a test that
pins down a mistake somebody already made buys the rest of the project.

The ones that earn their keep:

| File | |
|---|---|
| `redact.bats` | a registered secret must not survive a round trip, in any of six shapes |
| `regressions.bats` | one test per bug that actually shipped |
| `config.bats` | precedence, unknown key **rejected**, command substitution rejected, mode 0644 **refused** |
| `retention.bats` | the argv always carries `--host`, `--tag job=`, `--group-by`; both counting rails |
| `restic_args.bats` | no secret ever appears in a built argv |

### Integration

```bash
make rig-up
make integration UBUNTU=22.04
```

Real restic against a throwaway MinIO, in a clean Ubuntu container. The rig mints
a **least-privilege, prefix-scoped** user using the same policy production uses —
an over-broad test policy would hide a real permission bug.

`tests/e2e/installer.sh` must assert hard things, because a vacuous pass is the
real failure mode here:

- restic reports the pinned version and its sha256 matches
- `systemd-analyze verify` accepts the units (no PID 1 in a container, so verify
  rather than start — that is what the harness can honestly prove)
- a second `init` is **refused**
- a deliberately unreadable file yields exit **3, not 1**, and the `.prom` is
  still written
- `forget` with an everything-deleting policy is **refused**
- a restore reproduces the tree byte-for-byte **and its metadata** — mode, owner,
  symlink, hardlink. A checksum-only assertion misses exactly the things that go
  wrong.
- `doctor` output contains **no** test secret
- `uninstall` leaves no unit and does **not** touch the repository

### DR rehearsal

```bash
make dr-rehearse
```

Postgres, MariaDB and a file tree seeded natively in the `victim` container — no
docker-in-docker, which proves the same property without a privileged nightmare
that will be flaky.

The file tree includes 0 B / 1 B / 4 KiB / 100 MiB files, a sparse file, a
symlink, a hardlink pair, a UTF-8 name, a restrictive mode with a non-root owner,
and an xattr.

The `phoenix` container receives **only** what the recovery sheet lists. If the
rehearsal needs anything else, the sheet is wrong.

Includes the negative assertion: a file created **after** the snapshot must be
absent from the restore. Without it, a test that accidentally restores from a
live mount still passes.

## Adding a database engine

One new file in `share/db/`, seven functions, one word in `BGB_DB_ENGINES_KNOWN`.
Full interface: [share/db/README.md](../share/db/README.md).

The part worth thinking about is not the dump command — it is **when to report
`degraded`**. Every engine has a case where the dump succeeds but cannot be
called consistent. Find it, and say so.

## Adding a notifier

One file in `lib/notify/`, one function:

```bash
bgb_notify_<name> <event> <job> <rc> <payload-json> <log-excerpt-file>
```

Return 0 always. A notifier that can fail the backup is worse than no notifier.
Everything it sends must pass `redact()`.

## Commits

Conventional Commits, **past tense**, ≤50 characters, no AI attribution.

```
feat(db): added ClickHouse engine module
fix(lock): separated local declarations so job locks differ
```

`fix` → PATCH, `feat` → MINOR, `type!` or `BREAKING CHANGE:` → MAJOR.

## CI

| Workflow | |
|---|---|
| `ci.yml` | shellcheck, workflow lint, shfmt, bats — hermetic |
| `integration.yml` | matrix over 22.04 / 24.04 / 26.04, **22.04 first** |
| `security.yml` | gitleaks, TruffleHog in git-history mode, Trivy, CodeQL (`actions`) |
| `release.yml` | semantic-release, **gated** on shellcheck at severity `error` |

22.04 runs first on purpose: it has the oldest bash and systemd. A pass on 26.04
with a failure on 22.04 means somebody used newer syntax.

The release gate is not ceremony — `install.sh` is piped into root shells on
production hosts.

## Before opening a PR

```bash
make check-all
```

And ask the question the PR template asks: **what is the blast radius if this is
wrong?** For most of this codebase the answer is "a backup silently does not
work", which is why the comments are long and the safety rails are not optional.
