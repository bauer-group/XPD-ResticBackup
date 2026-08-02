# Runbook: Vollserver-Backup

**Owner:** [Name/Team eintragen] | **Frequenz:** Täglich (automatisch)
**Letzte Aktualisierung:** 2026-08-02 | **Letzter Testlauf:** [Datum eintragen]

**Ersetzt:** `.drafts/resti Docs/full-server-backup-disaster-recovery-manual.md`.

Ergänzt [backup-docker.md](backup-docker.md): dort die Anwendungsdaten, hier das
Betriebssystem drumherum.

---

## 1. Zwei-Ebenen-Strategie

Aus dem alten Manual übernommen, weil die Aussage weiterhin richtig ist:

| Ebene | Was | Vorteil | Nachteil |
|---|---|---|---|
| **Provider-/Hypervisor-Snapshot** | ganze VM, atomar | bildet wirklich alles ab (Bootloader, Partitionstabelle), Rollback in Minuten | nur bei VMs; nicht granular; liegt meist beim selben Anbieter — kein Schutz bei dessen Totalausfall |
| **Dateisystem-Backup (dieses Runbook)** | alle Dateien, granular, verschlüsselt, extern | Einzeldatei-Restore, anbieterunabhängig, auch für Bare Metal | Restore auf neue Hardware ist aufwendiger als ein Snapshot-Rollback |

**Empfehlung: beides.** Wo der Provider VM-Snapshots anbietet, zusätzlich
regelmäßig einen ziehen. Dieses Runbook deckt ausschließlich Ebene 2 ab.

---

## 2. Was gesichert wird

Dateien **plus ein maschinenlesbares Host-Manifest**. Das ist der Unterschied zum
alten Manual, und er entscheidet, ob ein Wiederaufbau auf frischer Installation
überhaupt möglich ist:

| | |
|---|---|
| Pakete | `apt-mark showmanual/showauto/showhold`, `dpkg-query -W`, `snap list` |
| APT | `sources.list*`, `preferences.d`, **Keyrings** |
| systemd | enabled / disabled / masked, failed units, Timer |
| Konten | passwd, group, shadow, **subuid/subgid** |
| Netzwerk | `ip -j link` (**MAC-Adressen**), netplan, Firewall-Regeln |
| Storage | `lsblk -J`, `blkid` (**UUIDs**), fstab, LVM, mdstat, Partitionstabellen |
| Sonstiges | Crontabs, Zeitzone, Locale, SSH-Host-Key-Fingerprints, `ss -lntup` |

Ohne MAC-Adressen und Disk-UUIDs ist ein Abgleich mit neuer Hardware Raten. Genau
daran scheitern naive Restores.

Gesammelt vom Pre-Hook `collect-system-facts.sh`, der ausschließlich liest.

---

## 3. Ausschlüsse

`/etc/bg-backup/excludes/system.exclude`

Virtuelle und flüchtige Dateisysteme (`/proc`, `/sys`, `/dev`, `/run`, `/tmp`,
`/var/tmp`, `/mnt`, `/media`, `/lost+found`), Swap, rebuildbare Container-Layer
(`/var/lib/docker/{overlay2,image,tmp}`, `/var/lib/containerd`), Caches, Snap,
und der eigene restic-Cache.

**`/var/lib/docker/volumes` ist bewusst nicht ausgeschlossen** — das sind die Daten.

> ⚠️ **Die `--one-file-system`-Falle**
>
> `--one-file-system` verhindert, dass restic in NFS-Mounts oder USB-Medien
> läuft — und **überspringt zugleich alles auf einem eigenen Dateisystem**. Liegt
> `/var/lib/docker` auf eigenem Mount, fehlt es still im Root-Backup.
>
> ```bash
> df -h /var/lib/docker
> ```
>
> Falls abweichend: in `JOB_EXTRA_PATHS` aufnehmen. `bg-backup doctor` prüft
> genau das und meldet einen Fehler, keine Warnung.

---

## 4. Konfiguration

`/etc/bg-backup/conf.d/10-system.conf`

