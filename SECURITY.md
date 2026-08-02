# Security Policy

bg-backup holds the credentials to every backup a server has. This document is
about what that does and does not protect you from, stated plainly enough to be
useful at 03:00.

---

## Supported versions

| Version | Supported | Notes |
| --- | --- | --- |
| `main` | ✅ | Fixes land here first. |
| Latest release | ✅ | Security fixes are backported to the latest tag. |
| Anything older | ❌ | Upgrade. `bg-backup self-update` is one command and does not touch your configuration. |

Supported platforms are Ubuntu 22.04, 24.04 and 26.04 LTS. 22.04 is the floor —
bash 5.1 and systemd 249 — and a fix that only works on newer releases is not a
fix.

While the project is pre-1.0, "latest release" means exactly that: the newest
tag, not the newest of each minor line.

---

## Reporting a vulnerability

**Do not open a public issue.** A vulnerability in a tool that runs as root on
other people's fleets cannot be un-published.

Use either:

- GitHub's private advisory form:
  [Report a vulnerability](https://github.com/bauer-group/XPD-ResticBackup/security/advisories/new)
- Email: **security@bauer-group.com**

What helps: the version (`bg-backup version`), Ubuntu release, repository
backend, and the smallest reproduction you can manage. If you have a patch, say
so — but do not open the pull request until we have agreed how to disclose it.

Our commitments:

| Stage | Target |
| --- | --- |
| Acknowledgement that a human has read it | **2 business days** |
| Assessment, severity, and a plan | 10 business days |
| Fix released, or a written explanation of why longer | **30 days** |
| Public advisory and credit (if you want it) | With the fix, or coordinated with you |

If you do not hear back within two business days, assume the mail was lost
rather than ignored, and chase it — the advisory form is the more reliable of
the two channels.

---

## Threat model — read this before trusting anything below

**bg-backup runs as root by design and has no privilege boundary of its own.**
It reads every file on the system, stops and starts containers, dumps
databases, and writes to the systemd unit directory. Anyone who can modify its
configuration, its hooks, or its binaries already has root by another name.
There is no sandbox here, and pretending otherwise would be worse than useless:
it would encourage people to grant access to `/etc/bg-backup` on the assumption
that it is "just the backup config".

So the security property this tool actually offers is a narrower and much more
useful one:

> **A credential that bg-backup holds must not be able to destroy backup
> history.**

That is the whole game. Root on the production host is assumed to be reachable
by an attacker — ransomware operators reach it routinely. The question that
decides whether you recover is what those credentials can do to the repository
once they have them. Every recommendation below serves that one property.

Two consequences worth stating explicitly:

- **`/etc/bg-backup/credentials/` is root-owned and `0400`.** If a non-root user
  can read it, the repository is compromised, and bg-backup refuses to run
  rather than warn.
- **A compromised host means a compromised repository password**, always. See
  [Rotating the repository password](#rotating-the-repository-password) — the
  honest answer there is not the one people expect.

---

## Do not paste output unredacted

`bg-backup doctor`, `--json` output, and the journal all pass through the
tool's redaction layer, and it is genuinely good at what it does.

**It protects the fields it knows about.** That is the entire limitation, and it
is a real one:

- A passphrase in a place bg-backup does not model — a hook script's argument, a
  `curl` line you typed by hand while debugging — is not a known field and is
  not masked.
- An endpoint hostname, a bucket name, a job name, a path: none of these are
  secrets *to the tool*, so none are masked. They may be secrets *to you*. A
  bucket named after a customer discloses that customer.
- Redaction operates on the message it is given. Output you captured with
  `restic` directly never went through it at all.

**Read the output before you paste it, not after.** If a credential does reach a
public issue, a chat channel, or a ticket: **rotate it first**, immediately, and
then worry about deleting the message. Deletion is not a control — the moment it
was submitted, it was public.

---

## How bg-backup handles credentials

These are promises the code keeps, and each one has a specific failure mode
behind it.

**No secret is ever passed as a command-line flag.**
`/proc/<pid>/cmdline` is world-readable on Linux. Every database dump command
and every hook we spawn can list the process table, so a passphrase on the
`restic` command line is readable by the unprivileged user running your
application's dump. Secrets travel by environment or by a `0400` file:
`RESTIC_PASSWORD_FILE`, never `RESTIC_PASSWORD`.

**The repository passphrase is in its own file, not in `repo.env`.**
`repo.env` is sourced and therefore inherited by every child process — including
`--stdin-from-command` dump commands. The passphrase lives in `repo.key`
(`0400`) and is reached only through `RESTIC_PASSWORD_FILE`, so a dump command
inherits a *path*, not a secret.

**systemd units use `LoadCredential=`, not `EnvironmentFile=`.**
`EnvironmentFile=` puts the contents into the unit's environment block, which
`systemctl show` will print, which the journal may capture, and which every
child inherits. `LoadCredential=` exposes the material as a file under
`$CREDENTIALS_DIRECTORY`, readable only by the service, unmounted when the unit
stops, and invisible to `systemctl show`.

**Loose permissions are a refusal, not a warning.**
Every configuration and credential file is checked before it is sourced:
root-owned, mode `0640` or tighter (`0400` for credentials), whitelisted keys
only, no command substitution. If a file is group- or world-readable,
bg-backup **exits** — it does not print a warning and continue. A warning in an
unattended timer run is a message nobody will ever read, and "it kept working"
is exactly how a world-readable credential file survives for two years.

**Config files are linted before they are sourced.**
Sourcing a shell fragment executes it. The lint pass rejects command
substitution and unknown keys, so a modified config cannot become arbitrary
code execution as root by way of `$(...)` — a thin protection given the threat
model above, but it costs nothing and it catches accidents.

---

## Ransomware and repository integrity

This is the section that matters. Everything else on this page is hygiene; this
is the part that decides whether you still have backups after an incident.

The assumption: **the attacker has root on the backed-up host and therefore has
every credential bg-backup holds.** The goal: they still cannot destroy the
history.

### rest-server in append-only mode

If you control the backup server, this is the strongest and simplest answer:

```bash
rest-server --path /srv/restic --append-only --private-repos
```

In append-only mode the server accepts writes and refuses deletes, at the
protocol level. A compromised client can add data and can *read* it, but cannot
remove a single pack file — not with `forget`, not with `prune`, not with a
hand-rolled HTTP DELETE. Retention then runs from the backup server itself, on
a schedule the client cannot influence.

Note what append-only does **not** give you: the client can still read every
snapshot it has the password for. Append-only protects availability of history,
not confidentiality.

### S3: the policy, and why it looks the way it does

For an S3-compatible backend, scope the identity to this host's prefix and deny
deletes — with **one deliberate exception**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOnlyThisPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::<bucket>",
      "Condition": { "StringLike": { "s3:prefix": ["<prefix>/*"] } }
    },
    {
      "Sid": "ReadWriteNoDelete",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::<bucket>/<prefix>/*"
    },
    {
      "Sid": "DeleteLocksOnly",
      "Effect": "Allow",
      "Action": ["s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<bucket>/<prefix>/locks/*"
    }
  ]
}
```

**Why `DeleteObject` is allowed under `locks/` and nowhere else.** restic is not
a lock-free format. Every run writes a lock object into `<prefix>/locks/` and
removes it on exit. Deny deletes outright and the lock is never cleaned up: the
second run finds a stale lock, the third finds two, and within a day every
operation fails with "repository is already locked" — including the
`restic unlock` that would fix it, because that command's job is to *delete*
lock objects. The failure looks like a hang, not a permissions problem, and it
is a genuinely expensive afternoon to diagnose. Scoping the delete to `locks/*`
gives restic exactly the one destructive operation it structurally requires and
nothing else.

**The honest limitation.** `PutObject` without `DeleteObject` prevents deletion.
It does **not** prevent *overwrite*: on a normal bucket, `PutObject` to an
existing key replaces its contents. An attacker who cannot delete your pack
files can still overwrite them with garbage. restic's content-addressed layout
means the corruption is detectable — `restic check --read-data` recomputes every
pack's hash and will find it — but detection is not prevention, and by the time
a weekly `check` finds it the healthy copy is gone. Enable bucket **versioning**
if your provider offers it (versioning turns an overwrite into a new version and
keeps the old one, and the same policy above then prevents deleting versions),
and treat the S3 policy as a strong speed bump rather than a wall.

### Why S3 Object Lock does not work with restic

The instinct is right and the mechanism is wrong. Object Lock with a bucket
**default retention** period applies to *every* object written to the bucket —
including the lock objects under `locks/`. Those are exactly the objects restic
must delete on every single run. With a default retention of even a few days:

1. Run 1 writes and cannot delete its lock. Run 1 leaves it behind.
2. Run 2 sees a stale lock and waits, or fails.
3. `restic unlock` cannot delete it either — the object is immutable until its
   retention expires.
4. Within days the repository is unusable, and it stays unusable until the
   retention period on the accumulated lock objects lapses.

You also cannot `prune`, ever, so the repository grows without bound.

Object Lock is a good control for a bucket full of write-once archives. A restic
repository is not that — it is a live data structure with mutable metadata. Do
not put a default retention policy on it. (Object Lock applied *selectively* to
`data/` only, via a mechanism that never touches `locks/`, `index/`, `keys/` or
`snapshots/`, is theoretically possible and practically fragile; we do not
recommend it.)

### The recommendation that actually holds: a pull-side copy

The control that survives full root compromise of the production host is
architectural, not permission-based:

> **A second repository, on infrastructure the production host cannot reach,
> filled by a job that PULLS. No credential for the copy repository exists
> anywhere on the production host.**

The copy host holds read access to the primary repository and write access to
the copy. The production host holds neither. An attacker with root on
production can corrupt the primary and cannot touch the copy, because there is
nothing on the compromised machine that names it, addresses it, or authenticates
to it.

Create the copy repository like this, and pay attention to the second flag:

```bash
restic -r <copy-repo> init \
  --from-repo <primary-repo> \
  --copy-chunker-params
```

`--copy-chunker-params` is not optional. restic's content-defined chunking is
seeded per repository; a copy repository created without it re-chunks every
blob, so nothing deduplicates against the primary's boundaries. The copy then
grows to several times the size of the source, the first copy run takes days
instead of hours, and — worst — this is not fixable after the fact. You would
have to destroy the copy repository and start over. `bg-backup copy` checks for
this and refuses to run against a mismatched repository rather than quietly
uploading a fortune's worth of duplicate data.

Verify the copy on its own schedule (`restic check --read-data-subset`), from
the copy host. A backup nobody has ever read is a hypothesis.

---

## Rotating the repository password

Adding and removing keys is routine and safe:

```bash
restic key list
restic key add                       # prompts for the new password
restic key remove <old-key-id>       # after verifying the new one works
```

Always add before removing, and verify the new key with a real
`restic snapshots` before removing the old one. Removing your only working key
ends the repository permanently — there is no recovery path, by design.

**And now the part people are usually surprised by.**

restic encrypts your data with a **master key**. Each repository password
encrypts a *copy* of that master key, and that is all a "key" is in
`restic key list`. `restic key remove` deletes one wrapped copy. It **does not
re-encrypt the master key and does not re-encrypt any data.**

Therefore: if an attacker ever read the master key — which anyone with root on a
host holding a valid repository password can do, since that password unwraps it
— then rotating the repository password accomplishes **nothing**. The attacker
retains the master key and can decrypt every existing snapshot and every future
one written to that repository. The rotation locks a door whose key has already
been copied.

**After a host compromise, the only correct response is a NEW repository.**
Initialise it, back up into it fresh, and keep the old repository read-only for
as long as you need its history — understanding that its contents must be
considered disclosed. Password rotation is appropriate for password *hygiene*
(someone left the company, the passphrase was on a whiteboard, it went into a
chat message). It is not a response to compromise, and treating it as one leaves
you feeling protected while nothing has changed.

---

## Scope

**In scope** — please report:

- Any way a credential reaches argv, a log file, the journal, a notifier
  payload, or `systemctl show`.
- Any path where redaction fails to mask a field it is supposed to mask.
- Privilege escalation from a non-root user, via config, hooks, unit files, the
  temp directory, the state directory, or a symlink race.
- `install.sh` or `self-update` fetching, verifying, or executing something it
  should not — signature verification bypass, TOCTOU on the downloaded binary,
  path injection into the install prefix.
- A destructive operation (`forget`, `prune`, `restore --target`, `unlock`)
  that can be made to act outside its intended scope — most importantly, one
  host affecting another host's snapshots in a shared bucket.
- Command injection through a job name, path, tag, hostname, or any other
  operator-supplied string.
- Anything that causes a backup to report success while storing incomplete or
  corrupt data. Silent data loss is a security issue here, not a bug.

**Out of scope:**

- "bg-backup runs as root." That is the design, stated above.
- "Someone with root can read the credentials." Same.
- Vulnerabilities in restic, Docker, systemd, or your S3 provider — report those
  upstream. If bg-backup *uses* one of them unsafely, that is in scope and we
  want to hear about it.
- Missing hardening on a host you configured against the documentation
  (world-readable config, credentials in `/tmp`, a repository shared between
  hosts without prefix scoping).
- Automated scanner output with no demonstrated impact.
- Denial of service that requires the privileges the tool already has.

---

## For operators: a five-line self-check

```bash
sudo bg-backup doctor                # permissions, prefix scoping, repo reachability
sudo namei -l /etc/bg-backup/credentials/repo.key   # every component root-owned?
sudo restic snapshots --host $(hostname -f) | tail  # is anything actually landing?
sudo bg-backup check --read-data-subset 5%          # is what landed readable?
sudo bg-backup dr rehearse --dry-run                # do you know how to get it back?
```

The last one is the only one that answers the question you actually care about.
