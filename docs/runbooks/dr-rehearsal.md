# Runbook: DR-Übung

**Owner:** [Name/Team eintragen] | **Frequenz:** Quartalsweise, und nach jeder größeren Änderung
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

---

## Warum

Ein Backup, das nie wiederhergestellt wurde, ist eine Hypothese.

`bg-backup verify` prüft automatisch viel — Canary, Stichproben, Dumps in
Wegwerf-Containern. Was es **nicht** prüfen kann, ist der Teil, der im Ernstfall
zählt: ob ein Mensch mit einem gedruckten Blatt Papier von null auf einen
laufenden Host kommt.

Genau das übt dieses Runbook.

> **Die zentrale Regel:** Braucht die Übung Informationen, die **nicht** auf dem
> Recovery Sheet stehen, ist das Sheet fehlerhaft. Das gilt als
> **fehlgeschlagene Übung**, nicht als Randnotiz. Diese Regel ist der eigentliche
> Wert der Übung — sie findet die Lücke, bevor sie teuer wird.

---

## Vorbereitung

- [ ] Wegwerf-VM, gleiche Ubuntu-Version wie der Quellhost
- [ ] Das **gedruckte** Recovery Sheet — nicht die digitale Kopie
- [ ] Zwei Personen: eine führt aus, eine protokolliert Zeiten und Stolperstellen
- [ ] Zeitfenster: 2–4 Stunden
- [ ] **Nichts** vom Quellhost mitbringen: kein SSH-Zugang, keine Notizen, keine
      geöffnete Doku, kein Passwort-Manager außer für die auf dem Sheet
      genannten Einträge

Der letzte Punkt ist der wichtigste. Jede Abkürzung macht die Übung wertlos.

---

## Ablauf

### Phase 1 — Ausgangslage (Start der Zeitmessung)

Frische VM, sonst nichts.

```bash
uname -a; cat /etc/os-release
```

**Notieren:** Startzeit.

### Phase 2 — Werkzeug

Nur mit Abschnitt 5 des Sheets:

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
bg-backup version
```

**Notieren:** Dauer. Stolperstellen?

### Phase 3 — Zugang zum Repository

Nur mit Abschnitt 1 des Sheets:

```bash
bg-backup dr bootstrap
```

**Gate:** `bg-backup snapshots` liefert eine Liste.

Falls nicht: **hier stoppen und das Sheet korrigieren.** Das ist ein Fund, kein
Hindernis.

**Notieren:** Dauer. Musste irgendetwas geraten werden?

### Phase 4 — Plan

```bash
bg-backup dr plan | tee /tmp/dr-plan.txt
```

**Notieren:** Welche REFUSE- oder Abweichungsmeldungen erscheinen? Sind sie
verständlich?

### Phase 5 — Wiederherstellung

```bash
bg-backup dr run --phase system
# gestagete Dateien prüfen
bg-backup dr run --phase docker
bg-backup dr run --phase databases
```

**Notieren:** Dauer je Phase. Wo war eine Entscheidung nötig, und war die
Information dafür vorhanden?

### Phase 6 — Verifikation

```bash
bg-backup dr verify
```

Plus fachlich:

- [ ] Anwendungen über ihre Domains erreichbar (Hosts-Datei genügt)
- [ ] Datenbank-Inhalte stichprobenartig plausibel
- [ ] Zeilenzahlen gegen die Werte vom Quellhost
- [ ] Alle erwarteten Container laufen
- [ ] Keine `systemctl --failed`

### Phase 7 — Der letzte Schritt

```bash
bg-backup backup --all
```

Ein wiederhergestelltes System ohne eigenes Backup ist ein Single Point of
Failure mit frischer Uhr. In der Übung wie im Ernstfall.

**Notieren:** Endzeit. **RTO = Endzeit − Startzeit.**

---

## Protokoll

```
DR-ÜBUNG
Datum                 ____________  Durchgeführt von  ____________
Quellhost             ____________  Ziel-VM           ____________
Recovery Sheet        RS-____-____  Protokoll von     ____________

ZEITEN
  Werkzeug installiert          ____ min
  Repository erreichbar         ____ min
  Plan gelesen                  ____ min
  Phase system                  ____ min
  Phase docker                  ____ min
  Phase databases               ____ min
  Verifikation                  ____ min
  ------------------------------------------
  RTO gesamt                    ____ min

ERGEBNIS
  [ ] bestanden
  [ ] bestanden mit Einschränkungen: ____________________________
  [ ] FEHLGESCHLAGEN: __________________________________________

SHEET
  [ ] vollständig — nichts außerhalb des Sheets wurde gebraucht
  [ ] unvollständig, fehlte: ___________________________________
      -> Sheet korrigieren und neu drucken:  PFLICHT

FUNDE
  1. ____________________________________________________________
  2. ____________________________________________________________
  3. ____________________________________________________________

MASSNAHMEN                                     Verantwortlich  Bis
  1. ____________________________________      ____________   ______
  2. ____________________________________      ____________   ______

Unterschrift ____________________  Datum ____________
```

Das Ergebnis kommt auf das Recovery Sheet, Abschnitt 8.

---

## Was eine Übung fehlschlagen lässt

Nicht: „es hat lange gedauert". Sondern:

| | |
|---|---|
| Information gebraucht, die nicht auf dem Sheet steht | das Sheet ist falsch |
| Ein Image ließ sich nicht ziehen | lokal gebaut, `EXPORT_IMAGES` war `none` |
| Ein Dump ließ sich nicht laden | die Konsistenzannahme war falsch |
| Die Passphrase öffnete das Repository nicht | Rotation ohne Sheet-Aktualisierung |
| Der Host bootete nicht | ein STAGED-Pfad wurde ungeprüft übernommen |
| Niemand wusste, wer eskaliert | Abschnitt 7 nicht ausgefüllt |

Jeder dieser Punkte wäre im Ernstfall teuer gewesen. Ihn hier zu finden, ist das
Ziel — eine Übung, die nichts findet, hat entweder alles richtig gemacht oder war
zu bequem.

---

## Nach der Übung

- [ ] Wegwerf-VM löschen
- [ ] Falls das Sheet unvollständig war: korrigieren, neu drucken, alte Kopien
      vernichten
- [ ] Maßnahmen als Tickets anlegen
- [ ] Nächsten Termin setzen
- [ ] Bei Auffälligkeiten am Werkzeug: Issue im Repository

---

## Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Erstfassung |
