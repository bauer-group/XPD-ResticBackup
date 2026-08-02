# Recovery Sheet

One printed page. It is what stands between a total loss and a recovery.

```bash
bg-backup secrets print-recovery-card --out /root/recovery-sheet.txt
```

## Rules

**It names where each secret lives; it does not contain the values** — except the
fields you fill in by hand, which is why it is handled as a confidential
document. Two printed copies, two locations, sealed, opening logged.

**Regenerate it on every credential change.** A sheet pointing at a rotated
passphrase is worse than no sheet: it produces confident, wrong attempts during
an incident.

**Section 4 is the point.** A human with only this page and a restic binary must
be able to recover. If a rehearsal needs anything that is not on the sheet, the
**sheet is wrong** — and that counts as a failed rehearsal, not a footnote.

## Template

```
+----------------------------------------------------------------------+
| BAUER GROUP - BACKUP RECOVERY SHEET                     CONFIDENTIAL  |
+----------------------------------------------------------------------+
 Host            <fqdn>
 Generated       <date>                    Sheet   RS-<year>-<nnnn>
 Tool            bg-backup <ver> / restic <ver>
 Verify by       <date + 90 days>          Supersedes  RS-<...>

 1  PRIMARY REPOSITORY
    URL           ________________________________________________
    Repository ID ________________
    S3 key id     ________________________  (password manager entry: ____)
    S3 secret     ________________________  (password manager entry: ____)
    Passphrase    ________________________  (password manager entry: ____)

 2  RECOVERY KEY   (independent; never stored on the host)
    Passphrase    ____ ____ ____ ____ ____ ____

 3  RECOVERY BUNDLE
    Local         /var/lib/bg-backup/export/bg-backup-config.tar.age
    Escrow        ________________________________________________
    Safe          USB "DR-__"
    Content SHA   ________________________________________________
    Bundle pass   ________________________  (password manager entry: ____)
    age binary    static, beside the bundle;  sha256 ________________

 4  RECOVERY WITH NO TOOLING AT ALL
    export RESTIC_REPOSITORY='<section 1>'
    export AWS_ACCESS_KEY_ID='<section 1>'
    export AWS_SECRET_ACCESS_KEY='<section 1>'
    export RESTIC_PASSWORD='<section 1>'

    restic snapshots
    restic snapshots --tag run=<id>          # ONE complete run
    restic restore <snap> --target /mnt/restore
    restic dump <snap> /db/postgres/<container>/<db>.dump | pg_restore -d <db>

    Restore BY RUN, not by "latest" per snapshot: one backup produces several
    snapshots, and resolving each independently pairs a database dump from one
    day with volume contents from another.

    Tags: kind=files | kind=dbdump | kind=image | run=<id> | job=<name>

 5  RECOVERY WITH bg-backup
    curl -fsSL https://raw.githubusercontent.com/bauer-group/\
      XPD-ResticBackup/main/install.sh | bash
    bg-backup dr bootstrap        # or: config import --in <bundle>
    bg-backup dr plan             # READ-ONLY report
    bg-backup dr run --phase all
    bg-backup dr verify

 6  DO NOT RESTORE BLINDLY
    /boot, /etc/fstab, /etc/netplan, /etc/machine-id and the account databases
    are NEVER written automatically. On new hardware, stale disk UUIDs drop the
    host into an emergency shell and old interface names leave it unreachable.
    Apply netplan only with:  netplan try --timeout 120
    Validate sshd first with: sshd -t -f <staged config>

 7  ESCALATION
    Backup failing > 48h    _______________________________
    Disaster recovery       _______________________________
    Passphrase lost         ESCALATE IMMEDIATELY. Without it the data is
                            permanently unreadable. No back door exists.

 8  LAST DR TEST
    Date __________  RTO __________  Result __________  By __________
+----------------------------------------------------------------------+
```

## Filling it in

**Section 1** — the repository path must end with **this host's** FQDN. In a
shared bucket that is what keeps one host's retention from deleting another's.

**Section 2** — leave blank if no recovery key exists, and then read
[secrets.md](secrets.md): without one, a host compromise costs the repository
rather than one `restic key remove`.

**Section 3** — the `age` binary's hash matters. A rescue image usually has no
`age`, so a static copy travels with the bundle; the hash is how you know it is
the right one.

**Section 8** — an unsigned sheet is an untested backup.

## Storage

| Copy | Where |
|---|---|
| 1 | company safe, sealed |
| 2 | second location (off-site, different building) |
| digital | password manager, as the entries referenced above |

Never in the repository it protects, and never only on the host it protects.
