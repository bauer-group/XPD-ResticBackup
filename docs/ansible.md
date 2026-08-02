# Ansible integration

The role source of truth is [`ansible/roles/restic_backup`](../ansible/roles/restic_backup)
in this repository. It is **maintained in `bauer-group/IAC-Ansible`** under
`roles/restic_backup/`.

## Why the role lives there and not here

Two facts from IAC-Ansible decide it:

**ADR-0001** says managed hosts have zero Galaxy network dependency at runtime —
they are self-contained on the distribution `ansible` package. A role hosted in
this repository would have to reach the host somehow, and every mechanism for
that reintroduces the runtime dependency that ADR refuses.

**The `ansible-pull` model** means each host clones exactly one repository and
runs `site.yml` against itself. Anything not in that clone does not exist at
converge time.

So the split is: this repository owns the **product**, IAC-Ansible owns the
**role**, and the role is a thin driver. See
[ADR-0007](adr/0007-ansible-role-lives-in-iac-ansible.md).

## What the role does

Fetches a **pinned** release tarball with `ansible.builtin.get_url` and a
`checksum:`, then runs `install.sh --offline`.

Not `curl | bash`. That is right for a human bootstrapping one server; an
unattended converge wants a checksum assertion and a `changed_when` you can
reason about.

```yaml
restic_backup_version: "1.0.0"
restic_backup_release_checksum: "sha256:..."
```

Pinned deliberately: **no host takes a new backup tool version on a routine
`ansible-pull`.** Bumping it is a reviewed change.

## Variable contract

Every variable is prefixed `restic_backup_`. Full surface in
[`defaults/main.yml`](../ansible/roles/restic_backup/defaults/main.yml).

| Variable | Default | |
|---|---|---|
| `restic_backup_enabled` | `true` | master switch |
| `restic_backup_test_mode` | `false` | render everything, install and start nothing — for molecule |
| `restic_backup_version` | pinned | |
| `restic_backup_repo_prefix` | `{{ inventory_hostname }}` | see the note below |
| `restic_backup_prune_local` | **`false`** | see below |
| `restic_backup_jobs` | system + docker | list of job definitions |
| `restic_backup_notifiers` | `[uptime-kuma, email]` | |

### Secrets

Pulled from the `secrets` role in `defaults`, never hardcoded:

```yaml
restic_backup_password: "{{ secrets_restic_password | default('') }}"
restic_backup_s3_access_key_id: "{{ secrets_restic_s3_access_key_id | default('') }}"
```

Every credential task carries `no_log: true`.

Additions needed in IAC-Ansible's `roles/secrets`:

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

> **The prune credential is deliberately NOT in that list.** It must not be
> resolvable by any managed host. If it ever is, the append-only control is void.

### `restic_backup_prune_local: false`

This is a ransomware control, not a preference. `prune` deletes and rewrites pack
files; a host that can prune can destroy its own history, and so can anything
that compromises it. Retention runs from a management path with a separate
identity.

## Targeting

A **functional** inventory group:

```yaml
restic_backup_hosts:
  hosts: {}
```

Not group code 72 — that describes a host which *is* a backup server, not one
that gets backed up. Different axis entirely.

### Legacy hostnames

Some hosts use an older naming scheme that does not match `AAAA-GG` (for example
`25000-040.cloud.bauer-group.com`). `parse_asset_hostname` returns
`valid: false` for those.

**Never derive an asset id or group code from the hostname, and never assert the
schema.** The repository prefix uses `{{ inventory_hostname }}` verbatim, and
`bg-backup doctor` checks only "the repository path ends with my FQDN" — which is
schema-free. An assert on the naming convention here would be a bug, not a
feature: it would fail on exactly the oldest and often most important servers.

## site.yml

Append as the **last** phase:

```yaml
# --- Phase 9: Backup & disaster recovery ---
# Last on purpose: backup jobs quiesce services and enumerate paths that earlier
# phases create. Arming a timer before those exist means the first scheduled run
# stops a service that was never configured.
- name: "Phase 9: Restic backup and disaster recovery"
  hosts: restic_backup_hosts
  become: true
  gather_facts: true
  tags: [backup, restic, dr]
  pre_tasks:
    - name: Skip host when restic_backup disabled
      ansible.builtin.meta: end_host
      when: not (restic_backup_enabled | default(true) | bool)
  roles:
    - role: restic_backup
```

## Makefile

```make
backup: ## Apply the restic_backup role only (Phase 9)
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags backup $(EXTRA_ARGS)

backup-status: ## Show timer and last-run status
	ansible -i $(INVENTORY) restic_backup_hosts -m ansible.builtin.command \
	  -a "/usr/local/sbin/bg-backup status" --become $(LIMIT_ARG)
```

Add both to `.PHONY`, mirroring the existing `k0s` / `k0s-status` pair.

## molecule-test.yml

Two edits: add `restic_backup` to the `workflow_dispatch` choice list, and to the
matrix:

```yaml
- role: restic_backup
  scenario: default
```

## The assertion worth having

`tasks/assert.yml` compares `df -P /var/lib/docker` against `df -P /` and **fails
the converge** when they differ while `one_file_system` is true and
`/var/lib/docker` is not an explicit source.

A failed converge is loud and gets fixed. A silent half-backup is discovered
during a restore.

## Rollout

1. add the host to `restic_backup_hosts` and the vault entries
2. `make check LIMIT=<host>` — a dry run should report **no changes** on a host
   already configured by hand. A converge that wants to change everything means
   the manual install and the role disagree, and it is far better to learn that
   now than unattended.
3. `make deploy LIMIT=<host> TAGS=backup`
4. let `ansible-pull` own it

Do not bulk-enable. See [runbooks/onboarding-a-host.md](runbooks/onboarding-a-host.md).
