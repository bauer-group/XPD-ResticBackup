# Runbook: Restore

**Owner:** [Name/Team eintragen] | **Frequenz:** Nach Bedarf
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

**Ersetzt:** `.drafts/resti Docs/backup-disaster-recovery-manual-docker.md` §7.

Für einen verlorenen Host: [disaster-recovery.md](disaster-recovery.md). Dieses
Runbook behandelt einen **laufenden** Host, dem Daten fehlen.

---

## 0. Die wichtigste Entscheidung zuerst: nach Lauf, nicht nach „latest"

Ein Backup-Lauf erzeugt **mehrere** Snapshots — den Dateibaum, je einen pro
Datenbank-Dump, ggf. Images. Löst man „latest" je Snapshot einzeln auf, bekommt
man den Datenbank-Dump von Montag zusammen mit den Volume-Inhalten von Dienstag.
Jeder ist für sich der neueste, zusammen sind sie inkonsistent.

```bash
bg-backup runs list
```

```
RUN                      JOB       SNAPS  TIME                 KINDS
20260802T031500Z-a7f3k2  docker    4      2026-08-02 03:15:00  files,dbdump
20260801T031500Z-b2c9x1  docker    4      2026-08-01 03:15:00  files,dbdump
```

Die Run-ID ist der Selektor. `--snapshot` gibt es für chirurgische Eingriffe.

---

## 1. Erst schauen, dann wiederherstellen

```bash
bg-backup restore preview file --path /etc/nginx/nginx.conf
```

Zeigt je Eintrag `create` / `overwrite` / `identical`, Größen- und Modus-Diff,
und markiert Pfade der **NEVER-Liste** rot. Bei einem NEVER-Treffer endet der
Befehl mit Exit 2 und schreibt nichts.

Snapshot durchsuchen, ohne etwas zurückzuspielen:

```bash
bg-backup ls latest /etc | head -40
bg-backup find 'nginx.conf'
bg-backup mount /mnt/browse        # FUSE, Ctrl-C beendet sauber
```

---

## 2. Einzelne Datei oder Verzeichnis

**Standard: in ein Staging-Verzeichnis, nicht an den Originalort.**

```bash
bg-backup restore file --path /etc/nginx/nginx.conf --to /tmp/check
diff -u /etc/nginx/nginx.conf /tmp/check/etc/nginx/nginx.conf
```

Erst wenn der Diff stimmt:

```bash
bg-backup restore file --path /etc/nginx/nginx.conf --in-place --yes
```

**Was dabei passiert:** wiederherstellen ins Staging, prüfen, dann per `mv`
tauschen. Der bisherige Inhalt bleibt sieben Tage als `.bgbk-old-<token>` liegen.

```bash
bg-backup restore rollback --token <token>    # zurücknehmen
bg-backup restore commit   --token <token>    # Sicherungskopie verwerfen
```

> Liegen Staging und Ziel auf **verschiedenen** Dateisystemen, wird aus dem
> Rename eine Kopie: doppelter Platzbedarf und nicht atomar. Das Tool warnt und
> fragt nach.

---

## 3. Docker-Volume

```bash
bg-backup restore volume --name pg_data --run 20260802T031500Z-a7f3k2
```

Nutzt ein Container das Volume, listet das Tool die Consumer auf und bietet an,
sie zu stoppen und danach wieder zu starten.

> Ein Volume unter einem laufenden Container zurückzuspielen beschädigt beides.
> Nie bestätigen, ohne die Liste gelesen zu haben.

Getauscht wird `…/volumes/<name>/_data` per Rename — **nicht** das Volume-Objekt,
denn Docker kann Volumes nicht umbenennen. Driver, Optionen und Labels bleiben
dadurch unangetastet.

---

## 4. Compose-Projekt

```bash
bg-backup restore project --name mystack --run <id> --config-only   # nur Dateien
bg-backup restore project --name mystack --run <id>                 # + Volumes
bg-backup restore project --name mystack --run <id> --recreate      # + compose up
```

