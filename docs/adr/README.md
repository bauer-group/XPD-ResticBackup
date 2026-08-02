# Architecture Decision Records

Why things are the way they are — and, in the **Revisit when** section, what
would change the answer. That last section is what keeps an ADR from becoming a
tombstone.

| # | Decision | Short version |
|---|---|---|
| [0001](0001-bash-cli-instead-of-resticprofile.md) | Bash CLI + systemd, not resticprofile | resticprofile solves scheduling; none of the four requirements |
| [0002](0002-pinned-verified-restic-binary.md) | Pinned, GPG-verified restic binary | 22.04 ships 0.12.1 — no `--stdin-from-command` |
| [0003](0003-loadcredential-not-environmentfile.md) | `LoadCredential=`, not `EnvironmentFile=` | the latter is readable by any local user |
| [0004](0004-application-level-docker-backup.md) | Application-level Docker backup | overlay2 ties the restore to one Docker version |
| [0005](0005-append-only-and-separate-prune-identity.md) | Append-only + separate prune identity | a host credential must not be able to destroy history |
| [0006](0006-pluggable-notifiers.md) | Pluggable notifiers | a notifier must never fail the backup |
| [0007](0007-ansible-role-lives-in-iac-ansible.md) | The role lives in IAC-Ansible | ADR-0001 there forbids runtime Galaxy dependencies |
| [0008](0008-bats-and-container-rig.md) | bats + container rig | test the bugs that happened, not the obvious |
| [0009](0009-no-s3-object-lock-with-restic.md) | No S3 Object Lock | restic is not lock-free; it bricks the repository |
| [0010](0010-one-repository-per-host-in-a-shared-bucket.md) | One repository per host | blast radius over cross-host deduplication |
| [0011](0011-exit-codes-are-a-scheduling-interface.md) | Exit codes are an interface | exit 3 means different things on different jobs |

## Format

Status · Date · Deciders · Context · Decision · Consequences (Positive +
**Accepted trade-off**) · Alternatives considered · **Revisit when**

The two bold sections are the ones that earn their keep. A decision without a
stated cost was not a decision, and a decision without a revisit condition
outlives its reasoning.
