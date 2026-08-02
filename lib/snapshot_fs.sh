#!/usr/bin/env bash
# =============================================================================
# bg-backup - snapshot_fs: consistency with zero downtime
# =============================================================================
# The only quiesce mode that is both CONSISTENT and DOWNTIME-FREE.
#
# The sequence, and why each step is shaped the way it is:
#
#   fsfreeze -f <mount>     flush and block writers - held for MILLISECONDS
#   lvcreate --snapshot     take the block-level snapshot
#   fsfreeze -u <mount>     thaw immediately
#   mount the snapshot OVER the original path, inside a PRIVATE mount namespace
#   restic backup <path>    reads the frozen point-in-time copy
#
# Two details decide whether this works in practice:
#
#  1. fsfreeze must never be held for the duration of the backup. A frozen
#     filesystem blocks every writer on the machine, so a 40-minute backup
#     becomes a 40-minute outage - worse than the docker-stop it was meant to
#     replace. Freeze, snapshot, thaw: milliseconds.
#
#  2. The snapshot is mounted over the ORIGINAL path in a private namespace, so
#     the paths restic stores are the production paths. Backing up
#     /mnt/snap/var/lib/docker instead would produce a snapshot whose contents
#     restore to the wrong place, and nobody notices until a restore.
# =============================================================================

[ -n "${_BGB_SNAPSHOT_FS_SOURCED:-}" ] && return 0
_BGB_SNAPSHOT_FS_SOURCED=1

# snapshot_fs_begin <job> <state-file>
snapshot_fs_begin() {
  local job="$1" state="$2"
  case "${JOB_QUIESCE}" in
    lvm)   snapshot_fs_lvm_begin "${job}" "${state}" ;;
    btrfs) snapshot_fs_btrfs_begin "${job}" "${state}" ;;
    zfs)   snapshot_fs_zfs_begin "${job}" "${state}" ;;
    *) die "${EX_PRECOND}" "snapshot_fs_begin called with JOB_QUIESCE=${JOB_QUIESCE}" ;;
  esac
}

