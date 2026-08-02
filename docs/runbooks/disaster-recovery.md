# Runbook: Disaster Recovery

**Owner:** [Name/Team eintragen] | **Frequenz:** Im Ernstfall + quartalsweise Übung
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

**Ersetzt:** `.drafts/resti Docs/backup-disaster-recovery-manual-docker.md` §8 und
`.drafts/resti Docs/full-server-backup-disaster-recovery-manual.md` §9.

> ⚠️ **Die wichtigste Regel dieses Dokuments**
>
> **Niemals `restic restore latest --target /` auf neuer Hardware.**
>
> Alte Disk-UUIDs in `/etc/fstab` lassen den Host beim Boot in eine Emergency-Shell
> fallen. Alte Interface-Namen in `/etc/netplan` machen ihn bootbar, aber
> **unerreichbar** — der schlimmere Fall, weil er Konsolenzugriff erfordert. Ein
> restauriertes `/boot`, dessen Kernelmodule nicht mitkamen, paniced ohne
> brauchbare Meldung.
>
> `bg-backup dr` trennt deshalb strikt: **AUTO** (wird geschrieben), **STAGED**
> (wird abgelegt und muss angesehen werden), **NEVER** (wird nie geschrieben).

---

## 0. Voraussetzungen — was Sie in der Hand haben müssen

Genau drei Dinge, alle vom Recovery Sheet:

- [ ] Repository-URL
- [ ] Repository-Passphrase
- [ ] Backend-Zugangsdaten (S3 Key + Secret)

Fehlt eines davon: **sofort eskalieren**. Ohne die Passphrase sind die Daten
dauerhaft unlesbar — es gibt keinen Wiederherstellungsweg, keine Hintertür, keinen
Support-Fall, der das löst.

> Wenn dieses Runbook Informationen braucht, die **nicht** auf dem Recovery Sheet
> stehen, ist das Sheet fehlerhaft. In einer Übung gilt das als **fehlgeschlagener
> Testlauf**, nicht als Randnotiz.

---

## 1. Lagebild — welcher Fall liegt vor?

| Fall | Vorgehen |
|---|---|
| Cloud-/VPS-VM, Host verloren | **Abschnitt 2** — neu installieren, dann `dr run`. Immer schneller und sicherer als Blockebenen-Chirurgie. |
| Bare Metal, Host verloren | **Abschnitt 6** — Rescue-System, teilautomatisch |
| Host lebt, einzelne Daten weg | Runbook [restore.md](restore.md), nicht dieses hier |
| Host lebt, Konfiguration weg | `bg-backup config import --in <bundle>` |
| Ransomware-Verdacht | Zuerst [incident-ransomware.md](incident-ransomware.md) |

---

## 2. Fall A: Cloud-/VPS-Host (Regelfall)

### Schritt 1 — Frisches Ubuntu installieren

Gleiche Version wie vorher. `bg-backup dr plan` prüft das und **verweigert eine
ältere Zielversion**: Datenbank-Dumps sind nur vorwärtskompatibel, ein
PostgreSQL-16-Dump lädt nicht in PostgreSQL 15.

