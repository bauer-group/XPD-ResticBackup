# Runbook: Backup eines Docker-Hosts

**Owner:** [Name/Team eintragen] | **Frequenz:** Täglich (automatisch)
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

**Ersetzt:** `.drafts/resti Docs/backup-disaster-recovery-manual-docker.md`.

---

## 1. Was gesichert wird — und was bewusst nicht

| Gesichert | Nicht gesichert |
|---|---|
| Compose-Dateien, `.env`, alle aufgelösten `env_file` | overlay2- und Image-Layer |
| Named Volumes (Inhalt) | `/var/lib/docker/{overlay2,image,containerd}` |
| Bind-Mount-Quellen | Container-Dateisysteme |
| Image-**Digests** und Netzwerk-**Subnetze** | |
| Logische Datenbank-Dumps | |

**Warum nicht `/var/lib/docker`:** Ein Restore davon ist an exakt dieselbe
Docker-Version und denselben Storage-Driver gebunden. Die Anforderung lautet aber
„wiederherstellbar auf frisch installiertem System" — und genau das kann ein
Image-Ebenen-Backup nicht zusagen. Außerdem killt `systemctl stop docker` die
Container nach einem Timeout hart, Datenbanken laufen beim Restore also durch
Crash-Recovery.

**Das Zwei-Phasen-Prinzip aus dem alten Manual bleibt erhalten**, nur besser
zugeschnitten: Die Dumps laufen im laufenden Betrieb (sie sind transaktional
konsistent und brauchen kein Einfrieren), und nur der **Datei**-Teil bekommt ein
kurzes Fenster. Statt des kompletten Daemons wird nur das gerade gelesene Projekt
pausiert — Sekunden statt Minuten.

---

## 2. Konfiguration

`/etc/bg-backup/conf.d/20-docker.conf`

```bash
JOB_MODE="docker"
JOB_QUIESCE="docker-pause"       # Sekunden, kein Neustart
JOB_QUIESCE_SCOPE="project"
JOB_DB_DUMP=1
JOB_DOCKER_EXPORT_IMAGES="missing"
JOB_SCHEDULE="*-*-* 03:00:00"
JOB_PARTIAL_IS_FAILURE=1         # quiesced: unlesbare Dateien sind ein Signal
JOB_KEEP_DAILY="14"
JOB_KEEP_WEEKLY="8"
JOB_KEEP_MONTHLY="6"
```

Nach jeder Änderung:

```bash
bg-backup config validate
bg-backup schedule sync
```

---

## 3. Regelbetrieb

Nichts zu tun. Der Timer läuft.

```bash
bg-backup status
```

```
JOB       STATUS      AGE      SLA  SNAPSHOT   TOOK     NEXT
docker    ok          7.7h    26h   9f2c1a7b   04m 31s  2026-08-03 03:00
```

Manuell auslösen:

```bash
bg-backup backup docker
bg-backup backup docker --dry-run
```

---

## 4. Nach jeder Stack-Änderung: nachsehen

```bash
bg-backup discover
```

Drei Dinge kontrollieren:

**Werden die neuen Pfade erfasst?** Compose-Verzeichnis, Volumes, Bind-Mounts.

**Wird eine neue Datenbank erkannt?** Und meldet die Engine `degraded`? Dann
steht dort auch, warum — MyISAM-Tabellen, standalone MongoDB, ClickHouse ohne
Backup-Disk. Jedes davon ist eine echte Lücke, bis sie behoben ist.

**Gibt es Images ohne Registry-Digest?** Lokal gebaut, nie gepusht — die lassen
sich beim Restore nicht ziehen. `JOB_DOCKER_EXPORT_IMAGES=missing` exportiert
genau diese ins Repository.

---

## 5. Exit-Codes

| Code | Bedeutung | Aktion |
|---|---|---|
| 0 | vollständig | keine |
| 3 | Snapshot da, einzelne Dateien unlesbar | bei diesem Job **untersuchen** — es wurde quiesced |
| 1 | fatal, **kein** Snapshot | sofort untersuchen |
| 9 | Safety Rail hat verweigert | Meldung lesen, nicht erzwingen |

Vollständig: [exit-codes.md](../exit-codes.md).

---

## 6. Kontrolle, die sich lohnt

**Wöchentlich** (automatisch): `bg-backup check`

**Monatlich** (automatisch): `bg-backup verify` — lädt jeden Dump in einen
Wegwerf-Container ohne Netzwerkausgang und vergleicht Zeilenzahlen gegen die zur
Dump-Zeit erfassten Werte.

```bash
bg-backup status | grep 'last proven'
```

**Quartalsweise** (Mensch): [dr-rehearsal.md](dr-rehearsal.md)

---

## 7. Troubleshooting

| Symptom | Ursache | Behebung |
|---|---|---|
| Container bleiben pausiert | Lauf hart abgebrochen | `bg-backup internal unquiesce --job docker`; sollte nicht vorkommen, drei Mechanismen greifen dagegen |
| Exit 3 jede Nacht | unlesbare Dateien trotz Quiesce | Pfade im Job-Log ansehen — bei einem quiesced Job ist das ein echtes Signal |
| Dump schlägt jede Nacht fehl | Erkennung falsch, oder Container braucht Zugangsdaten | `bg-backup discover`, `docker logs <container>`; ggf. Label `skip: "true"` |
| Backup wächst stark | Bind-Mount zieht großes Verzeichnis mit, oder Dumps vorkomprimiert | `bg-backup diff`; `JOB_DB_DUMP_COMPRESS` muss 0 sein |
| `/var/lib/docker` fehlt | eigenes Dateisystem, `--one-file-system` überspringt es | in `JOB_EXTRA_PATHS` aufnehmen; `doctor` meldet das |
| Elasticsearch scheitert mit „path.repo" | Snapshot-API nicht nutzbar | Compose ändern und Dienst neu starten — bis dahin **kein** funktionierendes Backup dieses Containers |

---

## 8. Eskalation

| Situation | Kontakt |
|---|---|
| Backup > 48 h fehlgeschlagen | [eintragen] |
| `check` meldet Fehler | [eintragen] — **nicht prunen** |
| `verify` schlägt fehl | [eintragen] — wie ein Backup-Ausfall behandeln |

---

## 9. Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Umstellung von `/var/lib/docker` + Daemon-Stop auf Applikationsebene mit `docker-pause` und logischen Dumps |
