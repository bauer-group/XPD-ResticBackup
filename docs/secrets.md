# Secrets and keys

## The bootstrap problem

The repository passphrase cannot live only inside the repository it opens. After
a total loss you have exactly what you deliberately put somewhere else, in
advance.

Three layers, each covering what the previous one cannot:

| Layer | Covers | Fails when |
|---|---|---|
| **recovery card** (printed, password manager) | everything — it is the root of trust | it was never written down |
| **config snapshot** in the repository (`tag: bg-backup-config`) | configuration loss with credentials intact | the repository cannot be opened |
| **recovery bundle** (encrypted, off-host) | both at once | it is stale, or only exists on the host it protects |

## On the host

```
/etc/bg-backup/credentials/          0700 root:root
├── repo.env      repository URL + backend credentials      0400
├── repo.key      the passphrase                            0400
└── notify.env    webhook URLs and push tokens              0400
```

`repo.env` is a plain sourceable shell fragment on purpose:

```bash
source /etc/bg-backup/credentials/repo.env && restic snapshots
```

**The passphrase is not in it.** `--stdin-from-command` and every hook spawn child
processes that inherit this environment; an inline `RESTIC_PASSWORD` would be
readable by every database dump command the tool runs. It lives in `repo.key` and
is reached via `RESTIC_PASSWORD_FILE`.

The permission gate **refuses** rather than warns. A warning gets ignored; a
refusal gets fixed.

### systemd

```ini
LoadCredential=repo-password:/etc/bg-backup/credentials/repo.key
```

Not `EnvironmentFile=`. That merges values into the unit environment, which
systemd exposes to **any local user** via `systemctl show -p Environment`.
`LoadCredential=` puts them in a per-invocation root-only `ramfs` that is never
swapped and is torn down when the unit exits. Available since systemd 247, so
safe on 22.04, 24.04 and 26.04. See
[ADR-0003](adr/0003-loadcredential-not-environmentfile.md).

### Never in argv

`/proc/<pid>/cmdline` is world-readable; `/proc/<pid>/environ` is not. So:

- bg-backup never accepts a secret as a command-line flag
- database engines read the password **inside the container** from the
  container's own environment — bg-backup never stores a database credential at
  all
- a unit test asserts no built restic argv contains a registered secret

## Redaction

Everything leaving the process — journal, log files, notifier payloads, `.prom`
files, `doctor` output — passes `redact()`. Two layers:

**Registered literals.** The passphrase, backend keys, webhook URLs. Exact and
cheap, but only covers what the tool was told about.

**Structural patterns.** Credentials embedded in a URL, bearer tokens, push
tokens, `Authorization:` headers, AWS key shapes, `?token=` query parameters.
This is what protects a secret the tool was **never told about** — an access key
an operator interpolated into a custom endpoint, a password in a hook's error
message.

Layer one alone would be theatre. Stated plainly rather than implied:
**redaction cannot protect what it has never seen.** Read output before you paste
it, even redacted output.

```bash
bg-backup doctor      # includes a redaction self-test
```

## The recovery bundle

```bash
bg-backup config export --out /root/bg-backup-recovery.age
```

Contents: repository URL and backend credentials (primary and secondary), the
passphrase, the recovery key's passphrase, the complete `/etc/bg-backup`, the
system facts `dr plan` needs, which repository keys exist, and a plaintext
`RECOVER.txt`.

**Encrypted three ways, every time:**

| Tool | Availability on a rescue image | Integrity |
|---|---|---|
| `age` | universe package, often absent from minimal images — a static binary ships beside the bundle | AEAD |
| `gpg --symmetric` | on nearly every Ubuntu server image | AEAD |
| `openssl enc` | effectively universal | **none** — hence the ciphertext SHA-256 on the printed sheet |

Three independent tool paths mean no single missing package blocks a recovery.

Every ciphertext is **decrypted again and byte-compared** before it is accepted.
A bundle that has never been round-tripped is not a bundle; it is a hope.

The tar is deterministic — sorted entries, fixed mtimes — so the same content
produces the same SHA-256 and "did the bundle change?" is answerable.

### Where copies go

3-2-1 applied to the bundle, not just the data:

1. a second S3 path with **different credentials** — never the same bucket prefix
   as the repository, or a bucket-wide deletion takes the data and the means to
   recover it at once
2. Ansible Vault or HashiCorp Vault
3. the team password manager
4. an encrypted USB stick in the safe
5. the printed recovery sheet

`doctor` warns when the bundle is older than `BGB_ESCROW_MAX_AGE_DAYS`, and — more
usefully — when the **configuration hash has changed since the last export**. That
is the most common way this story quietly rots: someone adds a credential and
never re-exports, so the bundle restores a configuration that no longer works.

## The three-key model

restic separates the master key from repository keys, so a passphrase rotation is
O(1) and touches no snapshot.

| Key | Passphrase lives | Purpose |
|---|---|---|
| `host:<fqdn>` | on the host | routine backups |
| `ops:recovery` | **never on the host** | disaster recovery; survives a host compromise |
| `ops:prune` | ops vault only | retention, from a management path |

With a recovery key, a host compromise costs one `restic key remove`. Without
one, it costs the repository.

```bash
bg-backup secrets add-recovery-key
bg-backup secrets rotate-repo-password
```

Rotation adds the new key, **proves it works from a clean environment**, and only
then removes the old one. Removing first and discovering the new key is wrong
afterwards leaves the repository unreachable with either.

> ⚠️ `restic key remove` does **not** re-encrypt the master key. Anyone who ever
> obtained the master key material retains access to every snapshot that already
> exists. After a host compromise you need a **new repository**, not a rotated
> key. Rotation defends against a stolen *password*, not a stolen *key*.

Order of operations after a compromise: rotate the **S3 credential first** (that
stops further writes), then remove the host key from a clean machine, then
`restic check --read-data` to establish whether the history is intact, and only
then rebuild. Removing the key first while the attacker still holds the S3
credential achieves nothing.

## The recovery sheet

```bash
bg-backup secrets print-recovery-card --out /root/recovery-sheet.txt
```

One page. It contains no secret **values** — it names where each one lives. Its
most important section is *Recovery with no tooling at all*: the raw restic
commands, so a human with only that page and a restic binary can recover.

Print two copies, two locations, sealed. Regenerate on every credential change.

> If a disaster-recovery rehearsal needs information that is **not** on the sheet,
> the sheet is wrong. That counts as a failed rehearsal, not a footnote.