# snapshot_fs_end <snapshot-id> <mountpoint>
snapshot_fs_end() {
  local snapshot="$1" mountpoint="$2"
  [ -n "${snapshot}" ] || return 0

  case "${snapshot}" in
    /dev/*)
      umount "${mountpoint}" 2>/dev/null || true
      # Retry: a snapshot LV can be briefly busy right after the umount, and
      # leaving it behind silently consumes VG space until the volume group is
      # full and the NEXT backup fails for an unrelated-looking reason.
      local n=0
      while [ "${n}" -lt 5 ]; do
        lvremove -f "${snapshot}" >/dev/null 2>&1 && { debug "removed ${snapshot}"; return 0; }
        sleep 2; n=$(( n + 1 ))
      done
      err "Could not remove the LVM snapshot ${snapshot} - remove it by hand:"
      err "    lvremove -f ${snapshot}"
      return 1 ;;
    btrfs:*)
      local sub="${snapshot#btrfs:}"
      btrfs subvolume delete "${sub}" >/dev/null 2>&1 || warn "could not delete ${sub}" ;;
    zfs:*)
      local ds="${snapshot#zfs:}"
      umount "${mountpoint}" 2>/dev/null || true
      zfs destroy "${ds}" >/dev/null 2>&1 || warn "could not destroy ${ds}" ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# LVM
# -----------------------------------------------------------------------------
snapshot_fs_lvm_begin() {
  local job="$1" state="$2"
  require_cmd lvcreate "apt-get install -y lvm2"
  require_cmd fsfreeze "util-linux"

  local src="${JOB_PATHS[0]:-/}"
  local dev lv vg free_g need_g
  dev="$(findmnt -no SOURCE --target "${src}" 2>/dev/null)"
  [ -n "${dev}" ] || die "${EX_PRECOND}" "Could not determine the device backing ${src}"

  # Must be an LVM logical volume, not a partition.
  if ! lvs --noheadings -o lv_path 2>/dev/null | tr -d ' ' | grep -qx "${dev}"; then
    die "${EX_PRECOND}" "${src} is on ${dev}, which is not an LVM logical volume - JOB_QUIESCE=lvm cannot work here"
  fi

  vg="$(lvs --noheadings -o vg_name "${dev}" 2>/dev/null | tr -d ' ')"
  free_g="$(vgs --noheadings -o vg_free --units g --nosuffix "${vg}" 2>/dev/null | tr -d ' ' | cut -d. -f1)"
  need_g="$(printf '%s' "${JOB_SNAPSHOT_SIZE}" | tr -dc '0-9')"

  # Checked up front: an LVM snapshot that runs out of copy-on-write space is
  # dropped by the kernel mid-backup, and restic then reads I/O errors from a
  # device that used to work. Failing here is far easier to diagnose.
  if [ -n "${free_g}" ] && [ "${free_g}" -lt "${need_g}" ] 2>/dev/null; then
    die "${EX_PRECOND}" "Volume group ${vg} has ${free_g}G free but JOB_SNAPSHOT_SIZE is ${JOB_SNAPSHOT_SIZE}"
  fi

  local name; name="bgb_${job}_$(date -u '+%s')"
  local snapdev="/dev/${vg}/${name}"
  local mountpoint="${src}"

  log "Freezing ${src} (milliseconds) and taking an LVM snapshot"
  fsfreeze -f "${src}" || die "${EX_FAIL}" "fsfreeze failed on ${src}"

  if ! lvcreate --quiet --snapshot --name "${name}" --size "${JOB_SNAPSHOT_SIZE}" "${dev}" >/dev/null 2>&1; then
    # Thaw before reporting: leaving the filesystem frozen would take the host
    # down, which is a far worse outcome than a failed backup.
    fsfreeze -u "${src}" 2>/dev/null || true
    die "${EX_FAIL}" "lvcreate --snapshot failed on ${dev}"
  fi
  fsfreeze -u "${src}" || warn "fsfreeze -u failed on ${src} - CHECK THIS IMMEDIATELY"

  {
    printf 'mode=%s\n' "${JOB_QUIESCE}"
    printf 'job=%s\n' "${job}"
    printf 'started=%s\n' "$(now_epoch)"
    printf 'snapshot=%s\n' "${snapdev}"
    printf 'mountpoint=%s\n' "${mountpoint}"
  } >"${state}"
  chmod 0600 "${state}"

  BGB_SNAPSHOT_DEV="${snapdev}"
  BGB_SNAPSHOT_MOUNT="${mountpoint}"
  export BGB_SNAPSHOT_DEV BGB_SNAPSHOT_MOUNT
  log "Snapshot ${snapdev} created; the filesystem was frozen only for the snapshot itself"
}

# snapshot_fs_run <restic-args...>
# Runs restic with the snapshot mounted over the production path inside a
# private mount namespace, so nothing else on the host sees the overmount.
snapshot_fs_run() {
  [ -n "${BGB_SNAPSHOT_DEV:-}" ] || { "${BGB_RESTIC_BIN}" "$@"; return $?; }

  local fstype
  fstype="$(blkid -o value -s TYPE "${BGB_SNAPSHOT_DEV}" 2>/dev/null || echo auto)"
  local -a opts=(-o ro)
  # "ro,nouuid" is one mount-option STRING, not two array elements.
  # shellcheck disable=SC2054
  # XFS refuses to mount a second filesystem with the same UUID without nouuid,
  # and an LVM snapshot is by definition a UUID duplicate of its origin.
  [ "${fstype}" = "xfs" ] && opts=(-o ro,nouuid)

  unshare --mount --propagation private -- bash -c '
    set -euo pipefail
    mount --make-rprivate /
    dev="$1"; mp="$2"; shift 2
    mount '"${opts[*]}"' "$dev" "$mp"
    exec "$@"
  ' _ "${BGB_SNAPSHOT_DEV}" "${BGB_SNAPSHOT_MOUNT}" "${BGB_RESTIC_BIN}" "$@"
}

# -----------------------------------------------------------------------------
# btrfs
# -----------------------------------------------------------------------------
snapshot_fs_btrfs_begin() {
  local job="$1" state="$2"
  require_cmd btrfs
  local src="${JOB_PATHS[0]:-/}"
  local snapdir="${src%/}/.bgb-snapshots"
  local name; name="bgb_${job}_$(date -u '+%s')"

  install -d -m 0700 "${snapdir}" 2>/dev/null || true
  # btrfs snapshots are atomic by design - no freeze is needed, which is why
  # this path is simpler than LVM.
  btrfs subvolume snapshot -r "${src}" "${snapdir}/${name}" >/dev/null \
    || die "${EX_FAIL}" "btrfs subvolume snapshot failed"

  {
    printf 'mode=btrfs\n'
    printf 'job=%s\n' "${job}"
    printf 'started=%s\n' "$(now_epoch)"
    printf 'snapshot=btrfs:%s\n' "${snapdir}/${name}"
    printf 'mountpoint=%s\n' "${snapdir}/${name}"
  } >"${state}"
  chmod 0600 "${state}"

  BGB_SNAPSHOT_PATH="${snapdir}/${name}"
  export BGB_SNAPSHOT_PATH
  log "btrfs snapshot: ${snapdir}/${name}"
}

# -----------------------------------------------------------------------------
# ZFS
# -----------------------------------------------------------------------------
snapshot_fs_zfs_begin() {
  local job="$1" state="$2"
  require_cmd zfs
  local src="${JOB_PATHS[0]:-/}"
  local ds
  ds="$(zfs list -H -o name,mountpoint 2>/dev/null | awk -v m="${src%/}" '$2==m{print $1; exit}')"
  [ -n "${ds}" ] || die "${EX_PRECOND}" "${src} is not a ZFS dataset mountpoint"

  local name; name="bgb_${job}_$(date -u '+%s')"
  zfs snapshot "${ds}@${name}" || die "${EX_FAIL}" "zfs snapshot failed"

  local mountpoint="/var/lib/bg-backup/snap/${name}"
  install -d -m 0700 "${mountpoint}"
  mount -t zfs -o ro "${ds}@${name}" "${mountpoint}" 2>/dev/null || true

  {
    printf 'mode=zfs\n'
    printf 'job=%s\n' "${job}"
    printf 'started=%s\n' "$(now_epoch)"
    printf 'snapshot=zfs:%s@%s\n' "${ds}" "${name}"
    printf 'mountpoint=%s\n' "${mountpoint}"
  } >"${state}"
  chmod 0600 "${state}"

  BGB_SNAPSHOT_PATH="${mountpoint}"
  export BGB_SNAPSHOT_PATH
  log "ZFS snapshot: ${ds}@${name}"
}
