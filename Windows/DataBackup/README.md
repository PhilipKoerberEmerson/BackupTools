# DataBackup — BackupMyData for Windows 10 / 11

`backupMyData.cmd` is a single, self-contained script that backs up any number of folders to a local disk, USB drive, or network share. Its companion `restoreMyData.cmd` safely restores any backup version. No installation, no third-party tools — it only uses what ships with Windows (`robocopy`, `dism`, `schtasks`, `powershell`).

## Features

- 🗂️ **Two backup modes**
  - **TIMESTAMP** — every run creates a new folder `<TARGET>\yyyy-MM-dd_HH-mm-ss\<SourceName>` with a full copy (robocopy). Browsable directly in Explorer; each run needs the full amount of space.
  - **WIM** — every source is kept in a single `<TARGET>\<SourceName>.wim` image file. The first run captures a full image, later runs *append* a new version (DISM). Unchanged files are stored only once, so each version only costs the changes. Requires administrator rights.
- ⏰ **Automatic backups** via the Windows Task Scheduler — daily, weekly, at user logon, or at system startup. Catches up missed runs and also runs on battery power.
- 🖱️ **Interactive menu** for configuration, manual runs, schedule management, and status — or fully scriptable via command-line switches.
- 📝 **Logging** to `<TARGET>\_logs` with per-run log files and meaningful exit codes.
- 🔧 **Plain-text configuration** in an `.ini` file next to the script — easy to edit, easy to version.

## Quick start

```bat
:: 1. Interactive: configure sources, target, mode, and (optionally) a schedule
backupMyData.cmd

:: 2. Or step by step:
backupMyData.cmd /setup      :: configure sources, target and mode
backupMyData.cmd /run        :: run a backup now
backupMyData.cmd /install    :: install the automatic schedule (admin)
backupMyData.cmd /status     :: show configuration and schedule status
```

## Command-line reference

| Option | Description |
|--------|-------------|
| *(none)* | Interactive menu |
| `/run` | Run the backup unattended (used by the scheduled task) |
| `/setup` | Configure sources, target and mode, then optionally install the schedule |
| `/install` | Install or update the automatic backup schedule (admin) |
| `/uninstall` | Remove the automatic backup schedule (admin) |
| `/status` | Show configuration and schedule status |
| `/cfg <file>` | Use another configuration file (default: `backupMyData.ini` next to the script) |
| `/?` `/h` `/help` | Show built-in help |

All options accept `/` or `-` as prefix, e.g. `-run`.

**Exit codes:** `0` = success · `1` = completed with warnings · `2` = error

## Configuration file

Created by `/setup`, may also be edited manually (no spaces around `=`):

```ini
; comment
TARGET=E:\Backup
MODE=TIMESTAMP              ; TIMESTAMP or WIM
WIM_COMPRESS=max            ; none, fast or max (WIM mode only)
SOURCE=C:\Users\me\Documents
SOURCE=D:\Projects          ; repeat SOURCE= for every folder
```

> **Note:** Paths containing `!` are not supported. Log files are written to `<TARGET>\_logs`.

## Restoring with restoreMyData.cmd (recommended)

`restoreMyData.cmd` is an interactive restore wizard for both backup modes. Data safety comes first: it **only reads until you confirm the final restore plan**, and you can cancel at every step.

```bat
restoreMyData.cmd                        :: start the wizard (uses TARGET= from backupMyData.ini)
restoreMyData.cmd /backup F:\Backup      :: restore from another location, e.g. USB disk with a new drive letter
restoreMyData.cmd /cfg D:\other.ini      :: read the backup location from another configuration file
```

The wizard guides you through seven steps:

1. **Backup location** — taken from `TARGET=` in `backupMyData.ini`, can be changed.
2. **Backup type** — if both TIMESTAMP and WIM backups exist, you choose; the most recent one is shown.
3. **Backup version** — newest first, the latest is marked. Pick an **older version** when something was deleted or damaged before the latest backup ran. The status of every version (OK / warnings / errors / incomplete) is read from `<TARGET>\_logs\backup_*.log`.
4. **Backed-up folder** — one of the `SOURCE` folders; its original location comes from the backup log.
5. **What to restore** — everything, a single sub-folder, or a single file. You can browse the backup in Explorer first.
6. **Destination and method**
   - `[1]` a **new, empty folder** — safest, nothing existing is touched (recommended)
   - `[2]` original location, **only add missing files** — existing files stay unchanged
   - `[3]` original location, **replace files that differ** — shows the list of affected files, offers a **safety copy** of every file before it is replaced (`<destination>_before_restore_<timestamp>`), and starts only after you type `OVERWRITE`
7. **Restore plan** — files and size in MB/GB to copy, files left unchanged or replaced, free space on the destination. **The restore does not start if the free space is insufficient** (data + 5 % + 64 MB headroom) or if a FAT32 destination cannot hold files ≥ 4 GB.

Files that exist only at the destination are **never deleted** by any method. Restores are logged to `<TARGET>\_logs\restore_<timestamp>.log` (or `%TEMP%` if the backup location is read-only).

> **Note:** WIM restores need administrator rights — the wizard offers to restart elevated. The selected image is mounted read-only under `%TEMP%` and unmounted afterwards; after an interrupted run, clean up with `dism /Cleanup-Mountpoints` in an elevated console. Mapped network drives are not visible in an elevated console — use a `\\server\share` path.

## Restoring manually from a WIM backup

In an elevated console:

```bat
:: List available versions
dism /Get-ImageInfo /ImageFile:"E:\Backup\Documents.wim"

:: Restore a version to a folder
dism /Apply-Image /ImageFile:"E:\Backup\Documents.wim" /Index:3 /ApplyDir:"C:\Restore"

:: Browse a version read-only
dism /Mount-Image /ImageFile:"E:\Backup\Documents.wim" /Index:3 /MountDir:"C:\Mnt" /ReadOnly
dism /Unmount-Image /MountDir:"C:\Mnt" /Discard
```

7-Zip can also open `.wim` files directly.

TIMESTAMP backups are plain folders — just copy the files back with Explorer or robocopy.

## Scheduled task details

The schedule is installed as Task Scheduler task **`BackupMyData`** — the supported way on Windows 10/11 to run a script unattended. It runs with highest privileges, catches up missed runs, and also runs on battery power.

- Run as **SYSTEM** for local/USB targets (no password needed).
- Run as **your user** for network share targets (password is asked once).
- Manage it anytime with `taskschd.msc` or `schtasks /Run /TN "BackupMyData"`.

## Good to know

- **WIM mode** needs administrator rights and fails on open/locked files — close applications that use the source data before the backup runs.
- **TIMESTAMP mode** uses robocopy with retries, multithreading, and (when elevated) backup mode `/B` to read files regardless of ACLs.
- The backup target itself, `$RECYCLE.BIN`, and `System Volume Information` are automatically excluded.
