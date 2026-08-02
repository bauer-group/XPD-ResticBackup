# Contributing to bg-backup

Thanks for helping. Before anything else, one paragraph of context that explains
every rule below.

**bg-backup is Bash that runs as root, unattended, on a timer, and is allowed to
delete backup history.** There is no test user, no staging tenant, and no
undo — a `forget` that names the wrong host removes another server's snapshots
and exits `0`. The conventions here are not style preferences; each one exists
because the alternative has cost somebody their history, their night, or both.

The design philosophy is lean: the simplest thing that works. A change that
removes a failure mode beats a change that adds a capability.

---

## 1. Getting set up

```bash
git clone --recurse-submodules https://github.com/bauer-group/XPD-ResticBackup.git
cd XPD-ResticBackup
make help          # every target is self-documenting
```

If you cloned without `--recurse-submodules`, `make submodules` fetches the
vendored bats. The suite is vendored on purpose so that your laptop, CI and a
22.04 container all run the identical bats.

You need:

| Tool | For | Notes |
| --- | --- | --- |
| `shellcheck` ≥ 0.9 | the lint gate | `apt-get install shellcheck` |
| `shfmt` 3.12 | formatting | version pinned — see below |
| `jq` | tests, and the tool itself | |
| `docker` + compose v2 | integration rig only | not needed for `make test` |
| `pre-commit` | the local gate | `pip install pre-commit && pre-commit install` |

**Install the pre-commit hooks.** The gitleaks hook is the one that matters: it
catches a credential on your machine, before the network is ever involved.

The `shfmt` version is pinned in `.pre-commit-config.yaml` and again in
`.github/workflows/ci.yml`. shfmt's output changes between minor versions, so a
floating version means CI and your hook disagree about correct formatting and
you end up in a reformat loop neither side can win. If you bump one, bump both
in the same commit.

---

## 2. The gates

```bash
make test          # hermetic: shellcheck + bats units. Run this on every save.
make check-all     # everything ci.yml runs: lint, format-check, units, config validate
make format        # rewrite with shfmt (make format-check only diffs)

make integration UBUNTU=22.04   # installer end-to-end in a clean container
make dr-rehearse  UBUNTU=22.04  # seed → back up → destroy the host → restore → assert
```

`make check-all` and `.github/workflows/ci.yml` are deliberately the same set.
If you add a gate to one, add it to the other in the same commit, or the local
and remote answers start disagreeing and people learn to ignore CI.

**Always test against 22.04 first.** It is the supported floor: bash 5.1 and
systemd 249. Your machine and the GitHub runner both have bash 5.2, which
happily accepts syntax that dies on a production 22.04 host. Green locally is
not evidence of 22.04 compatibility; the 22.04 leg of the integration matrix is.

---

## 3. Shell conventions

These are enforced by ShellCheck at `-S warning`, by `shfmt -i 2 -ci -bn`, and
by review.

- **Bash 5.1 compatible.** No 5.2-only syntax, ever.
- **`lib/*.sh` must not set `set -euo pipefail`.** The entrypoint owns the shell
  options; a library that sets them changes the behaviour of every caller,
  including callers that deliberately handle a non-zero status.
- **Every library starts with a double-source guard:**
  ```bash
  [ -n "${_BGB_MYMODULE_SOURCED:-}" ] && return 0
  _BGB_MYMODULE_SOURCED=1
  ```
  Modules source each other freely; without the guard, `readonly` declarations
  fail on the second pass and the failure surfaces somewhere unrelated.
- **Never `local x=$(cmd)`** (SC2155). `local` returns its own exit status, so
  the command's failure is swallowed and `set -e` never fires. Write
  `local x; x=$(cmd)`.
- **Quote everything.** Paths in this tool routinely contain spaces, because
  they come from someone else's server.
- **Never hand-parse restic or docker JSON.** Call `require_jq` and use `jq`. A
  `grep`-based parser works until a path contains a quote, at which point it
  reports a successful backup of the wrong thing.
- **bg-backup's own JSON output uses the `json_*` helpers**, which have no jq
  dependency. `bg-backup --json` has to work during a recovery on a host where
  jq was never installed.
- **No secret in argv.** `/proc/<pid>/cmdline` is world-readable on Linux, and
  every dump command and hook we spawn inherits a process table. Secrets travel
  by environment or a `0400` file, never as a flag.
- **Comments explain WHY**, at length where a trap is being avoided. The house
  marker is a comment that names the mistake it prevents — "written this way
  because the obvious form silently does X". A comment restating the code is
  noise; a comment naming the trap saves the next person an afternoon.
- **Real Unicode characters** (`✓`, `→`, `📦`), never escape sequences like
  `\U0001F4E6`.
- **LF line endings, 2-space indent, file ends with a newline.** `.gitattributes`
  enforces LF and it is load-bearing, not cosmetic: a CRLF `install.sh` served
  from raw.githubusercontent.com fails on every target host with
  `bash\r: no such file or directory`.

### The API surface

Three things are API and cannot change casually:

1. **Exit codes** (`lib/core.sh`). systemd, monitoring probes and Ansible key
   off them. Adding is fine; renumbering is a breaking change.
2. **`--json` output.** `BGB_JSON_SCHEMA` is versioned; add fields, do not
   rename them.
3. **`BGB_*` / `JOB_*` configuration keys.** Config files live on operators'
   servers and survive upgrades untouched.

---

## 4. The traps that already cost someone data

Do not "simplify" any of these without reading the comment above them first.

