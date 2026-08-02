# Runbook: Migration von resticprofile / handgeschriebenen Cron-Wrappern

**Owner:** [Name/Team eintragen] | **Frequenz:** Einmalig pro Host
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

**Ersetzt:** `.drafts/resti Docs/resticprofile-automation-monitoring-manual.md`.

---

## Grundsatzentscheidung: das bestehende Repository weiterverwenden

**Ja.** Aus drei Gründen:

**Die Historie ist das Asset.** Ein neues Repository fängt bei null an, und die
Retention-Zusage (30 täglich / 8 wöchentlich / 6 monatlich) ist ein halbes Jahr
lang eine Lüge.

**Die Dedup-Basis ist das Asset.** Ein neues Repository lädt jedes Byte neu hoch.
Auf einem Docker-Host sind das leicht hunderte GB über WAN — und der erste Lauf
des **neuen** Werkzeugs wäre damit sein langsamster und fehleranfälligster. Genau
dann will man Langeweile.

**Rotation braucht kein neues Repository.** restic trennt Master-Key von
Repository-Keys; `key add` + `key remove` wechselt die Passphrase in O(1), ohne
einen Snapshot anzufassen.

> ⚠️ **Eine harte Bedingung an das Tag-Design**
>
> Die bestehenden Tags `live` / `stopped` / `full-live` / `full-stopped` müssen
> **erhalten bleiben**; `bg-backup`, `host=`, `job=`, `run=` kommen additiv dazu.
>
> Ändern sich die Tags, matchen die alten Snapshots kein `forget --tag stopped`
> mehr. Sie werden dann **für immer aufbewahrt** — still, und teuer.

```bash
# In conf.d/<job>.conf die Alt-Tags mitführen:
JOB_TAGS=( tier=docker stopped )
```

---

## Phase 0 — Rotation zuerst

Standen Zugangsdaten in `profiles.yaml` oder `/root/.restic-env` — bei
resticprofile liegt die Passphrase im Klartext in der Konfigurationsdatei —
zuerst [key-rotation.md](key-rotation.md) und
[incident-credential-leak.md](incident-credential-leak.md).

Danach einmalig:

```bash
restic check --read-data
```

Vollständig, nicht als Subset: Der alte Key durfte `PutObject`, also könnten
Packs überschrieben worden sein. Ergebnis protokollieren.

- [ ] Rotiert und geprüft: ____________

---

## Phase 1 — Parallel installieren, Timer aus

```bash
curl -fsSL .../install.sh | bash
bg-backup init --repo '<DASSELBE Repository>' --profile docker
```

**Dasselbe Repository, neue Zugangsdaten.** Kein Timer.

```bash
bg-backup doctor
bg-backup backup docker --dry-run
bg-backup backup docker
```

**Gate — beides muss stimmen:**

```bash
restic snapshots --tag live --json | jq '.[-2:]'
```

- [ ] Der neue Snapshot hat dieselben `paths` und dieselben Alt-Tags wie der
      resticprofile-Snapshot
- [ ] `data_added` ist ein **kleines Delta** — das beweist, dass die
      Deduplizierung gegen den Bestand greift und nicht alles neu hochgeladen wird

```bash
bg-backup restore file --path /etc/hostname --to /tmp/check
```

- [ ] Einzeldatei-Restore funktioniert

---

## Phase 2 — Umschalten

**Reihenfolge ist nicht optional.** Erst den alten Scheduler abschalten, dann den
neuen anschalten — sonst rennen zwei Jobs um `systemctl stop docker`. Genau davor
warnt auch das alte resticprofile-Manual.

```bash
# 1. Alten Scheduler abschalten
resticprofile -c /etc/resticprofile/profiles.yaml -n docker-live      unschedule
resticprofile -c /etc/resticprofile/profiles.yaml -n docker-stopped   unschedule
resticprofile -c /etc/resticprofile/profiles.yaml -n fullserver-live  unschedule
resticprofile -c /etc/resticprofile/profiles.yaml -n fullserver-stopped unschedule

systemctl list-timers | grep -i resticprofile     # muss leer sein
crontab -l                                        # keine backup-*.sh mehr
```

