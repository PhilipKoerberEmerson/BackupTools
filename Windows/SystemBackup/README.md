# SystemBackup — WinPE-based Windows System Backup & Restore

`backup.cmd` is an interactive script that creates **indexed, incremental full-system backups** of a Windows installation into a single WIM file, and can **restore** them either onto a whole (new) disk — including partitioning and making it bootable (bare-metal recovery) — or onto a **single existing partition** when the disk layout is still intact. It runs from **WinPE** and uses only built-in Windows tools (`dism`, `diskpart`, `bcdboot`, `bcdedit`).

> ⚠️ **Disk restore is UEFI-only.** It partitions the target disk for UEFI boot and refuses to run on BIOS/legacy-booted systems. Partition restore also works in legacy BIOS mode, but then does not refresh the boot files.

## How it works

- Every backup is **appended as a new index** to one big `backup.wim`. Unchanged files are stored only once, so each additional backup only costs the changed data.
- Each index gets a timestamp and an optional free-text description, so you can identify the right restore point later.
- An index overview is written to `backup.txt` next to the WIM after every run.
- Problematic folders (**OneDrive** and **WSL** distributions) are detected per user profile and excluded automatically via a generated DISM config file (`backup.ini`), which you can review and edit before the capture starts.

## Requirements

1. **A WinPE boot medium** — creating one is out of scope here (see Microsoft's [WinPE documentation](https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe-intro)).
2. **A large NTFS volume** to store the backup, marked with an (empty) file named `bigWimVolume.txt` in its root. The script scans drive letters C:–Z: for this marker to find the backup storage.
3. **Recommended layout:** one external USB hard disk / SSD with
   - a small **FAT32 partition** that boots WinPE and auto-starts `backup.cmd`, and
   - a big **NTFS partition** (containing `bigWimVolume.txt`) for the `backup.wim`.
4. **Optional companion files** — built-in defaults are used when they are missing:

   | File | Location | Purpose |
   |------|----------|---------|
   | `ExclusionList.ini` | `%UFDV%:\scripts\` | Base DISM `[ExclusionList]` |
   | `CompressionExclusionList.ini` | `%UFDV%:\scripts\` | DISM `[CompressionExclusionList]` |
   | `CreatePartitions-UEFI.txt` | next to `backup.cmd` | diskpart script: UEFI partition layout (restore) |
   | `HideRecoveryPartitions-UEFI.txt` | next to `backup.cmd` | diskpart script: hide recovery partition (restore) |

   The environment variable `UFDV` (USB flash drive volume) is normally set by the WinPE startup environment; if it is not set, the drive the script runs from is used. Any `select disk` lines in the diskpart companion files are **ignored** — the disk chosen interactively during restore is always used.

## Usage

### Creating a backup

1. Plug the backup drive into a USB port (preferably USB-3 SuperSpeed; avoid USB-C ports if you see DISM I/O problems under WinPE).
2. Boot the PC from the backup drive (e.g. press **F12** for the one-time boot menu and select the USB drive in UEFI mode).
3. The script starts automatically (or run `backup` manually). Choose **B** for backup.
4. Enter the **drive letter of the volume to capture** — typically the large Windows partition (a `diskpart` volume list is shown first).
5. Optionally enter a **description** for this restore point (no need for a date — each WIM index stores one automatically).
6. Review the generated DISM exclusion config (shown on screen, editable in Notepad). OneDrive and WSL folders are pre-excluded per user profile, but double-check for hidden `OneDriveCloudTemp` folders (`dir /a`) and additional WSL paths like `C:\Users\<name>\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_...` — add them to `[ExclusionList]` if present. The config used for each run is archived as `backup_<timestamp>.ini` next to the WIM file.
7. Confirm — DISM captures (first run) or appends (later runs) the image into `backup.wim`. If DISM fails, the script reports an error and exits with a non-zero exit code instead of pretending success.
8. **Verify the backup**: ideally run a test restore on a similar PC, or at least mount the WIM with `dism /Mount-Image` and inspect it. Only a real restore proves the backup works.

### Restoring a backup

Choose **R** for restore, then pick the restore mode:

| Mode | When to use | What is erased |
|------|-------------|----------------|
| **D** — Disk restore (bare metal) | New/empty disk, broken partition table, disaster recovery | The **whole** selected disk |
| **P** — Partition restore | The PC still has its partitions (EFI, MSR, Windows, Recovery) but Windows itself is broken or should be rolled back | **Only** the selected partition |

#### Disk restore (D)

> ⚠️ **This deletes ALL data on the selected target disk.** Read every prompt carefully.

1. Boot the PC from the backup drive as above. Choose **R**, then **D**. The script first verifies it runs in **WinPE** and the PC is booted in **UEFI** mode.
2. The script lists all **indexes** inside `backup.wim` with their dates and descriptions. Pick the one you want — typically the highest (latest) index. Invalid indexes are rejected.
3. Select the **target disk number** — typically the internal HDD/SSD. The script shows the details of the selected disk for a visual check and **refuses disks that contain the backup storage volume**, so you cannot accidentally wipe your backups.
4. Confirm the final safety prompts (you can still abort with `Ctrl+C`).
5. The script then:
   - partitions the selected disk (UEFI layout — `CreatePartitions-UEFI.txt` if present, otherwise a built-in standard layout; the interactively chosen disk is always enforced),
   - applies the selected WIM index to the Windows partition (`W:`) and **stops immediately if DISM fails**,
   - writes the boot files with `bcdboot` and puts Windows Boot Manager first in the UEFI boot order,
   - hides the recovery partition.
6. When finished, check the output — especially that DISM completed successfully — then reboot into the restored Windows.

#### Partition restore (P)

> ⚠️ **This deletes ALL data on the selected partition** — other partitions and the partition table are not touched.

1. Boot the PC from the backup drive. Choose **R**, then **P** (the script verifies it runs in **WinPE**).
2. Pick the **index** to restore, as above.
3. A `diskpart` volume list is shown. Enter the **drive letter of the partition to restore** — note that in WinPE the Windows partition often does *not* have the letter `C:`; identify it by label and size. The script shows the volume details, refuses the backup storage volume and the script/boot drive, and warns if the volume contains no `\Windows\System32` folder.
4. Confirm the final safety prompts (you can still abort with `Ctrl+C`).
5. The script then:
   - quick-formats the volume as NTFS (label `Windows`) — this ensures no stale files of the old installation remain,
   - applies the selected WIM index to it and **stops immediately if DISM fails**,
   - on UEFI systems: temporarily assigns a letter to the **EFI system partition of the same disk**, refreshes the boot files with `bcdboot /f UEFI`, and removes the letter again. If this step fails, a warning with the manual `bcdboot` command is shown — the existing boot entry usually keeps working anyway, because the partition itself is unchanged.
6. Reboot into the restored Windows.

Notes:
- **Backup on the same disk:** partition restore also works when `backup.wim` lives on another partition of the *same* disk (e.g. one big SSD with EFI, MSR, Windows, Recovery and a data partition holding the backup). Only the backup volume itself is refused as a target. Disk restore (D) refuses such a disk, since it would wipe the backup.
- **BitLocker:** a locked volume is not accessible in WinPE. Unlock it first, e.g. `manage-bde -unlock C: -RecoveryPassword <key>`. After the restore, the volume is **not encrypted** — re-enable BitLocker in Windows if needed.
- The backup should originate from the **same PC** (or one with an identical partition layout); the Windows Recovery Environment configuration in the image refers to the recovery partition of the original disk.

## Tips & troubleshooting

- During backup you can open additional CMD windows (`cmdus` / `cmdde` / `start`, depending on your WinPE setup) to intervene or investigate while DISM runs.
- Open/locked files are not an issue since the captured Windows is offline (you boot from WinPE, not from the system being backed up).
- If DISM fails during capture, the most common culprits are OneDrive placeholder files and WSL VHDX files — extend the `[ExclusionList]` accordingly.

## License & Disclaimer

Licensed under the [MIT License](../../LICENSE).

**USE ENTIRELY AT YOUR OWN RISK.** These scripts are provided **"AS IS"** without warranty or guarantee of any kind. Neither the author(s) nor any affiliated company assumes **any responsibility or liability** for data loss, system failure, or damages resulting from the use of this software. Every script **must be thoroughly reviewed and tested by the user prior to use**. Always verify your backups before relying on them.