- **Database dumps stream via
  `restic backup --stdin-from-command --stdin-filename <name> -- <cmd>`.** That
  flag aborts the backup when the dump command exits non-zero. Piping into
  `--stdin` instead stores a truncated dump as a perfectly healthy-looking
  snapshot, and you find out during the restore.
- **Dumps are never pre-compressed.** restic already compresses, and plain SQL
  deduplicates across days where a gzip stream does not — the same dump gzipped
  is a completely different byte sequence every night.
- **`forget` is always scoped** `--host <fqdn> --tag job=<name>
  --group-by host,tags`. The bucket is shared across servers. Without `--host`,
  one host deletes another host's snapshots, and restic reports success.
- **Exit 3 (partial) is not an error and not a success.** During a live phase it
  is normal (open files move); during a quiesced phase it is a real signal.
  `JOB_PARTIAL_IS_FAILURE` decides. Never fold it into 0 or 1 — a tool that
  loses that distinction teaches its operators to ignore both.
- **Notifiers run in a subshell with a timeout and never change the job's exit
  code.** A Teams outage is not a backup failure.
- **Docker backups are application-level**: compose files, volumes, bind mounts,
  image digests, network subnets, database dumps. Never
  `/var/lib/docker/overlay2` — that is unrestorable churn.
- **`retry` is for transient network and S3 conditions only.** Never wrap a dump
  or a hook: retrying hides the failure it exists to surface.

---

## 5. Credentials in documentation

This repository exists because live MinIO keys and a restic passphrase were
pasted into working documents. So:

- `docs/` is **not** allowlisted in `.gitleaks.toml`. Other repositories exempt
  their documentation directory; here, documentation is exactly where the leak
  happened.
- Every credential in every document is a **placeholder shape**, and only these
  shapes are allowlisted:
  `<angle-brackets>`, `CHANGE_ME`, `EXAMPLE` / `PLACEHOLDER` / `REDACTED` /
  `YOUR_KEY`, `${SHELL_VAR}`, `xxxxxxxx`.
- **Never a realistic-looking fake.** A plausible fake key trains reviewers to
  skim past key-shaped strings, which is precisely the reflex that let the real
  one through.

If you do commit a credential: **rotate it first**, then tell a maintainer. A
force-push does not un-leak anything — the object is fetchable the moment it
touches GitHub, and rewriting history is the second step, never the first.

---

## 6. Tests

- **Unit tests (bats, `tests/unit/`)** must be hermetic: no Docker, no network,
  no root, no secrets. They run on every push. Fixtures are recorded restic and
  docker JSON under `tests/fixtures/`.
- **Integration (`tests/rig/`, `tests/e2e/`)** drives a throwaway MinIO through
  real restic in a real container. The rig credentials are throwaway literals,
  allowlisted by name in `.gitleaks.toml`; never point the rig at a real bucket.

A **DR rehearsal is mandatory** — not optional — for any change that touches
`restore`, `dr`, retention, the systemd units, the installer, or the argv
bg-backup builds for restic. Those paths are only ever exercised for real on
the worst day of someone's year.

Bug fixes get a regression test. If it was worth fixing, it is worth pinning.

---

## 7. Commits and pull requests

Conventional Commits, **subject in past tense**, max 50 characters, no period:

```text
fix(retention): scoped forget to the local host

An unscoped `forget --keep-daily` matched snapshots from every server
sharing the bucket and removed them with exit code 0, so nothing alerted.
Now always passes --host, --tag job=<name> and --group-by host,tags.

Closes #123
```

- Types: `feat` `fix` `refactor` `docs` `style` `test` `chore` `perf` `build`
  `ci` `revert`. Breaking: `type!` or a `BREAKING CHANGE:` footer.
- **Past tense** — "added", "fixed", "updated". Not "add", "fix", "update".
- One commit = one logical change, and each commit stands alone. No WIP on main.
- **No `Co-Authored-By:` and no AI attribution.** Ever.
- Never commit secrets or `.env` files (`.env.example` is encouraged).
- Use `git mv` to move tracked files, so history follows them.

`CHANGELOG.md` is generated by semantic-release from these messages. Do not
hand-edit it — write the commit message you want to read in the changelog.

Pull requests: fill in the template honestly, including what you did **not**
run. "I skipped the DR rehearsal because this only touches the help text" is a
useful sentence; a fully-ticked checklist nobody believes is not.

---

## 8. What CI does with your branch

| Workflow | When | What it proves |
| --- | --- | --- |
| 🔎 CI | every push and PR | ShellCheck, workflow lint, `shfmt -d`, bats units, example config validates. Hermetic — no Docker, no secrets. |
| 🧪 Integration | nightly, and on PRs touching install/lib/tests | Real restic against real MinIO on 22.04 / 24.04 / 26.04, plus the full destroy-and-restore rehearsal. |
| 🛡️ Security | every push, PR, and weekly | gitleaks, TruffleHog, CodeQL (workflows), vulnerabilities, licences. |
| 🚀 Release | push to main | **Gated**: ShellCheck at severity `error` and workflow lint must pass before a tag is published. |

The release gate is stricter than CI for one reason: `install.sh` is piped into
root shells on production hosts. A tag published from that workflow is running
as uid 0 on unattended machines within hours, with no review step in between.

---

## 9. Reporting security problems

Not in an issue, not in a PR. `SECURITY.md` has the process:
private advisory or security@bauer-group.com, acknowledged within 2 business
days.

---

## 10. Code of Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