```bash
# 2. Zugangsdaten-Reste vernichten (shred, nicht rm)
shred -u /etc/resticprofile/profiles.yaml
shred -u /root/.restic-env
rm -f /root/backup-docker.sh /root/backup-fullserver.sh
rm -f /usr/local/bin/resticprofile
```

```bash
# 3. Erst jetzt den neuen Scheduler
bg-backup schedule sync
bg-backup schedule enable
systemctl list-timers 'bg-backup*'
```

**Gate:**

- [ ] Nur bg-backup-Timer gelistet
- [ ] `grep -rn '<alter-key>\|<alte-passphrase>' /etc /root /var 2>/dev/null` leer

---

## Phase 3 — Einwöchige Beobachtung

- [ ] Kuma täglich grün
- [ ] `bg-backup status` innerhalb der SLA
- [ ] `check` am Mittwoch grün
- [ ] Snapshot-Zahl entwickelt sich wie von der Policy vorhergesagt
- [ ] **Ein absichtlich erzeugter Fehler erreicht einen Menschen** — S3-Key für
      fünf Minuten sperren

Der letzte Punkt wird üblicherweise übersprungen und ist der einzige, der
beweist, dass die Überwachung funktioniert.

---

## Phase 4 — Erste echte DR-Übung

[dr-rehearsal.md](dr-rehearsal.md). RTO messen, Sheet unterschreiben,
Quartalsrhythmus setzen.

---

## Was sich konkret ändert

| | resticprofile | bg-backup |
|---|---|---|
| Zeitplanung | systemd-Timer über resticprofile | systemd-Timer direkt |
| Konfiguration | `profiles.yaml`, **Passphrase im Klartext** | `conf.d/*.conf` + `repo.key` (0400), via `LoadCredential` |
| Docker-Konsistenz | Daemon stoppen | logische Dumps + `docker-pause` je Projekt |
| Datenbanken | nicht behandelt | pro Engine, mit `--stdin-from-command` |
| Restore | von Hand | `restore`/`dr` mit Safe/Staged/Never-Klassifikation |
| Bootstrap | manuell aus dem Passwort-Manager | Recovery Bundle + Config-Snapshot |
| Monitoring | healthchecks.io | Kuma-Push, Mail, Teams, Prometheus |
| Verifikation | `restic check` | zusätzlich Canary, Stichproben, Dump-Restore mit Zeilenvergleich |

**Was gleich bleibt:** dasselbe Repository, dieselben restic-Kommandos darunter,
das Zwei-Phasen-Prinzip (nur feiner geschnitten), und die Möglichkeit, jederzeit
ohne das Werkzeug an die Daten zu kommen.

---

## Warum nicht auf resticprofile aufsetzen

resticprofile löst Zeitplanung, konsolidierte Konfiguration und Monitoring — und
das gut. Es löst **nichts** von dem, was hier die Arbeit ist: keine
DB-bewusste Konsistenz, keine Restore-Orchestrierung, keine
Disaster-Recovery-Planung, kein Config-Bootstrap. Diese Teile wären ohnehin
Eigenbau gewesen.

Damit bliebe eine zweite Konfigurationsebene und ein zweites, ungepinntes
Fremdbinary, dessen Konfigurationsdatei die Passphrase im Klartext hält.

Siehe [ADR-0001](../adr/0001-bash-cli-instead-of-resticprofile.md). Die guten
Ideen sind übernommen: systemd statt Cron, eine konsolidierte Konfiguration,
Benachrichtigung mit Dead-Man's-Switch.

---

## Troubleshooting

| Symptom | Ursache | Behebung |
|---|---|---|
| Erster Lauf lädt alles neu hoch | anderes Repository, oder Chunker-Parameter abweichend | Repository-URL gegen `profiles.yaml` prüfen |
| Alte Snapshots verschwinden nicht mehr | Tags geändert, `forget --tag` matcht nicht mehr | Alt-Tags in `JOB_TAGS` mitführen |
| Zwei Jobs stoppen Docker | alter Scheduler noch aktiv | Phase 2 Schritt 1 nachholen |
| Exit 12 nach Umstellung | Passphrase-Datei falscher Modus | `chmod 0400`, Eigentümer root |

---

## Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Erstfassung |
