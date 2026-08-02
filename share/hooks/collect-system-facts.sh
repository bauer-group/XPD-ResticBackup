#!/usr/bin/env bash
# =============================================================================
# bg-backup - pre-hook: capture everything needed to rebuild this host
# =============================================================================
# Files alone do not make a host restorable. A freshly installed Ubuntu has a
# different package set, different UIDs, different interface names and different
# disk UUIDs. This hook captures the facts that let `bg-backup dr plan`
# reconcile the two, and it writes them where the backup will sweep them up.
#
# Everything here is READ-ONLY. It runs as root on a production host before every
# backup, so it must never change state, never prompt, and never take long.
#
# Runs with a scrubbed environment: BGB_JOB, BGB_PHASE, BGB_HOSTNAME, BGB_RUN_ID
# are set; backend credentials deliberately are not.
# =============================================================================

set -uo pipefail   # not -e: a missing optional tool must not fail the backup

FACTS_DIR="${BGB_FACTS_DIR:-/var/lib/bg-backup/facts}"
install -d -m 0700 "${FACTS_DIR}"

_w() {  # _w <filename> <command...>
  local out="${FACTS_DIR}/$1"; shift
  "$@" >"${out}.tmp" 2>/dev/null && mv -f "${out}.tmp" "${out}" || rm -f "${out}.tmp"
}

# --- Identity ----------------------------------------------------------------
{
  printf 'captured=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'hostname=%s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'run_id=%s\n'   "${BGB_RUN_ID:-}"
  printf 'kernel=%s\n'   "$(uname -r)"
  printf 'arch=%s\n'     "$(uname -m)"
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  printf 'os_id=%s\n'       "${ID:-}"
  printf 'os_version=%s\n'  "${VERSION_ID:-}"
  printf 'os_codename=%s\n' "${VERSION_CODENAME:-}"
  printf 'timezone=%s\n'    "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
  printf 'virt=%s\n'        "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  printf 'firmware=%s\n'    "$([ -d /sys/firmware/efi ] && echo uefi || echo bios)"
} >"${FACTS_DIR}/host.env"

# --- Packages ----------------------------------------------------------------
# apt-mark showmanual is the right list: it is what a human chose to install.
# `dpkg --set-selections` + dselect-upgrade is deliberately NOT used on restore -
# it removes packages the newly installed system needs.
_w packages-manual.txt  apt-mark showmanual
_w packages-auto.txt    apt-mark showauto
_w packages-hold.txt    apt-mark showhold
_w packages-versions.tsv dpkg-query -W -f '${Package}\t${Version}\t${Architecture}\n'
_w snap.json            snap list --unicode=never

# APT sources and their signing keys - without these, half the package list is
# unavailable on the rebuilt host and the install phase fails confusingly.
tar -C / -cf "${FACTS_DIR}/apt-config.tar" \
  --exclude='etc/apt/sources.list.d/*.save' \
  etc/apt/sources.list etc/apt/sources.list.d etc/apt/preferences.d \
  etc/apt/apt.conf.d etc/apt/keyrings etc/apt/trusted.gpg.d 2>/dev/null
chmod 0600 "${FACTS_DIR}/apt-config.tar" 2>/dev/null

# --- systemd -----------------------------------------------------------------
_w units-enabled.txt      systemctl list-unit-files --state=enabled --no-legend
_w units-disabled.txt     systemctl list-unit-files --state=disabled --no-legend
_w units-masked.txt       systemctl list-unit-files --state=masked --no-legend
_w units-failed.txt       systemctl list-units --state=failed --no-legend
_w timers.txt             systemctl list-timers --all --no-legend