### Schritt 2 — Werkzeug installieren

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/XPD-ResticBackup/main/install.sh | bash
```

**Erwartetes Ergebnis:** `bg-backup version` zeigt Tool- und restic-Version.

### Schritt 3 — Zugangsdaten und Konfiguration zurückholen

Mit Recovery Bundle:

```bash
bg-backup dr bootstrap --bundle /mnt/usb/bg-backup-recovery.age
```

Nur mit dem gedruckten Sheet:

```bash
bg-backup dr bootstrap
# fragt interaktiv nach Repository-URL, Passphrase und S3-Zugangsdaten
```

**Was dabei passiert:** Die Zugangsdaten werden geschrieben, das Repository wird
getestet, und aus dem Snapshot mit dem Tag `bg-backup-config` wird `/etc/bg-backup`
vollständig rekonstruiert — alle Jobs, Excludes, Hooks, das Zweit-Repository.

**Prüfen:**
```bash
bg-backup snapshots
```
Es muss eine Liste erscheinen. Erscheint sie nicht, stimmt etwas an den
Zugangsdaten nicht — hier stehenbleiben, nicht weitermachen.

### Schritt 4 — Plan lesen (schreibt nichts)

```bash
bg-backup dr plan
```

Der Bericht nennt:

- Quell- gegen Zielsystem (OS, Kernel, Architektur, Firmware) mit **REFUSE**-Markierungen
- Paketanzahl und die Installationsmethode
- **UUID-Abgleich** — welche Filesystem-UUIDs es hier nicht mehr gibt
- **NIC-Abgleich per MAC** — welches Interface jetzt anders heißt oder fehlt
- Compose-Projekte, Volumes, Netzwerke
- die Liste der Dumps
- explizit: was **nicht** automatisch zurückgeschrieben wird

**Diesen Bericht wirklich lesen.** Er ist der einzige Punkt im Ablauf, an dem
Abweichungen zwischen altem und neuem Host billig auffallen.

### Schritt 5 — Basissystem

```bash
bg-backup dr run --phase system
```

Reihenfolge und die Gründe dahinter:

1. Zeitzone, Locale, Hostname (`/etc/hosts` wird **gemerged**, nicht überschrieben)
2. **UID/GID-Abgleich** — bei Kollisionen bricht der Lauf ab und zeigt eine
   Remap-Tabelle. Ein falsches rekursives `chown` ist nicht reparierbar, deshalb
   nie automatisch.
3. APT-Quellen und Keyrings, dann `apt-get update` **als Gate** — eine nicht
   erreichbare Fremdquelle stoppt hier, statt später still die interessanten
   Pakete auszulassen
4. Pakete in **einer** Transaktion, bei Fehlschlag paketweise bisektiert
5. Docker über die Hausmethode, `daemon.json` gegen den neuen Host validiert
6. Netzwerk und Firewall werden **nur gestaged**
7. Units enablen — Units aus dem Backup, die es nicht mehr gibt, werden
   **gemeldet**: das ist die beste Frühwarnung für stillgeschlagene Paketinstallationen

### Schritt 6 — Gestagete Dateien prüfen

```bash
diff -ru /etc/netplan /var/lib/bg-backup/restore/staged/etc/netplan
diff -u  /etc/fstab   /var/lib/bg-backup/restore/staged/etc/fstab
```

**Netplan ausschließlich so anwenden:**

```bash
netplan try --timeout 120
```

`netplan try` nimmt sich selbst zurück, wenn Sie nicht bestätigen. **Niemals
`netplan apply` über SSH** — bei einem Fehler ist die Verbindung weg und mit ihr
die Möglichkeit, es zu korrigieren.

**sshd vor der Installation validieren:**

```bash
sshd -t -f /var/lib/bg-backup/restore/staged/etc/ssh/sshd_config
```

Eine `sshd_config` aus einer älteren Ubuntu-Version kann Optionen enthalten, die
das neuere OpenSSH ablehnt (`ssh-rsa` in `KexAlgorithms`, `UsePrivilegeSeparation`).
sshd startet dann nicht — und sperrt Sie aus dem Host aus, den Sie gerade retten.

**fstab:** Zeile für Zeile gegen das aktuelle `blkid` abgleichen. Alte UUIDs
existieren auf neuer Hardware nicht.

### Schritt 7 — Docker

```bash
bg-backup dr run --phase docker
```

Reihenfolge, jeder Schritt aus einem konkreten Grund:

1. **Netzwerke mit den aufgezeichneten Subnetzen** — werden sie nicht explizit
   angelegt, vergibt Docker andere aus seinem Adresspool, und jede Firewall-Regel
   oder ACL, die auf das alte Subnetz zeigte, greift still nicht mehr
2. Volumes anlegen
3. Volume-Inhalte zurückspielen, **während nichts läuft**
4. **Images per Digest ziehen** und auf den Tag zurücktaggen, den die
   Compose-Datei verwendet — sonst löst `compose up` `:latest` neu auf und startet
   eine andere Version, als die Daten erwarten
5. `compose up -d`

> Ist ein Image nirgends verfügbar und wurde nie exportiert, bricht der Lauf mit
> Nennung der exakten Referenz ab. `bg-backup discover` warnt vor genau diesem Fall
> im Regelbetrieb — deshalb `JOB_DOCKER_EXPORT_IMAGES=missing`.

### Schritt 8 — Datenbanken

```bash
bg-backup dr run --phase databases
```

Wartet auf Health, lädt dann Globals/Rollen vor den Daten (sonst entstehen Objekte,
deren Eigentümer noch nicht existieren).

> **Invariante:** Pro Datenbank entweder Dump **oder** Datadir zurückspielen, nie
> beides. Ein nicht-leeres Datadir lässt den offiziellen Entrypoint die
> Initialisierung überspringen; der Dump liefe dann auf Livedaten. Das Tool
> verweigert die Kombination.

### Schritt 9 — Verifizieren

```bash
bg-backup dr verify
```

Prüft Units, `systemctl --failed`, Containerzahl, nicht-leere Volumes, vorher
lauschende Ports — und ob dieser Host das Repository erreicht.

**Letzter Punkt, und er wird gern vergessen:**

```bash
bg-backup backup --all
```

Der neue Host muss sich selbst sichern, **bevor** jemand Feierabend macht. Ein
wiederhergestelltes System ohne eigenes Backup ist ein Single Point of Failure mit
frischer Uhr.

---

## 3. Was nie automatisch zurückgeschrieben wird

**NEVER** — nur zur Referenz gesichert:
`/boot`, `/lib/modules`, `/etc/machine-id`, `/var/lib/dbus/machine-id`,
`/var/lib/dpkg`, `/var/lib/apt`, `/var/lib/docker/{overlay2,image,containerd}`,
`/var/lib/snapd`, `/etc/passwd`, `/etc/group`, `/etc/shadow`

Kernel und Bootloader werden **aus Paketen neu installiert**, nie kopiert.
Benutzerkonten werden **gemerged**, nie als Datei überschrieben.

**STAGED** — abgelegt, muss angesehen werden:
`/etc/fstab`, `/etc/crypttab`, `/etc/netplan`, `/etc/systemd/network`,
`/etc/resolv.conf`, `/etc/udev/rules.d`, `/etc/default/grub`,
`/etc/initramfs-tools`, `/etc/ssh/sshd_config`, `/etc/pam.d`, `/etc/nsswitch.conf`,
Firewall-Regeln, `/etc/cloud`

Zusätzlich gilt eine selbstpflegende Regel: Ist eine `/etc`-Datei ein
dpkg-*conffile* und liefert die neu installierte Paketversion einen anderen
Default, wandert sie automatisch von AUTO nach STAGED. So verrottet die Liste
über OS-Upgrades hinweg nicht.

Vollständig: [`share/dr/unsafe-restore.list`](../../share/dr/unsafe-restore.list)

---

## 4. Ohne bg-backup wiederherstellen

Das Werkzeug darf nie Voraussetzung sein, um die eigenen Backups zu lesen.

```bash
export RESTIC_REPOSITORY='<vom Recovery Sheet>'
export AWS_ACCESS_KEY_ID='<vom Recovery Sheet>'
export AWS_SECRET_ACCESS_KEY='<vom Recovery Sheet>'
export RESTIC_PASSWORD='<vom Recovery Sheet>'

