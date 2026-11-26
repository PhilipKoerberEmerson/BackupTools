#!/usr/bin/env bash
# =============================================================================
#  backup.sh - Linux full-system backup and restore (live media / GNU tar)
#
#  Creates indexed, incremental full-system backups of a Linux root filesystem
#  into a chain of compressed tar archives (GNU tar --listed-incremental) and
#  restores them onto a disk, including UEFI (GPT) partitioning and GRUB setup.
#
#  Requirements
#    - Backup storage: a mounted filesystem with an (empty) marker file
#      "bigBackupVolume.txt" in its root. The script finds it automatically.
#    - Restore only works on a PC booted in UEFI mode, run from live media.
#  Compression: zstd (default, fast), xz (smallest, as used by kernel.org) or
#  gzip/pigz - all of them use every available CPU core.
#
#  Optional companion file (built-in defaults are used when missing)
#    - exclude.lst (next to this script)   tar exclude patterns, one per line,
#      relative to the backup source, e.g. ./home/*/.cache/*
#
#  See README.md for the full documentation.
#  PhK 2026-11-22
#
#  License and Disclaimer
#    Licensed under the MIT License - see LICENSE in the repository root:
#    https://github.com/PhilipKoerberEmerson/BackupTools
#    USE ENTIRELY AT YOUR OWN RISK. This script is provided "AS IS" without
#    warranty or guarantee of any kind. Neither the author(s) nor any
#    affiliated company assumes any responsibility or liability for data
#    loss, system failure, or damages resulting from its use. Review and
#    test it thoroughly before use and always verify your backups.
# =============================================================================
set -u

APP_NAME="SystemBackup"
APP_VERSION="1.0.0"
MARKER="bigBackupVolume.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESTORE_MNT="/mnt/sysrestore"
CORES="$(nproc 2>/dev/null || echo 1)"
BK_VOL=""   # mountpoint of the backup storage volume
BK_DIR=""   # directory holding the backup chain of one host

banner() {
    echo "******************************************************************************"
    echo "        $APP_NAME v$APP_VERSION - Linux Backup and Restore Script"
    echo "        Note: Restore requires live media and a PC booted in UEFI mode"
    echo "******************************************************************************"
    echo
}

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
    [[ $(id -u) -eq 0 ]] || { echo "ERROR: This action requires root - run with sudo."; return 2; }
}

find_backup_volume() {
    BK_VOL=""
    local mp
    while read -r mp; do
        [[ -f "$mp/$MARKER" ]] && BK_VOL="$mp"
    done < <(findmnt -rn -o TARGET 2>/dev/null)
    [[ -n $BK_VOL ]]
}

# --- compression helpers (all multi-core) -------------------------------------
compress_cmd() {  # $1 = zstd|xz|gzip|none
    case "$1" in
        zstd) echo "zstd -q -T0 -3" ;;
        xz)   echo "xz -T0 -6" ;;
        gzip) if command -v pigz >/dev/null; then echo "pigz -p$CORES"; else echo "gzip"; fi ;;
        none) echo "cat" ;;
    esac
}

decompress_cmd_for() {  # $1 = archive file name
    case "$1" in
        *.tar.zst) echo "zstd -q -dc -T0" ;;
        *.tar.xz)  echo "xz -dc -T0" ;;
        *.tar.gz)  if command -v pigz >/dev/null; then echo "pigz -dc"; else echo "gzip -dc"; fi ;;
        *.tar)     echo "cat" ;;
        *)         return 1 ;;
    esac
}

ext_for() {  # $1 = compression method
    case "$1" in
        zstd) echo "tar.zst" ;;
        xz)   echo "tar.xz" ;;
        gzip) echo "tar.gz" ;;
        none) echo "tar" ;;
    esac
}

show_index() {
    local idx="$BK_DIR/index.txt"
    [[ -f $idx ]] || { echo "  (no backups yet)"; return 0; }
    echo "  Idx  Type  Archive                        Created              Description"
    echo "  ---  ----  -----------------------------  -------------------  -----------"
    local n file created desc kind
    while IFS='|' read -r n file created desc; do
        kind="incr"; [[ $file == full_* ]] && kind="FULL"
        printf '  %-3s  %-4s  %-29s  %-19s  %s\n' "$n" "$kind" "$file" "$created" "$desc"
    done < "$idx"
}

