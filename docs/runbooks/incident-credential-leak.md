# Runbook: Vorfall — Zugangsdaten geleakt

**Owner:** [Name/Team eintragen] | **Frequenz:** Im Ernstfall
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

Anlass für dieses Runbook: Beim Aufsetzen dieses Projekts standen echte
MinIO-Zugangsdaten und eine restic-Passphrase in unversionierten
Arbeitsdokumenten. Sie waren **nicht** im Git-Verlauf — aber der nächste Leak
soll ein Verfahren vorfinden, keine Improvisation.

---

## 1. Umfang feststellen — bevor irgendetwas anderes passiert

Die erste Frage entscheidet über den Aufwand: **Ist es im Git-Verlauf?**

```bash
git log --all -S '<das-secret>' --oneline
git log --all --pretty=format: --name-only --diff-filter=A | sort -u
git ls-files | grep -i draft
```

| Ergebnis | Konsequenz |
|---|---|
| **leer** — nur im Working Tree | Rotieren, `.gitignore`, Scanner. **Kein History-Rewrite.** |
| Treffer, **nicht** gepusht | History-Rewrite lokal möglich, danach normal weiter |
| Treffer, **gepusht** | History-Rewrite, Force-Push, und alle Klone müssen neu geholt werden. GitHub cached außerdem Commits — der Provider muss ggf. kontaktiert werden. |

Das zuerst zu klären ist der wertvollste Schritt: Es verhindert einen Tag
History-Rewrite an einem Verlauf, der bereits sauber ist.

- [ ] Ergebnis: ____________  Zeitpunkt: ____________

**Zusätzlich prüfen, wo es sonst noch gelandet ist:** Chat-Verläufe, Tickets,
Wiki, Screenshots, LLM-Transkripte, E-Mail. In der Praxis ist das der Kanal, der
übersehen wird.

---

## 2. Rotieren — als wäre es veröffentlicht

Unabhängig vom Ergebnis aus Schritt 1. Ein Secret, das in einem unversionierten
Dokument stand, war auf mindestens einem Laptop, in mindestens einem Backup und
möglicherweise in einem Chat.

Reihenfolge nach [key-rotation.md](key-rotation.md):

1. **Neuen** S3-Service-Account anlegen, prefix-scoped
2. Separaten Prune-Account anlegen — **nicht** auf dem gesicherten Host
3. Konfiguration umstellen, Backup-Lauf beweisen
4. Alten Key **löschen**, nicht deaktivieren — ein deaktivierter Key wird beim
   Aufräumen wieder aktiviert
5. `restic key add` neue Passphrase, verifizieren, alte entfernen
6. Bundle neu exportieren, Recovery Sheet neu drucken

- [ ] S3 rotiert: ____________
- [ ] Passphrase rotiert: ____________
- [ ] Alter Key gelöscht: ____________

---

## 3. Blast Radius im geteilten Bucket

**Der Schritt, der am ehesten übersprungen wird und am ehesten zählt.**

```bash
# In MinIO: Welche Policy hing am alten Key?
```

War er **bucket-weit** statt prefix-scoped, waren die Repositories **aller**
Server im Bucket erreichbar:

- [ ] Policy geprüft — bucket-weit? ____________
- [ ] Falls ja: MinIO-Zugriffslogs auf unerwartete Quell-IPs prüfen
- [ ] Falls ja: `restic check --read-data` für **jeden** betroffenen Server
- [ ] Falls ja: dortige Zugangsdaten ebenfalls rotieren

---

## 4. Strukturell verhindern

Rotation behebt den Vorfall. Diese Punkte verhindern den nächsten.

**`.gitignore` — vor dem nächsten `git add -A`:**

```gitignore
.drafts/
*.env
!*.env.example
credentials/
*.key
*.pem
secrets.yml
```

**Pre-commit-Hook** — fängt es auf dem Entwicklerrechner ab, bevor Netzwerk im
Spiel ist:

```yaml
- repo: https://github.com/gitleaks/gitleaks
  rev: v8.30.0
  hooks: [{id: gitleaks}]
```

**CI** — `security.yml` fährt gitleaks über den Baum **und TruffleHog im
`git-history`-Modus**. Letzterer ist der, der einen committeten Leak findet.

**Konvention, in `CONTRIBUTING.md` festgehalten und durch die
gitleaks-Allowlist durchgesetzt:**

> Jede Zugangsangabe in jedem Dokument ist ein Platzhalter der Form
> `<your-thing>` oder `CHANGE_ME_THING`. **Niemals ein realistisch aussehender
> Fake** — ein plausibler Fake-Key trainiert Reviewer darauf, über
> schlüsselförmige Zeichenketten hinwegzulesen.

**`docs/` wird bewusst *nicht* pauschal von der Secret-Erkennung ausgenommen.**
Andere Repositories tun das; hier ist die Dokumentation genau der Ort, an dem es
passiert ist. Erlaubt sind nur Platzhalter-**Muster**, sodass ein echter Key in
einem Runbook weiterhin ein Fund ist.

- [ ] `.gitignore` ergänzt
- [ ] Pre-commit installiert
- [ ] CI-Scan grün

---

## 5. Verifikation — jetzt, solange sie noch aussagekräftig ist

```bash
gitleaks detect --source . --config .gitleaks.toml --redact --log-opts="--all"
trufflehog git file://. --results=verified,unknown
git log --all -S '<altes-secret>' --oneline     # muss leer bleiben
grep -rn '<altes-secret>' /etc /root /var 2>/dev/null
```

Der letzte Befehl findet Reste auf dem Host selbst. Alte Konfigurationsdateien
mit Zugangsdaten:

```bash
shred -u /root/.restic-env /etc/resticprofile/profiles.yaml
```

> Diese Prüfungen werden wertlos, sobald das Secret rotiert ist — **jetzt**
> ausführen und das (redigierte) Ergebnis im Vorfallsbericht festhalten.

---

## 6. Vorfallsbericht

```
CREDENTIAL LEAK
Entdeckt          ____________  Von            ____________
Betroffene Secrets ___________________________________________
Wo aufgetaucht     ___________________________________________
Im Git-Verlauf     [ ] nein  [ ] ja, nicht gepusht  [ ] ja, gepusht
Öffentlich seit    ____________  (bei gepusht)

MASSNAHMEN
  S3 rotiert          ____________
  Passphrase rotiert  ____________
  Alter Key gelöscht  ____________
  Blast Radius        ___________________________________________
  Fremde Repos geprüft [ ] n/a  [ ] ja: __________________________

STRUKTURELL
  [ ] .gitignore   [ ] pre-commit   [ ] CI-Scan   [ ] Konvention dokumentiert

VERBLEIBENDES RISIKO
  ___________________________________________________________

Unterschrift ____________  Datum ____________
```

---

## Sonderfall: bereits gepusht

1. **Sofort rotieren.** Der Verlauf lässt sich bereinigen, ein bereits kopiertes
   Secret nicht.
2. `git filter-repo` oder BFG, dann Force-Push.
3. Alle Klone müssen neu geholt werden — ein alter Klon bringt den Commit zurück.
4. GitHub cached Commits auch nach dem Rewrite. Für vollständige Entfernung den
   Support kontaktieren.
5. War das Repository öffentlich: davon ausgehen, dass es indexiert wurde. Es gibt
   Scanner, die genau darauf warten.

---

## Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Erstfassung, ausgelöst durch Zugangsdaten in den Projekt-Arbeitsdokumenten |