restic snapshots
restic restore latest --target /mnt/restore          # in ein Verzeichnis, nicht nach /
restic dump <snap> /db/postgres/<container>/<datenbank>.dump | pg_restore -d <db>
```

**Nach Lauf wiederherstellen, nicht nach „latest":**

```bash
restic snapshots --tag run=20260802T031500Z-a7f3k2
```

Ein Backup-Lauf erzeugt mehrere Snapshots (Dateien, je Dump einen, Images). Löst
man „latest" je Snapshot einzeln auf, kombiniert man den Datenbank-Dump von Montag
mit den Volume-Inhalten von Dienstag.

Tags: `kind=files`, `kind=dbdump`, `kind=image`, `run=<id>`, `job=<name>`.

---

## 5. Fall B: Bare Metal

```bash
bg-backup dr bare-metal --target /mnt/target
```

Verweigert außerhalb eines Rescue-Systems. **Generiert** das Partitionierungs-
skript, führt es nie aus — ein falscher Gerätename zerstört die falsche Platte,
und diese Entscheidung gehört zu einem Menschen, der die Maschine vor sich hat.

Explizit verweigert, weil subtil falsch schlimmer ist als gar nicht:
LUKS-Root, ZFS/btrfs-Root mit abweichendem Layout, Software-RAID ohne vollständige
`mdadm.conf`, Secure Boot mit eigenen MOK-Keys, BIOS↔UEFI-Wechsel — und Cloud-VMs
(dort ist Abschnitt 2 schneller und sicherer).

Kernel und Bootloader **aus Paketen**:

```bash
chroot /mnt/target apt-get install --reinstall -y linux-image-generic \
  $([ -d /sys/firmware/efi ] && echo 'grub-efi-amd64 shim-signed' || echo 'grub-pc')