# =============================================================================
#  Backup
# =============================================================================
do_backup() {
    require_root || return 2
    BK_DIR="$BK_VOL/systembackup/$(hostname)"
    mkdir -p "$BK_DIR" || { echo "ERROR: Cannot create $BK_DIR."; return 2; }
    echo
    echo "******************************************************************************"
    echo "        Backup selected   (chain directory: $BK_DIR)"
    echo "******************************************************************************"
    echo
    echo "Mounted filesystems:"
    findmnt -rn -o TARGET,SOURCE,FSTYPE,SIZE | grep -Ev ' (proc|sysfs|devtmpfs|devpts|tmpfs|cgroup2?|securityfs|efivarfs|overlay|squashfs|autofs|binfmt_misc|9p|none) ' || true
    echo
    local src a
    while :; do
        read -rp "Mountpoint of the filesystem to back up [/]: " src
        src="${src:-/}"
        src="$(readlink -m "$src")"
        if ! findmnt -n "$src" >/dev/null 2>&1; then
            echo "  '$src' is not a mountpoint."
            continue
        fi
        if [[ "$src" == "$BK_VOL" ]]; then
            echo "  '$src' is the backup storage volume itself - choose another one."
            continue
        fi
        break
    done

    local comp="zstd"
    echo
    echo "Compression: [1] zstd (fast, recommended)  [2] xz (smallest, as kernel.org)"
    echo "             [3] gzip                      [4] none"
    read -rp "Select compression [1]: " a
    case "$a" in 2) comp="xz" ;; 3) comp="gzip" ;; 4) comp="none" ;; *) comp="zstd" ;; esac
    case "$comp" in
        zstd|xz) command -v "$comp" >/dev/null || { echo "ERROR: '$comp' is not installed."; return 2; } ;;
    esac

    local desc ts snar kind name
    read -rp "Optional description of this backup (Enter to skip): " desc
    ts="$(date +%F_%H-%M)"
    snar="$BK_DIR/snapshot.snar"
    kind="full"
    if [[ -f $snar ]]; then
        kind="incr"
        read -rp "Append an incremental backup? (n = start a NEW full chain) [Y/n] " a
        [[ ${a,,} == n* ]] && kind="full"
    fi
    [[ $kind == full ]] && rm -f "$snar"
    name="${kind}_${ts}.$(ext_for "$comp")"

    # --- build the exclusion list (paths relative to the backup source) -------
    local excl; excl="$(mktemp)" || return 2
    if [[ -f "$SCRIPT_DIR/exclude.lst" ]]; then
        cp "$SCRIPT_DIR/exclude.lst" "$excl"
    else
        echo "NOTE: '$SCRIPT_DIR/exclude.lst' not found - using built-in defaults."
        cat > "$excl" <<'EOF'