```bash
JOB_MODE="files"
JOB_PATHS=( / )
JOB_ONE_FILE_SYSTEM=1
JOB_EXTRA_PATHS=()               # ggf. /var/lib/docker
JOB_QUIESCE="none"               # der Docker-Job kümmert sich um Konsistenz
JOB_SCHEDULE="*-*-* 02:30:00"    # VOR dem Docker-Job
JOB_PARTIAL_IS_FAILURE=0         # live: Exit 3 ist normal
JOB_PRE_HOOKS=( /opt/bg-backup/current/share/hooks/collect-system-facts.sh )
```

**Warum täglich statt wöchentlich:** Dank Deduplizierung kostet ein zweiter Lauf
fast nichts, und ein wöchentliches Systembackup bedeutet im Ernstfall bis zu
sieben Tage verlorene Konfigurationsänderungen.

**Warum 02:30 vor 03:00:** Die Jobs dürfen sich nicht überschneiden. `doctor`
meldet kollidierende Zeiten, wenn beide quiescen.

---

## 5. Regelbetrieb

```bash
bg-backup status
bg-backup backup system          # manuell
```

Exit 3 ist bei diesem Job **normal**: rotierende Logs, Sockets, Dateien die
während des Laufs verschwinden. Deshalb `JOB_PARTIAL_IS_FAILURE=0`.

Die Zahl der unlesbaren Dateien steht in `bg_backup_files_unreadable`, die Pfade
im Job-Log — bewusst nicht in der Benachrichtigung, denn Dateinamen eines Hosts
sind eine Informationspreisgabe an einen externen Endpunkt.

---

## 6. Konsistenz ohne Ausfallzeit

Wo LVM, btrfs oder ZFS vorhanden ist:

```bash
JOB_QUIESCE="lvm"
JOB_SNAPSHOT_SIZE="10G"
```

```
fsfreeze -f     Millisekunden, nicht die Backup-Dauer
lvcreate --snapshot
fsfreeze -u
Snapshot ÜBER den Originalpfad mounten (privater Mount-Namespace)
restic backup
```

Der Snapshot wird über den Originalpfad gemountet, damit restic die
**Produktionspfade** speichert. Ein Backup von `/mnt/snap/var/...` erzeugt einen
Snapshot, dessen Inhalte an die falsche Stelle zurückgespielt werden — und das
fällt erst beim Restore auf.

```bash
bg-backup discover        # zeigt VG-Freiplatz
```

Läuft einem LVM-Snapshot der Copy-on-Write-Platz aus, verwirft ihn der Kernel
mitten im Backup, und restic liest I/O-Fehler von einem Gerät, das eben noch
funktionierte. Deshalb wird der Platz vorher geprüft.

---

## 7. Kontrolle

```bash
bg-backup status
bg-backup check                  # wöchentlich, automatisch
bg-backup verify                 # monatlich, automatisch
bg-backup snapshots --job system
```

---

## 8. Wiederherstellung

Einzelne Dateien: [restore.md](restore.md).
Ganzer Host: [disaster-recovery.md](disaster-recovery.md).

> ⚠️ **Nie `restic restore latest --target /` auf neuer Hardware.** Alte
> Disk-UUIDs in `/etc/fstab` lassen den Host in eine Emergency-Shell fallen, alte
> Interface-Namen in `/etc/netplan` machen ihn unerreichbar. `bg-backup dr`
> trennt deshalb in AUTO, STAGED und NEVER.

---

## 9. Troubleshooting

| Symptom | Ursache | Behebung |
|---|---|---|
| Backup dauert extrem lange | Erstlauf, oder externe Mounts werden mitgescannt | bei Erstlauf normal; sonst `findmnt` prüfen und `--one-file-system` setzen |
| `/var/lib/docker` fehlt | eigenes Dateisystem | `JOB_EXTRA_PATHS`; `doctor` meldet es |
| Exit 3 jede Nacht | rotierende Logs, Sockets | erwartet bei einem Live-Job |
| Manifest fehlt | Pre-Hook nicht ausführbar | `chmod +x`, `bg-backup logs system` |
| Beide Jobs stoppen Dienste gleichzeitig | Zeitpläne überschneiden sich | Zeiten trennen; `doctor` meldet es |

---

## 10. Änderungshistorie

| Datum | Von | Notizen |
|---|---|---|
| 2026-08-02 | [eintragen] | Ersetzt das manuelle Vollserver-Manual; Host-Manifest, LVM-Snapshot-Pfad und Safe/Staged/Never-Restore ergänzt |
