# Runbook: Vorfall — Host kompromittiert / Ransomware

**Owner:** [Name/Team eintragen] | **Frequenz:** Im Ernstfall
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

---

## Die unbequeme Ausgangslage

Der Host hält ein Credential, das ins Repository schreiben darf. Wer root auf dem
Host hat, hat dieses Credential. Client-seitige Verschlüsselung schützt gegen den
Storage-Betreiber — **nicht** gegen einen Angreifer auf der Quelle.

Was die Architektur zusagt, ist enger und nützlicher: Ein Credential, das der
Host hält, kann die Historie **nicht zerstören**, weil es nur unter `locks/`
löschen darf und `prune` einer anderen Identität gehört.

Was es **nicht** verhindert: `PutObject` ohne Delete erlaubt weiterhin
**Überschreiben**. `restic check --read-data` erkennt das, verhindert es nicht.

---

## Reihenfolge — nicht abweichen

### 1. Schreibzugriff stoppen (Minuten, nicht Stunden)

```bash
# In MinIO/S3: den Service-Account des Hosts LÖSCHEN, nicht deaktivieren.
```

Das ist der erste Schritt, weil alles andere wirkungslos ist, solange der
Angreifer weiter schreiben kann. Die Passphrase zuerst zu wechseln bringt nichts.

- [ ] Zeitpunkt notiert: ____________

### 2. Host isolieren, nicht abschalten

```bash
# Netzwerk trennen. NICHT herunterfahren - der Arbeitsspeicher ist Beweismaterial.
```

- [ ] Isoliert: ____________

### 3. Host-Key entfernen — von einer **sauberen** Maschine

```bash
export RESTIC_REPOSITORY='<vom Recovery Sheet>'
export RESTIC_PASSWORD='<Recovery-Key-Passphrase, NICHT die Host-Passphrase>'
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...   # Ops-Identität

restic key list
restic key remove <id des host:<fqdn> Keys>
```

Hier zahlt sich der unabhängige Recovery-Key aus: ohne ihn müsste man den
kompromittierten Key benutzen, um ihn zu entfernen.

- [ ] Entfernt: ____________

### 4. Zustand des Repositories feststellen

```bash
restic check --read-data
```

Das lädt das **gesamte** Repository — Stunden und echte Egress-Kosten. Es ist
trotzdem der richtige Schritt: `PutObject` erlaubte Überschreiben, und nur diese
Prüfung findet überschriebene Packs.

```bash
restic snapshots
```

Fehlen Snapshots? Sind welche zu klein? Notieren.

- [ ] Ergebnis: ____________

### 5. Sauberen Zeitpunkt bestimmen

```bash
restic snapshots --tag kind=files
bg-backup runs list
```

Der letzte Lauf **vor** dem Zeitpunkt der Kompromittierung. Anhaltspunkte:

- ein plötzlicher Sprung in `bg_backup_bytes_added` — re-verschlüsselte Dateien
  ändern jeden Block, das ist der beste vorhandene Kanarienvogel
- der erste fehlgeschlagene oder auffällig lange Lauf
- Logs, Audit-Trail, MinIO-Zugriffslogs

> **Konservativ wählen.** Ein Snapshot zu weit zurück kostet Daten. Ein Snapshot
> zu weit vorn stellt die Kompromittierung wieder her.

- [ ] Gewählter Lauf: ____________

---

## Wiederherstellung

### 6. Neues Repository — nicht das alte weiterverwenden

> `restic key remove` verschlüsselt den Master-Key **nicht** neu. Wer je an das
> Master-Key-Material kam, kann alle vorhandenen Snapshots weiterhin
> entschlüsseln — auch nach der Rotation. Das alte Repository ist damit
> **kompromittiert und bleibt es**.

```bash
# 1. Neues Repository mit neuen Zugangsdaten anlegen
restic init -r <neu>

# 2. Nur den sauberen Lauf kopieren
restic copy --from-repo <alt> --tag run=<sauberer-lauf> -r <neu>

# 3. Das alte Repository für die Forensik behalten, isoliert und read-only
```

### 7. Host neu aufbauen — nicht bereinigen

Ein kompromittierter Host wird nicht desinfiziert. Neu installieren, dann
[disaster-recovery.md](disaster-recovery.md) mit dem sauberen Lauf.

> **SSH-Host-Keys aus dem Backup NICHT übernehmen.** Sie tragen die
> möglicherweise kompromittierte Identität weiter.
>
> ```bash
> bg-backup dr run --phase system --no-host-keys
> ```

### 8. Alle geteilten Zugangsdaten rotieren

Der Bucket ist geteilt. War der Key nicht prefix-scoped, sind die Repositories
der anderen Server im Blast Radius.

- [ ] MinIO-Policy des alten Keys geprüft — war er bucket-weit?
- [ ] Falls ja: `restic check --read-data` für **jeden** betroffenen Server
- [ ] Alle Anwendungs-Zugangsdaten des Hosts rotiert (DB-Passwörter, API-Keys,
      Webhooks) — sie lagen auf einem kompromittierten System
- [ ] Bundle-Passphrase rotiert

---

## Danach

- [ ] `bg-backup verify` auf dem neuen Host
- [ ] Ein Backup läuft ins **neue** Repository
- [ ] Recovery Sheet neu erstellt und gedruckt
- [ ] Vorfallsbericht: Zeitleiste, betroffene Daten, gewählter
      Wiederherstellungspunkt, verbliebene Unsicherheiten
- [ ] Verbesserungen umgesetzt — siehe unten

---

## Was diesen Vorfall beim nächsten Mal begrenzt

| Maßnahme | Wirkung |
|---|---|
| **Pull-Copy-Repository** — eine gehärtete Maschine kopiert primär → sekundär, kein Produktionshost hat Zugangsdaten dafür | die stärkste verfügbare Kontrolle |
| S3-Versionierung + Deny auf `DeleteObjectVersion` | Überschreiben wird rückholbar |
| rest-server `--append-only` | Löschen serverseitig verweigert |
| unabhängiger Recovery-Key | Kompromittierung kostet einen Key statt das Repository |
| `prune` niemals vom gesicherten Host | ohne das ist alles andere wirkungslos |
| Wachstums-Alarm (`BackupGrowthAnomaly`) | findet Re-Verschlüsselung früh |

> **S3 Object Lock löst das nicht.** restic ist bis 0.19 nicht lock-frei; eine
> Bucket-Default-Retention macht auch die `locks/`-Objekte unlöschbar und das
> Repository binnen Tagen unbenutzbar. Siehe
> [ADR-0009](../adr/0009-no-s3-object-lock-with-restic.md).

Beim Erstellen des Zweit-Repositories:

```bash
restic init --from-repo <primär> --copy-chunker-params -r <sekundär>
```

Ohne `--copy-chunker-params` re-chunked restic alles, die Deduplizierung geht
verloren, und die Kopie kann ein Vielfaches groß werden.

---

## Eskalation

| Situation | Kontakt |
|---|---|
| Kompromittierung bestätigt | [eintragen] |
| Datenschutzrelevant | [eintragen] — Meldefristen beachten |
| Repository beschädigt | [eintragen] |

---

## Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Erstfassung |