./proc/*
./sys/*
./dev/*
./run/*
./tmp/*
./mnt/*
./media/*
./lost+found
./var/tmp/*
./swapfile
./swap.img
EOF
    fi
    # never back up the backup volume itself when it lives on the same filesystem
    local rel
    if [[ "$BK_VOL" == "$src"/* || ( "$src" == "/" && "$BK_VOL" != "/" ) ]]; then
        rel="${BK_VOL#"$src"}"; rel="${rel#/}"
        echo "./$rel" >> "$excl"
    fi
    echo
    echo "Exclusions (relative to $src):"
    sed 's/^/  /' "$excl"
    read -rp "Edit the exclusion list before the backup? [y/N] " a
    [[ ${a,,} == y* ]] && "${EDITOR:-vi}" "$excl"

    local cc; cc="$(compress_cmd "$comp")"
    echo
    echo "Creating $kind backup of '$src' -> $BK_DIR/$name"
    echo "Compression: $comp (using up to $CORES CPU cores)"
    read -rp "Start the backup now? [Y/n] " a
    if [[ ${a,,} == n* ]]; then rm -f "$excl"; return 0; fi

    # keep a copy of the incremental state so a failed run can be rolled back
    [[ -f $snar ]] && cp "$snar" "$snar.bak"
    local start
    start="$(date +%s)"
    tar --listed-incremental="$snar" --one-file-system --numeric-owner \
        --acls --xattrs --exclude-from="$excl" -cpf - -C "$src" . 2> >(grep -v 'socket ignored' >&2) \
        | $cc > "$BK_DIR/$name"
    local rcs=("${PIPESTATUS[@]}")
    local trc=${rcs[0]} crc=${rcs[1]}
    rm -f "$excl"
    if (( crc != 0 )) || (( trc >= 2 )); then
        echo
        echo "ERROR: backup failed (tar exit $trc, compressor exit $crc) - the archive is NOT usable."
        rm -f "$BK_DIR/$name"
        if [[ -f $snar.bak ]]; then mv "$snar.bak" "$snar"; else rm -f "$snar"; fi
        return 2
    fi
    rm -f "$snar.bak"
    if (( trc == 1 )); then
        echo "WARNING: some files changed while they were read - the backup is usable,"
        echo "         but verify the affected files (see tar messages above)."
    fi

    local idx="$BK_DIR/index.txt" n=1
    [[ -f $idx ]] && n=$(( $(wc -l < "$idx") + 1 ))
    echo "$n|$name|$(date '+%F %T')|$desc" >> "$idx"
    echo
    echo "Backup finished in $(( $(date +%s) - start ))s, size: $(du -h "$BK_DIR/$name" | cut -f1)"
    echo
    echo "Restore points in $BK_DIR:"
    show_index
    return 0
}

# =============================================================================
#  Restore
# =============================================================================
cleanup_mounts() {
    local m
    for m in /sys/firmware/efi/efivars /sys /proc /dev/pts /dev; do
        umount "$RESTORE_MNT$m" 2>/dev/null
    done
    umount "$RESTORE_MNT/boot/efi" 2>/dev/null
    umount "$RESTORE_MNT" 2>/dev/null
}

do_restore() {
    require_root || return 2
    echo
    echo "******************************************************************************"
    echo "        Restore selected - ATTENTION: this will ERASE the target disk!"
    echo "******************************************************************************"
    echo
    [[ -d /sys/firmware/efi ]] || { echo "ERROR: PC is booted in legacy BIOS mode - restore supports UEFI only."; return 2; }
    local tool
    for tool in sgdisk partprobe mkfs.vfat mkfs.ext4 blkid lsblk tar findmnt chroot; do
        command -v "$tool" >/dev/null || { echo "ERROR: required tool '$tool' is missing - install it first."; return 2; }
    done

    # --- choose the host whose backup chain shall be restored ------------------
    local base="$BK_VOL/systembackup" hosts=() h
    [[ -d $base ]] || { echo "ERROR: No backups found in $base."; return 2; }
    mapfile -t hosts < <(ls -1 "$base" 2>/dev/null)
    (( ${#hosts[@]} >= 1 )) || { echo "ERROR: No backups found in $base."; return 2; }
    if (( ${#hosts[@]} == 1 )); then
        BK_DIR="$base/${hosts[0]}"
    else
        echo "Backed-up hosts:"; printf '  %s\n' "${hosts[@]}"
        read -rp "Host to restore: " h
        [[ -n $h && -d $base/$h ]] || { echo "ERROR: No such host."; return 2; }
        BK_DIR="$base/$h"
    fi
    local idx="$BK_DIR/index.txt"
    [[ -f $idx ]] || { echo "ERROR: $idx not found."; return 2; }
    echo
    echo "Available restore points:"
    show_index
    local sel
    while :; do
        read -rp "Index of the restore point (usually the highest): " sel
        [[ $sel =~ ^[1-9][0-9]*$ ]] && grep -q "^$sel|" "$idx" && break
        echo "  Please enter a valid index number."
    done

    # --- collect the archive chain: last full backup up to the chosen index ----
    local chain=() n file rest
    while IFS='|' read -r n file rest; do
        (( n > sel )) && break
        [[ $file == full_* ]] && chain=()
        chain+=("$file")
    done < "$idx"
    [[ ${chain[0]} == full_* ]] || { echo "ERROR: No full backup found for index $sel - index file corrupt?"; return 2; }
    echo "Archives to apply in order:"; printf '  %s\n' "${chain[@]}"

    # --- choose the target disk -------------------------------------------------
    echo
    echo "Disks on this system:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE | grep -v ' loop'
    local bk_src bk_disk disk
    bk_src="$(findmnt -n -o SOURCE --target "$BK_VOL")"
    bk_disk="$(lsblk -no PKNAME "$bk_src" 2>/dev/null | head -1)"
    while :; do
        read -rp "Disk to restore onto, e.g. sda or nvme0n1 (x = back to menu): " disk
        [[ ${disk,,} == x ]] && return 0
        disk="${disk#/dev/}"
        [[ -b /dev/$disk ]] || { echo "  /dev/$disk is not a block device."; continue; }
        [[ "$(lsblk -dno TYPE "/dev/$disk")" == disk ]] || { echo "  /dev/$disk is not a whole disk."; continue; }
        if [[ -n $bk_disk && $disk == "$bk_disk" ]]; then
            echo "  ERROR: /dev/$disk contains the backup storage volume -"
            echo "         restoring onto it would destroy your backups. Choose another disk."
            continue
        fi
        if lsblk -no MOUNTPOINT "/dev/$disk" | grep -q .; then
            echo "  ERROR: /dev/$disk has mounted partitions - unmount them first."
            continue
        fi
        break
    done
    echo
    echo "Details of /dev/$disk:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "/dev/$disk"
    echo
    echo "******************************************************************************"
    echo "  ALL DATA ON /dev/$disk WILL BE ERASED and replaced with restore point $sel."
    echo "******************************************************************************"
    local a
    read -rp "Type YES (uppercase) to continue: " a
    [[ $a == YES ]] || { echo "Cancelled."; return 0; }

    # --- partition: GPT with 512 MiB EFI system partition + ext4 root -----------
    local p=""; [[ $disk =~ [0-9]$ ]] && p="p"
    local esp="/dev/${disk}${p}1" rootp="/dev/${disk}${p}2"
    echo "Partitioning /dev/$disk (GPT: 512 MiB EFI + Linux root)..."
    sgdisk --zap-all "/dev/$disk" >/dev/null || { echo "ERROR: Wiping /dev/$disk failed."; return 2; }
    sgdisk -n1:0:+512M -t1:ef00 -c1:"EFI" -n2:0:0 -t2:8300 -c2:"Linux" "/dev/$disk" >/dev/null \
        || { echo "ERROR: Partitioning /dev/$disk failed."; return 2; }
    partprobe "/dev/$disk"; sleep 2
    [[ -b $esp && -b $rootp ]] || { echo "ERROR: Partitions $esp / $rootp did not appear."; return 2; }
    mkfs.vfat -F32 "$esp" >/dev/null       || { echo "ERROR: Formatting the EFI partition failed."; return 2; }
    mkfs.ext4 -qF "$rootp"                  || { echo "ERROR: Formatting the root partition failed."; return 2; }
    mkdir -p "$RESTORE_MNT"
    mount "$rootp" "$RESTORE_MNT"           || { echo "ERROR: Mounting $rootp failed."; return 2; }
    mkdir -p "$RESTORE_MNT/boot/efi"
    mount "$esp" "$RESTORE_MNT/boot/efi"    || { echo "ERROR: Mounting $esp failed."; cleanup_mounts; return 2; }

    # --- extract the archive chain ----------------------------------------------
    local f dc rc1 rc2
    for f in "${chain[@]}"; do
        dc="$(decompress_cmd_for "$f")" || { echo "ERROR: Unknown archive type: $f"; cleanup_mounts; return 2; }
        echo "Extracting $f ..."
        $dc < "$BK_DIR/$f" | tar --listed-incremental=/dev/null --numeric-owner --acls --xattrs -xpf - -C "$RESTORE_MNT"
        local xrcs=("${PIPESTATUS[@]}")
        rc1=${xrcs[0]}; rc2=${xrcs[1]}
        if (( rc1 != 0 || rc2 != 0 )); then
            echo "ERROR: Extracting $f failed (decompress $rc1, tar $rc2) - the disk is NOT restored."
            cleanup_mounts
            return 2
        fi
    done

    # --- regenerate /etc/fstab with the new filesystem UUIDs --------------------
    echo "Regenerating /etc/fstab with the new filesystem UUIDs..."
    local ruuid euuid
    ruuid="$(blkid -s UUID -o value "$rootp")"
    euuid="$(blkid -s UUID -o value "$esp")"
    [[ -f $RESTORE_MNT/etc/fstab ]] && cp "$RESTORE_MNT/etc/fstab" "$RESTORE_MNT/etc/fstab.before-restore"
    mkdir -p "$RESTORE_MNT/etc"
    {
        echo "# regenerated by $APP_NAME on $(date '+%F %T')"
        echo "# the previous file was saved as /etc/fstab.before-restore"
        echo "UUID=$ruuid  /          ext4  defaults    0 1"
        echo "UUID=$euuid  /boot/efi  vfat  umask=0077  0 2"
    } > "$RESTORE_MNT/etc/fstab"

    # --- install the boot loader (GRUB, UEFI) ------------------------------------
    echo "Installing the boot loader (GRUB, UEFI)..."
    local m grubrc=1
    for m in /dev /dev/pts /proc /sys /sys/firmware/efi/efivars; do
        mount --bind "$m" "$RESTORE_MNT$m" 2>/dev/null
    done
    if chroot "$RESTORE_MNT" sh -c 'command -v grub-install' >/dev/null 2>&1; then
        chroot "$RESTORE_MNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck \
            && chroot "$RESTORE_MNT" sh -c 'command -v update-grub >/dev/null 2>&1 && update-grub || grub-mkconfig -o /boot/grub/grub.cfg'
        grubrc=$?
    elif chroot "$RESTORE_MNT" sh -c 'command -v grub2-install' >/dev/null 2>&1; then
        chroot "$RESTORE_MNT" grub2-install --target=x86_64-efi --efi-directory=/boot/efi --recheck \
            && chroot "$RESTORE_MNT" grub2-mkconfig -o /boot/grub2/grub.cfg
        grubrc=$?
    else
        echo "WARNING: No grub-install found inside the restored system."
    fi
    (( grubrc == 0 )) || {
        echo "WARNING: Boot loader setup failed. The files are restored, but you must"
        echo "         install GRUB manually from a live system (chroot into $RESTORE_MNT)."
    }
    cleanup_mounts
    echo
    echo "Restore finished. Remove the live/backup media and reboot into the restored system."
    return 0
}

# =============================================================================
#  Help
# =============================================================================
show_help() {
    cat <<EOF

Using the Backup and Restore script
===================================

BACKUP  (b)
  1. Boot a live Linux (or run on the live system - tar warns about files that
     change while they are read) and make sure the backup volume is mounted.
     It is found via the marker file $MARKER in its root.
  2. Choose b, then enter the mountpoint of the filesystem to back up.
     --one-file-system is used, so nested mounts are not crossed.
  3. Pick the compression: zstd is fast and strong (recommended), xz is the
     smallest (as used by kernel.org), gzip/pigz for compatibility. All of
     them use every CPU core ($CORES detected here).
  4. The first run creates a FULL archive, later runs append INCREMENTAL
     archives (GNU tar --listed-incremental) that only contain the changes.
     Answer 'n' to start a fresh full chain from time to time.
  5. Review the exclusion list - OneDrive-like problem folders do not exist on
     Linux, but virtual filesystems, caches and swap files are excluded.
  6. Verify the backup, ideally with a test restore on a spare disk, or at
     least by listing an archive:  zstd -dc <archive> | tar -t | head

RESTORE  (r)  -  live media + UEFI only, ERASES the selected disk
  1. Boot a live Linux in UEFI mode, mount the backup volume, run this script.
  2. Choose r, then the host, then the restore point (usually the highest
     index). The full backup and all incrementals up to that point are applied
     in order automatically.
  3. Select the target disk carefully - all data on it is erased. The script
     shows the disk details first and refuses disks that contain the backup
     storage volume or mounted partitions.
  4. The disk gets a fresh GPT layout (EFI + ext4 root), the archives are
     extracted, /etc/fstab is regenerated with the new UUIDs and GRUB is
     installed for UEFI boot.

See README.md in this folder for the full documentation.
EOF
}

# =============================================================================
#  Main
# =============================================================================
banner
find_backup_volume || die "No mounted filesystem with the marker file '$MARKER' found.
       Create an empty file named $MARKER in the root of the (mounted)
       filesystem that shall store the backups, then run again."
echo "Backup storage: $BK_VOL  (chains in $BK_VOL/systembackup/<hostname>)"

while :; do
    echo
    read -rp "Choose [b]ackup, [r]estore, [h]elp or [q]uit: " choice
    case "${choice,,}" in
        b) do_backup ;;
        r) do_restore ;;
        h) show_help ;;
        q) exit 0 ;;
        *) : ;;
    esac
done
