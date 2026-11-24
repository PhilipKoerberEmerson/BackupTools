# SystemBackup — Linux Full-System Backup & Restore

`backup.sh` is an interactive bash script that creates **indexed, incremental full-system backups** of a Linux root filesystem into a chain of compressed tar archives, and can **restore** them onto a (new) disk — including GPT/UEFI partitioning, fstab regeneration, and GRUB installation.

It is the Linux twin of the [Windows SystemBackup tool](../../Windows/SystemBackup/README.md) and follows the same concepts (marker file, indexed restore points, UEFI-only restore, safety checks).

> ⚠️ **Restore is UEFI-only** and intended to run from **live media** (e.g. a Ubuntu live USB). It partitions the target disk and refuses to run on BIOS/legacy-booted systems.

## How it works

- The first backup creates a **FULL** archive; every later run appends an **INCREMENTAL** archive that only contains the changes — implemented with GNU tar's `--listed-incremental` snapshot file. You can start a fresh full chain at any time.
- Every restore point gets an index, timestamp, and optional description in `index.txt`. On restore, the full archive and all incrementals up to the chosen point are applied automatically in the correct order.
- **Compression uses all CPU cores:**

  | Choice | Tool | Character |
  |--------|------|-----------|
  | `zstd` *(default)* | `zstd -T0` | Very fast, strong compression — best overall choice |
  | `xz` | `xz -T0` | Smallest archives (the format kernel.org uses), slower |
  | `gzip` | `pigz` (parallel) or `gzip` | Maximum compatibility |
  | `none` | `cat` | Fastest, e.g. when the target compresses itself |

- `--one-file-system` keeps the backup on the chosen filesystem; virtual filesystems, caches, and swap files are excluded via a reviewable exclusion list. ACLs and xattrs are preserved.
- A copy of the incremental state is kept during each run, so a failed backup is rolled back cleanly and never corrupts the chain.

## Requirements

1. **Backup storage:** a mounted filesystem with an (empty) marker file named `bigBackupVolume.txt` in its root. The script scans all mounted filesystems for this marker. Chains are stored per host in `<volume>/systembackup/<hostname>/`.
2. **Tools:** `bash`, GNU `tar`, `findmnt`/`lsblk`/`blkid` (util-linux), and the chosen compressor (`zstd` or `xz`; `gzip` is always available). For restore additionally: `sgdisk` (package `gdisk`), `mkfs.vfat` (`dosfstools`), `mkfs.ext4`. All of these are present on common live systems or one `apt install` away.
3. **Optional companion file:** `exclude.lst` next to the script with tar exclude patterns (one per line, relative to the source, e.g. `./home/*/.cache/*`). Built-in defaults are used when it is missing.

## Usage

### Creating a backup

1. Mount the backup volume (the one with `bigBackupVolume.txt`) and run `sudo ./backup.sh`. For a perfectly consistent image boot a live Linux first; backing up the running system also works — tar then warns about files that changed while being read.
2. Choose **b**, then enter the mountpoint of the filesystem to back up (`/` by default).
3. Pick the compression (zstd recommended) and optionally enter a description.
4. Review the exclusion list — edit it in place if needed.
5. The first run creates `full_<timestamp>.tar.zst`, later runs append `incr_<timestamp>.tar.zst`. Answer **n** to the append question to start a fresh full chain from time to time (shorter restore chains, independent history).
6. **Verify the backup**, ideally with a test restore on a spare disk, or at least by listing an archive: `zstd -dc full_....tar.zst | tar -t | head`

### Restoring a backup

> ⚠️ **This erases ALL data on the selected target disk.** Read every prompt carefully.

1. Boot a live Linux in **UEFI mode**, mount the backup volume, and run `sudo ./backup.sh`. Choose **r**.
2. Select the host (if several machines back up to this volume) and the restore point — usually the highest index. The script determines the required archive chain automatically.
3. Select the target disk (e.g. `sda` or `nvme0n1`). The script shows the disk details first and **refuses disks that contain the backup storage volume** or that have mounted partitions. Confirm by typing `YES`.
4. The script then:
   - creates a fresh GPT layout (512 MiB EFI system partition + ext4 root),
   - extracts the full archive and all incrementals in order and **stops immediately if anything fails**,
   - regenerates `/etc/fstab` with the new filesystem UUIDs (the old file is kept as `fstab.before-restore`),
   - chroots into the restored system and installs GRUB for UEFI boot (handles both `grub-install` and `grub2-install` distros).
5. Reboot into the restored system.

## Tips & troubleshooting

- **Restore chain length:** every incremental must be applied on top of the last full backup — start a new full chain occasionally to keep restores fast and reduce risk.
- **Separate `/boot` or LVM/btrfs subvolume layouts** are not recreated by the built-in restore (it builds the standard ESP + ext4 root layout). The archives themselves contain all files, so you can always partition manually and extract the chain yourself.
- If GRUB installation fails (exotic distro), the data is still fully restored — chroot into `/mnt/sysrestore` from the live system and install the boot loader manually.
- `zstd --long=27 -T0` or `xz -9 -T0` squeeze out more compression if storage is tight — adjust the `compress_cmd` function.
