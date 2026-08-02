# Exit codes

These are an **interface**, not an implementation detail. systemd, Ansible,
monitoring probes and operators all key off them. Adding a code is allowed;
renumbering one is a breaking change.

| Code | Name | Meaning | What to do |
|---|---|---|---|
| `0` | OK | success | nothing |
| `1` | FAIL | fatal error, **no snapshot** | investigate now — there is no backup from this run |
| `2` | USAGE | unknown flag, missing argument | fix the command |
| `3` | PARTIAL | snapshot written, some sources unreadable | see below |
| `4` | PRECOND | not root, missing dependency, invalid config | fix the host |
| `5` | LOCKED | another instance holds the lock | usually self-resolving; check for an overlapping schedule |
| `6` | REPO | repository unreachable, uninitialised, or wrong key | check credentials and network |
| `7` | VERIFY | `check` or `verify` found damage | **treat as a backup outage** |
| `8` | HOOK | a pre/post hook failed | the snapshot may still exist; check the hook |
| `9` | SAFETY | a safety rail refused a destructive operation | read the message — this is the tool preventing data loss |
| `130` | INTERRUPT | SIGINT / SIGTERM | quiesce was reversed; re-run |

## Why 3 is separate

Exit 3 is deliberately **not** collapsed into 0 or 1. It is the difference
between "some files were unreadable" and "no backup exists", and a tool that
loses that distinction teaches its operators to ignore both.

The same code means different things depending on the job:

| Context | Meaning | Default handling |
|---|---|---|
| **live** run (`JOB_QUIESCE=none`) | rotating logs, sockets, files deleted mid-run | normal — `JOB_PARTIAL_IS_FAILURE=0` |
| **quiesced** run | files were unreadable *with services stopped* | a real signal — set `JOB_PARTIAL_IS_FAILURE=1` |

The unreadable-file **count** is recorded in the job state and exported as
`bg_backup_files_unreadable`. The **paths** stay in the local log:
`BGB_NOTIFY_INCLUDE_PATHS=0` by default, because the filenames on a host are an
information disclosure to an external endpoint while the count is the part that
is actually actionable.

## Severity ordering

`backup --all` returns the **worst** result, and worst is not numeric order — 3
is less severe than 1:

```
0  <  3  <  8  <  7 = 9  <  5  <  6  <  4 = 2  <  1  <  130
```

A run that produced a degraded snapshot never reports worse than one that
produced none at all.

## Mapping from restic

| restic | bg-backup | |
|---|---|---|
| 0 | 0 | |
| 1 | 1 | |
| 3 | 3 | some source files unreadable |
| 10 | 6 | repository does not exist |
| 11 | 6 | already locked |
| 12 | 6 | wrong password |

restic gained the distinct 10/11/12 codes in 0.17. Below that everything
collapses into 1, which makes an alert untriageable — hence
`BGB_RESTIC_MIN_VERSION=0.17.0` and why distribution packages are not used.

Codes 10 and 12 are **never retried**: they do not become true by trying again,
and retrying scrolls the real error off the top of the log.

## In systemd

```ini
SuccessExitStatus=3
```

is **not** set on the templated unit. Exit 3 marks the unit failed, which fires
`OnFailure=bg-backup-failure@%i.service`, which reports it as a warning rather
than a page. That keeps the distinction visible in `systemctl` instead of hiding
it behind a success.

## In a script

```bash
bg-backup backup --all
rc=$?
case "$rc" in
  0) ;;
  3) echo "degraded: some files unreadable" >&2 ;;
  9) echo "a safety rail refused - read the message, do not force" >&2; exit 1 ;;
  *) echo "backup failed: rc=$rc" >&2; exit 1 ;;
esac
```
