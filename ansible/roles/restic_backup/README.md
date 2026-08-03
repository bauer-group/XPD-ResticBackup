# Ansible role: `restic_backup`

Installs and configures [bg-backup](https://github.com/bauer-group/XPD-ResticBackup)
on Ubuntu 22.04 / 24.04 / 26.04 and Debian 13.

> **Where this role lives.** The authoritative source is this repository; the
> role is maintained in `bauer-group/IAC-Ansible` under `roles/restic_backup/`
> and PR'd across. See [ADR-0007](../../../docs/adr/0007-ansible-role-lives-in-iac-ansible.md).

## What it does

It is a **driver**, not a reimplementation. It fetches a pinned release tarball
with `get_url` and a `checksum:`, runs `install.sh --offline`, then renders the
configuration and credentials.

Not `curl | bash`. That is right for a human bootstrapping one server; an
unattended converge wants a checksum assertion and a `changed_when` it can reason
about.

## Quick start

```yaml
- hosts: restic_backup_hosts
  become: true
  roles:
    - role: restic_backup
```

with, in `group_vars`:

```yaml
restic_backup_version: "1.0.0"
restic_backup_release_checksum: "sha256:..."
restic_backup_repository: "{{ secrets_restic_repository }}"
restic_backup_password: "{{ secrets_restic_password }}"
restic_backup_s3_access_key_id: "{{ secrets_restic_s3_access_key_id }}"
restic_backup_s3_secret_access_key: "{{ secrets_restic_s3_secret_access_key }}"
```

## The variables that carry a decision

Full surface in [`defaults/main.yml`](defaults/main.yml) — 120 variables, all
prefixed `restic_backup_`. These five are the ones worth understanding.

| Variable | Default | |
|---|---|---|
| `restic_backup_enabled` | `true` | master switch |
| `restic_backup_test_mode` | `false` | render everything, install and start nothing. What molecule uses. |
| `restic_backup_version` | pinned | **deliberately pinned** — no host takes a new backup tool on a routine `ansible-pull`; bumping it is a reviewed change |
| `restic_backup_repo_prefix` | `{{ inventory_hostname }}` | used verbatim, see below |
| `restic_backup_prune_local` | **`false`** | a ransomware control, not a preference |

### `restic_backup_prune_local: false`

`prune` deletes and rewrites pack files. A host that can prune can destroy its own
history, and so can anything that compromises it. Retention runs from a management
path with a separate identity, and that identity is deliberately absent from the
`secrets` role's variable table so no managed host can resolve it.

See [ADR-0005](../../../docs/adr/0005-append-only-and-separate-prune-identity.md).

### Legacy hostnames

Some hosts use an older naming scheme that does not match `AAAA-GG` — for example
`10000-001.cloud.example.com`. `parse_asset_hostname` returns `valid: false`
for those.

**The role never derives an asset id or group code from the hostname and never
asserts the schema.** `restic_backup_repo_prefix` uses `{{ inventory_hostname }}`
verbatim, and `bg-backup doctor` checks only "the repository path ends with my
FQDN", which is schema-free.

An assert on the naming convention here would fail on exactly the oldest and often
most important servers. The molecule scenario converges with a legacy-style
hostname to keep that honest.

## Secrets

Pulled from the `secrets` role in `defaults`, never hardcoded:

```yaml
restic_backup_password: "{{ secrets_restic_password | default('') }}"
```

Every credential task carries `no_log: true`. Credential files are written `0400`
into a `0700` directory.

Notifier tokens reach the units through **`LoadCredential=`**, never
`EnvironmentFile=` — the latter is rendered by `systemctl show -p Environment` for
any local user. See [ADR-0003](../../../docs/adr/0003-loadcredential-not-environmentfile.md).

The IAC-Ansible `secrets` role needs these additions:

```yaml
secrets_restic_repository: ""
secrets_restic_password: ""
secrets_restic_s3_access_key_id: ""
secrets_restic_s3_secret_access_key: ""
secrets_restic_teams_webhook: ""
secrets_restic_kuma_push_url: ""
```

in `defaults/main.yml`, the `SET`/`EMPTY` status line in
`backend_ansible_vault.yml`, the `set_fact` block in
`backend_hashicorp_vault.yml`, and the table in `docs/vault.md`.

> The prune credential is **not** in that list, and must not be.

## The assertion worth having

`tasks/assert.yml` compares `df -P /var/lib/docker` against `df -P /` and **fails
the converge** when they differ while `one_file_system` is true and
`/var/lib/docker` is not an explicit source.

A failed converge is loud and gets fixed. A silent half-backup is discovered
during a restore.

## Task order

```
assert → install → credentials → config → systemd → logrotate → verify
```

Credentials before configuration, because `bg-backup.conf` points at them and a
configuration referencing a missing `repo.env` makes every later command in the
role exit 4 instead of doing its job.

The role does **not** use `meta: end_host` when disabled — that ends the whole
play for the host and would silently skip any role scheduled after it.

## Testing

```bash
cd ansible/roles/restic_backup
molecule test
molecule test -- --skip-tags slow
```

Three Ubuntu releases, 22.04 first (oldest bash and systemd). The converge runs
in `test_mode`, so nothing is downloaded or started; `verify.yml` asserts what a
container can honestly prove:

- file modes and ownership
- **the throwaway passphrase appears nowhere outside `credentials/`**
- no drop-in uses `EnvironmentFile=`
- `systemd-analyze verify` accepts the unit
- **no timer was armed and nothing was installed**
- the legacy hostname was carried through verbatim

The passphrase-leak assertion is the one that earns its keep: a template that
accidentally interpolated a secret into the 0640 `bg-backup.conf` would be
invisible in review and obvious here.

## Requirements

`ansible.builtin` and `ansible.posix` only — nothing outside the modules bundled
with the distribution `ansible` package, per IAC-Ansible ADR-0001.

No `dependencies:` in `meta/main.yml`. A backup host need not be a Docker host;
the docker job is gated on `'docker_hosts' in group_names`.
