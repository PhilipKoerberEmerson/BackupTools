# DataBackup — BackupMyData for Linux

`backupMyData.sh` is a single, self-contained bash script that backs up any number of folders to a local disk, USB drive, or mounted network share. No installation, no exotic dependencies — it only needs `bash`, `rsync` and (for scheduling) systemd or cron.

It is the Linux twin of the [Windows DataBackup tool](../../Windows/DataBackup/README.md) and follows the same concepts.

## Features

- 🗂️ **Two backup modes**
  - **TIMESTAMP** — every run creates a new folder `<TARGET>/yyyy-mm-dd_HH-MM-SS/<SourceName>` with a full copy (rsync). Browsable with any file manager; each run needs the full amount of space.
  - **SNAPSHOT** — every run creates `<TARGET>/snapshots/<timestamp>/<SourceName>`. Unchanged files are **hard-linked** to the previous snapshot (`rsync --link-dest`), so each snapshot looks and behaves like a full copy but only costs the changed data. `<TARGET>/snapshots/latest` always points to the most recent snapshot. This is the Linux equivalent of the Windows WIM mode — with the bonus that no special tools are needed to browse or restore.
- ⏰ **Automatic backups** via **systemd timer** (preferred, with `Persistent=true` to catch up missed runs) or an `/etc/cron.d` entry as fallback — daily, weekly, or at boot.
- 🖱️ **Interactive menu** for configuration, manual runs, schedule management, and status — or fully scriptable via command-line options.
- 📝 **Logging** to `<TARGET>/_logs` with per-run log files and meaningful exit codes.
- 🔧 **Plain-text configuration** in a `.conf` file next to the script — same format as the Windows tool.

## Quick start

```bash
# 1. Interactive: configure sources, target, mode, and (optionally) a schedule
./backupMyData.sh

# 2. Or step by step:
./backupMyData.sh --setup        # configure sources, target and mode
./backupMyData.sh --run          # run a backup now
sudo ./backupMyData.sh --install # install the automatic schedule
./backupMyData.sh --status       # show configuration and schedule status
```

## Command-line reference

| Option | Description |
|--------|-------------|
| *(none)* | Interactive menu |
| `--run` | Run the backup unattended (used by the schedule) |
| `--setup` | Configure sources, target and mode, then optionally install the schedule |
| `--install` | Install or update the automatic backup schedule (root) |
| `--uninstall` | Remove the automatic backup schedule (root) |
| `--status` | Show configuration and schedule status |
| `--cfg FILE` | Use another configuration file (default: `backupMyData.conf` next to the script) |
| `-h` `--help` | Show built-in help |

**Exit codes:** `0` = success · `1` = completed with warnings · `2` = error

## Configuration file

Created by `--setup`, may also be edited manually:

```ini
# comment
TARGET=/mnt/backup
MODE=SNAPSHOT               # TIMESTAMP or SNAPSHOT
SOURCE=/home/me/Documents
SOURCE=/srv/projects        # repeat SOURCE= for every folder
```

## Restoring

Both modes produce plain directory trees — copy files back with `cp`, a file manager, or rsync:

```bash
rsync -a /mnt/backup/snapshots/latest/Documents/ /home/me/Documents/
```

## Scheduled backup details

- With systemd, the schedule is installed as `backupmydata.timer` + `backupmydata.service` in `/etc/systemd/system`. Missed runs are caught up (`Persistent=true`), and the backup runs with low CPU/IO priority (`Nice=10`, `IOSchedulingClass=idle`).
- Manage it with `systemctl list-timers backupmydata.timer` or `systemctl start backupmydata.service`.
- Without systemd, a `/etc/cron.d/backupmydata` entry is created instead.

## Good to know

- SNAPSHOT mode needs a target filesystem that supports hard links (ext4, xfs, btrfs, …) — **not** FAT/exFAT. Deleting an old snapshot never breaks newer ones; the data of a file is only freed when the last snapshot referencing it is removed.
- If the backup target lies inside a source folder, it is excluded automatically.
- rsync exit codes 23/24 (partial transfer, e.g. files vanished while reading) are reported as warnings; everything else fails the run.