# --- Accounts ----------------------------------------------------------------
# Restored by MERGE, never by overwriting the files: the fresh install has system
# users this backup does not know about.
_w users-passwd.txt  getent passwd
_w users-group.txt   getent group
{ [ -r /etc/subuid ] && cat /etc/subuid; } >"${FACTS_DIR}/users-subuid.txt" 2>/dev/null
{ [ -r /etc/subgid ] && cat /etc/subgid; } >"${FACTS_DIR}/users-subgid.txt" 2>/dev/null

# --- Storage -----------------------------------------------------------------
# The UUID map is what makes fstab reconciliation possible instead of guesswork.
_w disk-lsblk.json  lsblk -J -O
_w disk-blkid.txt   blkid
_w disk-fstab.txt   cat /etc/fstab
_w disk-df.txt      df -hPT
_w disk-mounts.txt  findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS
if command -v sfdisk >/dev/null 2>&1; then
  for d in /dev/sd? /dev/nvme?n? /dev/vd?; do
    [ -b "${d}" ] || continue
    sfdisk -d "${d}" >"${FACTS_DIR}/disk-partitions-$(basename "${d}").sfdisk" 2>/dev/null || true
  done
fi
command -v pvs  >/dev/null 2>&1 && _w disk-lvm-pvs.txt pvs
command -v vgs  >/dev/null 2>&1 && _w disk-lvm-vgs.txt vgs
command -v lvs  >/dev/null 2>&1 && _w disk-lvm-lvs.txt lvs
[ -r /proc/mdstat ] && _w disk-mdstat.txt cat /proc/mdstat

# --- Network -----------------------------------------------------------------
# MAC addresses are the only reliable way to match old interfaces to new ones
# after a hardware change; names (eth0 vs ens3 vs enp0s3) are not stable.
_w net-links.json    ip -j link show
_w net-addrs.json    ip -j addr show
_w net-routes.json   ip -j route show
_w net-listening.txt ss -lntup
_w net-resolv.txt    cat /etc/resolv.conf
tar -C / -cf "${FACTS_DIR}/net-config.tar" \
  etc/netplan etc/systemd/network etc/network 2>/dev/null
chmod 0600 "${FACTS_DIR}/net-config.tar" 2>/dev/null

# --- Firewall ----------------------------------------------------------------
command -v ufw      >/dev/null 2>&1 && _w fw-ufw.txt ufw status verbose
command -v nft      >/dev/null 2>&1 && _w fw-nft.txt nft list ruleset
command -v iptables >/dev/null 2>&1 && _w fw-iptables.txt iptables-save

# --- Scheduled work ----------------------------------------------------------
_w cron-system.txt cat /etc/crontab
for u in $(cut -d: -f1 /etc/passwd); do
  crontab -l -u "${u}" 2>/dev/null | sed "s/^/${u}\t/"
done >"${FACTS_DIR}/cron-users.tsv" 2>/dev/null

# --- SSH ---------------------------------------------------------------------
# Fingerprints only. The private host keys are in the file backup already; a
# second plaintext copy in a facts directory is a needless extra place to leak.
for k in /etc/ssh/ssh_host_*_key.pub; do
  [ -e "${k}" ] || continue
  ssh-keygen -lf "${k}" 2>/dev/null
done >"${FACTS_DIR}/ssh-hostkey-fingerprints.txt"

# --- Docker ------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  _w docker-info.json    docker info --format '{{json .}}'
  _w docker-images.txt   docker image ls --digests --format '{{.Repository}}:{{.Tag}}\t{{.Digest}}\t{{.ID}}'
  _w docker-ps.txt       docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
  [ -r /etc/docker/daemon.json ] && cp -f /etc/docker/daemon.json "${FACTS_DIR}/docker-daemon.json" 2>/dev/null
fi

# --- Hardware ----------------------------------------------------------------
_w hw-cpu.txt     lscpu
_w hw-mem.txt     free -h
command -v dmidecode >/dev/null 2>&1 && _w hw-dmi.txt dmidecode -t system

chmod -R go-rwx "${FACTS_DIR}" 2>/dev/null || true
exit 0
