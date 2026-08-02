# Runbook: Schlüssel- und Zugangsdaten-Rotation

**Owner:** [Name/Team eintragen] | **Frequenz:** Jährlich, und nach jedem Verdacht
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

---

## Was hier rotiert werden kann — und was nicht

restic trennt den **Master-Key** (verschlüsselt die Daten) von den
**Repository-Keys** (Passphrasen, die ihn entpacken). Eine Passphrasen-Rotation
ist deshalb O(1) und rührt keinen einzigen Snapshot an.

> ⚠️ **Das schützt gegen ein gestohlenes Passwort, nicht gegen einen gestohlenen
> Schlüssel.** `restic key remove` verschlüsselt den Master-Key **nicht** neu. Wer
> je an das Master-Key-Material gekommen ist, behält Zugriff auf alle bereits
> vorhandenen Snapshots. Nach einer Host-Kompromittierung braucht es ein **neues
> Repository**, keine rotierte Passphrase.
>
> Siehe [incident-ransomware.md](incident-ransomware.md).

---

## Reihenfolge nach einem Verdacht

Diese Reihenfolge ist nicht beliebig:

1. **S3-Zugangsdaten zuerst.** Das stoppt weitere Schreibzugriffe. Die Passphrase
   zuerst zu wechseln, während der Angreifer noch das S3-Credential hat, bringt
   nichts.
2. Host-Key entfernen — **von einer sauberen Maschine aus**
3. `restic check --read-data` — ist die Historie noch intakt?
4. Erst dann über Wiederaufbau entscheiden

---

## A. Repository-Passphrase rotieren

```bash
bg-backup secrets rotate-repo-password
```

Was passiert, und warum in dieser Reihenfolge:

1. neuer Key wird **hinzugefügt**
2. der neue Key wird aus einer **sauberen Umgebung** verifiziert
3. erst dann wird der alte entfernt
4. das Recovery Bundle wird neu exportiert
5. die neue Passphrase wird einmalig ausgegeben

Schritt 2 ist der Punkt: Erst entfernen und danach feststellen, dass der neue Key
nicht funktioniert, macht das Repository mit **keinem** von beiden erreichbar.

**Danach zwingend:**

- [ ] neue Passphrase in den Passwort-Manager
- [ ] **Recovery Sheet neu drucken** — ein Sheet mit der alten Passphrase ist
      schlimmer als keines, es erzeugt im Ernstfall selbstsichere Fehlversuche
- [ ] alte gedruckte Kopien vernichten
- [ ] Bundle an alle Escrow-Ziele verteilen

```bash
bg-backup config export
bg-backup secrets print-recovery-card --out /root/recovery-sheet.txt
```

Von Hand, falls das Werkzeug nicht verfügbar ist:

```bash
source /etc/bg-backup/credentials/repo.env
restic key add --user bg-backup --host "$(hostname -f)" --new-password-file /root/.new
env -i RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
       RESTIC_PASSWORD_FILE=/root/.new \
       AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
       AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
       restic snapshots >/dev/null     # PRÜFEN, bevor entfernt wird
restic key list
restic key remove <alte-id>
install -m 0400 /root/.new /etc/bg-backup/credentials/repo.key
shred -u /root/.new
```

---

## B. S3-Zugangsdaten rotieren

```bash
# 1. Neuen Service-Account anlegen, prefix-scoped:
#      ListBucket   nur auf <prefix>/*
#      GetObject, PutObject, Multipart auf <prefix>/*
#      DeleteObject NUR auf <prefix>/locks/*
```

> **Deletes nicht pauschal verbieten.** restic schreibt bei jedem Lauf ein
> Lock-Objekt und räumt es beim Beenden weg. Bei vollständigem Delete-Verbot
> bleibt nach jedem Lauf ein Stale Lock zurück, und ab dem dritten Lauf braucht
> das Repository ein `unlock`, das ebenfalls nicht gelingt.

```bash
# 2. In die Konfiguration übernehmen
bg-backup config edit          # credentials/repo.env

# 3. Prüfen
bg-backup doctor
bg-backup backup system --dry-run

# 4. Ein echter Lauf
bg-backup backup system

# 5. Erst jetzt den alten Key LÖSCHEN (nicht deaktivieren -
#    ein deaktivierter Key wird beim Aufräumen wieder aktiviert)
```

- [ ] Bundle neu exportieren
- [ ] Recovery Sheet neu drucken

---

## C. Recovery-Key anlegen oder erneuern

```bash
bg-backup secrets add-recovery-key
```

Die Passphrase wird **einmal** ausgegeben und **nicht auf dem Host gespeichert**.
Sofort in den Passwort-Manager und auf das Sheet.

Mit einem Recovery-Key kostet eine Host-Kompromittierung ein
`restic key remove`. Ohne ihn kostet sie das Repository.

---

## D. Bundle-Passphrase rotieren

```bash
bg-backup config export --passphrase-file /root/.new-escrow
```

Alte Bundles an allen Escrow-Zielen ersetzen — ein altes Bundle mit alter
Passphrase ist ein zweiter, veralteter Zugangsweg.

---

## Checkliste nach jeder Rotation

- [ ] `bg-backup doctor` grün
- [ ] ein Backup-Lauf erfolgreich
- [ ] `bg-backup snapshots` zeigt die **vollständige** Historie
- [ ] Bundle neu exportiert und verteilt
- [ ] Recovery Sheet neu gedruckt, alte Kopien vernichtet
- [ ] Passwort-Manager aktualisiert
- [ ] `bg-backup verify` erfolgreich
- [ ] Datum im Änderungsprotokoll unten

**Die Historie-Prüfung ist nicht optional.** Sie beweist, dass die Rotation die
alten Snapshots nicht unlesbar gemacht hat — das ist das einzige, was hier
schiefgehen kann und was man sonst erst im Ernstfall merkt.

---

## Troubleshooting

| Symptom | Ursache | Behebung |
|---|---|---|
| Nach Rotation Exit 12 | Key-Datei nicht aktualisiert oder falscher Modus | `ls -l /etc/bg-backup/credentials/repo.key` muss `-r--------` zeigen |
| `key remove` schlägt fehl | der zu entfernende Key ist der gerade genutzte | mit dem **neuen** Key authentifizieren, dann entfernen |
| Streuner-Key nach Fehlschlag | Verifikation scheiterte, alter Key blieb absichtlich | `restic key list`, nach Ursachenklärung entfernen |
| Backup läuft, `check` scheitert | Zugangsdaten dürfen schreiben, aber nicht lesen | S3-Policy: `GetObject` auf dem Prefix fehlt |

---

## Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Erstfassung |