`--config-only` ist der häufigste Fall: jemand hat eine `docker-compose.yml`
kaputt bearbeitet, die Daten sind in Ordnung.

---

## 5. Datenbank

### In einen Wegwerf-Container (sicher, zum Nachsehen)

```bash
bg-backup restore db --db postgres/pg-app/app.dump --into scratch
```

Startet einen Container ohne Netzwerkausgang aus dem exakt aufgezeichneten Image,
lädt den Dump und vergleicht Objekt- und Zeilenzahlen gegen die zur Dump-Zeit
erfassten Werte. **Nichts Produktives wird angefasst.**

### Nach stdout (volle Kontrolle)

```bash
bg-backup restore db --db postgres/pg-app/app.dump --into - > /tmp/app.dump
bg-backup dump latest /db/postgres/pg-app/app.dump | pg_restore -d app
```

### In den Live-Container (letzter Schritt, nicht der erste)

```bash
bg-backup restore db --db postgres/pg-app/app.dump --into pg-app
```

Fragt nach. Der Dump wird auf die **laufende** Datenbank angewendet.

> **Reihenfolge bei PostgreSQL:** erst `globals.sql` (Rollen und Rechte), dann
> die Einzeldatenbanken. Andersherum entstehen Objekte, deren Eigentümer noch
> nicht existieren — PostgreSQL meldet das als Warnungen, nicht als Fehler, es
> sieht also aus, als hätte es funktioniert.

> **Nie Dump und Datadir gleichzeitig.** Ein nicht-leeres Datadir lässt den
> Entrypoint die Initialisierung überspringen, der Dump liefe dann auf Livedaten.
> Das Tool verweigert die Kombination.

---

## 6. Zeitpunkt wählen

```bash
bg-backup snapshots --job docker
bg-backup restore file --path /srv/app/config.yml --at 2026-07-15T00:00:00Z
bg-backup runs diff <run-a> <run-b>
```

---

## 7. Ohne bg-backup

```bash
source /etc/bg-backup/credentials/repo.env
restic snapshots
restic restore <snap> --target /mnt/restore --include /etc/nginx
restic dump <snap> /db/postgres/pg-app/app.dump | pg_restore -d app
restic mount /mnt/browse
```

Das ist bewusst so: Das Werkzeug darf nie Voraussetzung sein, um die eigenen
Backups zu lesen.

---

## 8. Testrestore (regelmäßig, ohne Anlass)

```bash
bg-backup verify
```

Stellt eine Canary-Datei und Stichproben echter Dateien wieder her und vergleicht
Hashes; lädt jeden Datenbank-Dump in einen Wegwerf-Container und vergleicht
Zeilenzahlen. Monatlich zusätzlich den **ältesten** aufbewahrten Snapshot — den,
auf den man im Ransomware-Fall angewiesen ist.

```bash
bg-backup status | grep 'last proven'
```

---

## 9. Troubleshooting

| Symptom | Ursache | Behebung |
|---|---|---|
| `restore preview` endet mit Exit 2 | NEVER-Pfad betroffen | in ein Verzeichnis wiederherstellen und bewusst übernehmen |
| Wiederhergestellte Dateien haben falsche Eigentümer | UIDs weichen ab | `bg-backup dr fix-ownership --apply` nach Prüfung der Remap-Tabelle |
| Volume nach Restore leer | lief noch, als zurückgespielt wurde | Consumer stoppen, erneut |
| Dump lädt, Zeilenzahlen weichen ab | Dump unvollständig, oder Schreibzugriffe zwischen Zählung und Dump | ernst nehmen; bei PostgreSQL sind die Zählungen exakt |
| `latest` liefert Unerwartetes | je Snapshot aufgelöst statt je Lauf | `bg-backup runs list` und `--run <id>` |

---

## 10. Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Ersetzt §7 des Docker-Manuals; Lauf-basierte Auswahl, Staging-Swap mit Rollback, Wegwerf-Container-Restore ergänzt |