chroot /mnt/target grub-install <disk>
chroot /mnt/target update-grub
chroot /mnt/target update-initramfs -c -k all
```

**Gate vor dem Reboot — nicht überspringen:**

```bash
findmnt --verify --fstab
ls /mnt/target/boot/vmlinuz-* /mnt/target/boot/initrd.img-*
chroot /mnt/target grub-probe /
chroot /mnt/target sshd -t
[ -d /sys/firmware/efi ] && efibootmgr
```

---

## 6. Troubleshooting

| Symptom | Ursache | Behebung |
|---|---|---|
| `restic snapshots` liefert nichts | falsches Repository-Prefix | Pfad muss auf den FQDN des **alten** Hosts enden, nicht des neuen |
| Exit 12 bei jedem Kommando | falsche Passphrase | Recovery Sheet prüfen; das Repository nicht anfassen |
| `dr plan` sagt REFUSE | Ziel-OS älter, andere Distribution oder Architektur | Zielsystem korrigieren; Dumps sind nur vorwärtskompatibel |
| Host bootet nach Restore nicht | UUID-Mismatch in fstab | Rescue booten, `blkid` gegen fstab abgleichen |
| Host bootet, ist aber nicht erreichbar | Interface-Namen | Konsole, `ip link`, netplan anpassen; künftig `netplan try` |
| Container starten, finden sich aber nicht | Netzwerk-Subnetze neu vergeben | Netzwerke mit den Werten aus dem Manifest neu anlegen |
| „Access denied" trotz korrektem Passwort | Passwort mit `#` im MySQL-Optionfile abgeschnitten | Von der Engine behandelt; bei Handarbeit escapen |
| Volumes leer nach dem Restore | Volume lief noch, als zurückgespielt wurde | Consumer stoppen, erneut zurückspielen |

---

## 7. Eskalation

| Situation | Kontakt |
|---|---|
| Backup > 48 h fehlgeschlagen | [eintragen] |
| Disaster Recovery läuft | [eintragen] |
| Bare Metal, Bootloader-Problem | [eintragen] |
| **Passphrase verloren, keine Kopie** | Sofort eskalieren — Daten sonst unwiederbringlich |

---

## 8. Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Ersetzt die manuellen Runbooks aus `.drafts/`; Safe/Staged/Never-Klassifikation, Lauf-basierter Restore, UID/GID-Abgleich, Image-Digests und Netzwerk-Subnetze ergänzt |
