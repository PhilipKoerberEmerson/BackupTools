# SystemBackup — WinPE-based Windows System Backup & Restore

`backup.cmd` is an interactive script that creates **indexed, incremental full-system backups** of a Windows installation into a single WIM file, and can **restore** them onto a (new) disk — including partitioning and making it bootable. It runs from **WinPE** and uses only built-in Windows tools (`dism`, `diskpart`, `bcdboot`, `bcdedit`).

> ⚠️ **Restore is UEFI-only.** The restore part partitions the target disk for UEFI boot and refuses to run on BIOS/legacy-booted systems.

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
4. **Companion files** expected by the script:

   | File | Location | Purpose |
   |------|----------|---------|
   | `ExclusionList.ini` | `%UFDV%:\scripts\` | Base DISM `[ExclusionList]` |
   | `CompressionExclusionList.ini` | `%UFDV%:\scripts\` | DISM `[CompressionExclusionList]` |
   | `ListDisk.txt` | `%DEPLOYTOOLS%\` | diskpart script to list disks (restore) |
   | `CreatePartitions-UEFI.txt` | next to `backup.cmd` | diskpart script: UEFI partition layout (restore) |
   | `HideRecoveryPartitions-UEFI.txt` | next to `backup.cmd` | diskpart script: hide recovery partition (restore) |

   The environment variables `UFDV` (USB flash drive volume) and `DEPLOYTOOLS` must be set by the WinPE startup environment.

## Usage

### Creating a backup

1. Plug the backup drive into a USB port (preferably USB-3 SuperSpeed; avoid USB-C ports if you see DISM I/O problems under WinPE).
2. Boot the PC from the backup drive (e.g. press **F12** for the one-time boot menu and select the USB drive in UEFI mode).
3. The script starts automatically (or run `backup` manually). Choose **B** for backup.
4. Enter the **drive letter of the volume to capture** — typically the large Windows partition (a `diskpart` volume list is shown first).
5. Optionally enter a **description** for this restore point (no need for a date — each WIM index stores one automatically).
6. Review the generated **`backup.ini`** exclusion config. OneDrive and WSL folders are pre-excluded, but double-check for hidden `OneDriveCloudTemp` folders (`dir /a`) and additional WSL paths like `C:\Users\<name>\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_...` — add them to `[ExclusionList]` if present.
7. Confirm — DISM captures (first run) or appends (later runs) the image into `backup.wim`.
8. **Verify the backup**: ideally run a test restore on a similar PC, or at least mount the WIM with `dism /Mount-Image` and inspect it. Only a real restore proves the backup works.

### Restoring a backup

> ⚠️ **This deletes ALL data on the selected target disk.** Read every prompt carefully.

1. Boot the PC from the backup drive as above. Choose **R** for restore.
2. The script lists all **indexes** inside `backup.wim` with their dates and descriptions. Pick the one you want — typically the highest (latest) index.
3. Select the **target disk number** — typically the internal HDD/SSD. Use the disk sizes as guidance and make absolutely sure you do **not** select the backup drive itself!
4. Confirm the final safety prompts (you can still abort with `Ctrl+C`).
5. The script then:
   - verifies it runs in WinPE and the PC is booted in **UEFI** mode,
   - partitions the target disk (UEFI layout per `CreatePartitions-UEFI.txt`),
   - applies the selected WIM index to the Windows partition (`W:`),
   - writes the boot files with `bcdboot` and puts Windows Boot Manager first in the UEFI boot order,
   - hides the recovery partition.
6. When finished, check the output — especially that DISM completed successfully — then reboot into the restored Windows.

## Tips & troubleshooting

- During backup you can open additional CMD windows (`cmdus` / `cmdde` / `start`, depending on your WinPE setup) to intervene or investigate while DISM runs.
- Open/locked files are not an issue since the captured Windows is offline (you boot from WinPE, not from the system being backed up).
- If DISM fails during capture, the most common culprits are OneDrive placeholder files and WSL VHDX files — extend the `[ExclusionList]` accordingly.
