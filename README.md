# BackupTools

A collection of small, dependency-free backup tools for everyday use. Each tool lives in its own folder with a detailed README — this page only gives a short overview.

## Windows

### [DataBackup](Windows/DataBackup/) — scheduled folder backups

Backs up any number of folders to a local disk, USB drive, or network share — either as browsable timestamped full copies (robocopy) or as space-saving incremental WIM images (DISM). Includes an interactive menu and Task Scheduler integration for fully automatic backups. Uses only tools that ship with Windows 10 / 11.

➡️ Details: [Windows/DataBackup/README.md](Windows/DataBackup/README.md)

### [SystemBackup](Windows/SystemBackup/) — full-system backup & restore from WinPE

Creates indexed, incremental full-system backups of a Windows installation into a single WIM file, booted from a WinPE USB drive. Can restore a backup onto a (new) disk including UEFI partitioning and boot setup — a complete bare-metal recovery solution.

➡️ Details: [Windows/SystemBackup/README.md](Windows/SystemBackup/README.md)

## Linux

*(coming soon)*

## License

Personal utility scripts — use at your own risk. Always verify your backups before relying on them.
