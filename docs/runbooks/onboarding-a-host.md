# Runbook: Host aufnehmen

**Owner:** [Name/Team eintragen] | **Frequenz:** Pro neuem Server
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

Etwa 30 Minuten, davon das meiste Wartezeit beim ersten Backup.

> **Nicht in Serie ausrollen.** Ein Backup-Werkzeug, das zehn Hosts still falsch
> konfiguriert, ist schlechter als eines, das einer nach dem anderen von Hand
> eingerichtet wurde. Der Ansible-Weg kommt, wenn der erste Host beweisbar
> funktioniert.

---

## 1. Storage vorbereiten

Ein eigener Service-Account **pro Host**, auf das eigene Prefix beschränkt:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListOwnPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::backup-server"],
      "Condition": { "StringLike": { "s3:prefix": ["<fqdn>/*"] } } },
    { "Sid": "ReadWriteOwnPrefix",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::backup-server/<fqdn>/*"] },
    { "Sid": "DeleteLocksOnly",
      "Effect": "Allow",
      "Action": ["s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::backup-server/<fqdn>/locks/*"] }
  ]
}
```

> **`DeleteObject` nur unter `locks/`.** restic schreibt bei jedem Lauf ein
> Lock-Objekt und räumt es beim Beenden weg. Ein pauschales Delete-Verbot lässt
> nach jedem Lauf ein Stale Lock zurück, und ab dem dritten Lauf braucht das
> Repository ein `unlock`, das ebenfalls nicht gelingt.
>
> Ehrliche Einschränkung: `PutObject` ohne Delete erlaubt weiterhin
> **Überschreiben**. Dagegen hilft Versionierung oder ein Pull-Copy-Repository.

- [ ] Service-Account angelegt, Prefix = FQDN des Hosts
- [ ] Policy geprüft — **nicht** bucket-weit

---

## 2. Installieren

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
bg-backup version
```

---

## 3. Einrichten

```bash
bg-backup init
```

- Backend: S3/MinIO
- Endpoint und Bucket
- Pfad muss auf den **FQDN dieses Hosts** enden — der Wizard schlägt es vor
- Passphrase generieren lassen
- Profil: `docker` bei Docker-Hosts, sonst `server`
- Recovery-Key anlegen: **ja**

Am Ende erscheint die Recovery Card. Wirklich speichern, nicht wegklicken.

- [ ] Recovery Card im Passwort-Manager
- [ ] Recovery-Key-Passphrase im Passwort-Manager (steht nirgends sonst)

---

## 4. Hinsehen, bevor der Timer läuft

```bash
bg-backup discover
```

Drei Dinge prüfen:

- [ ] **Liegt `/var/lib/docker` auf eigenem Dateisystem?** Dann in
      `JOB_EXTRA_PATHS`, sonst überspringt `--one-file-system` es still.
- [ ] **Werden alle Datenbanken erkannt?** Meldet eine `degraded`, steht dort
      auch warum — und das ist eine echte Lücke, bis sie behoben ist.
- [ ] **Gibt es Images ohne Registry-Digest?** Dann
      `JOB_DOCKER_EXPORT_IMAGES=missing`, sonst sind diese Stacks nicht
      wiederherstellbar.

```bash
bg-backup doctor
```

Muss ohne `✗` durchlaufen.

---

## 5. Erstes Backup von Hand

```bash
bg-backup backup --all
bg-backup snapshots
bg-backup status
```

Der erste Lauf ist der langsame — alles ist neu.

---

## 6. Restore beweisen

**Der Schritt, der aus einer Hypothese ein Backup macht.**

```bash
bg-backup restore preview file --path /etc/hostname
bg-backup restore file --path /etc/hostname --to /tmp/check
cat /tmp/check/etc/hostname

bg-backup verify
```

- [ ] `verify` grün

Bei Docker-Hosts zusätzlich einen Dump prüfen:

```bash
bg-backup restore db --db postgres/<container>/<db>.dump --into scratch
```

---

## 7. Recovery Bundle

```bash
bg-backup config export --out /root/bg-backup-recovery.age
bg-backup secrets print-recovery-card --out /root/recovery-sheet.txt
```

- [ ] Bundle **vom Host herunterkopiert** — eines, das nur auf dem gesicherten
      Host liegt, schützt nichts
- [ ] Sheet gedruckt und abgelegt
- [ ] Bundle an die Escrow-Ziele verteilt

---

## 8. Benachrichtigung

`/etc/bg-backup/bg-backup.conf`:

```bash
BGB_MONITOR_KUMA_PUSH_URL="https://kuma.example.com/api/push/<token>"
BGB_MONITOR_MAIL_TO="support@support.bauer-group.com"
```

In Uptime Kuma einen Push-Monitor anlegen, Intervall = Job-Zeitplan + Toleranz.

- [ ] Ein absichtlich erzeugter Fehler erreicht nachweislich einen Menschen

Das ist der Test, der übersprungen wird, und der einzige, der beweist, dass die
Überwachung funktioniert.

---

## 9. Jetzt erst den Timer

```bash
bg-backup schedule sync
bg-backup schedule enable
systemctl list-timers 'bg-backup*'
```

---

## 10. Unter Ansible nehmen

Erst wenn Schritt 1–9 durch sind.

```yaml
# inventory/production/hosts.yml
restic_backup_hosts:
  hosts:
    <fqdn>: {}
```

Vault-Einträge ergänzen, dann:

```bash
make check LIMIT=<fqdn>
```

> Ein Dry-Run auf einem bereits von Hand konfigurierten Host sollte **keine
> Änderungen** melden. Will der Converge alles ändern, weichen Handinstallation
> und Rolle voneinander ab — das jetzt zu erfahren ist erheblich besser als
> unbeaufsichtigt.

```bash
make deploy LIMIT=<fqdn> TAGS=backup
```

---

## Abschluss-Checkliste

- [ ] Eigener, prefix-scoped Service-Account
- [ ] Repository-Prefix = FQDN
- [ ] `doctor` ohne `✗`
- [ ] Erstes Backup erfolgreich
- [ ] **Restore bewiesen**, nicht angenommen
- [ ] Recovery Bundle vom Host herunter
- [ ] Recovery Sheet gedruckt
- [ ] Benachrichtigung erreicht einen Menschen
- [ ] Timer aktiv
- [ ] Im Inventory, Converge idempotent
- [ ] Im nächsten Quartals-Übungsplan

---

## Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Erstfassung |
