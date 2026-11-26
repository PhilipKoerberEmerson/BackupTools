@echo off
rem ===========================================================================
rem  backup.cmd - Windows full-system backup and restore (WinPE / DISM)
rem
rem  Creates indexed, incremental full-system backups of a Windows volume into
rem  a single WIM file and restores them either onto a whole disk (bare metal,
rem  including UEFI partitioning and boot setup) or onto a single existing
rem  partition (the partition layout stays untouched).
rem
rem  Requirements
rem    - Backup storage: a big NTFS volume with an (empty) marker file
rem      "bigWimVolume.txt" in its root. The script finds it automatically.
rem    - Restore only works from WinPE; disk restore requires UEFI mode.
rem
rem  Optional companion files (built-in defaults are used when missing)
rem    - <UFDV>:\scripts\ExclusionList.ini             DISM [ExclusionList]
rem    - <UFDV>:\scripts\CompressionExclusionList.ini  DISM [CompressionExclusionList]
rem    - CreatePartitions-UEFI.txt (next to this script)       diskpart layout
rem    - HideRecoveryPartitions-UEFI.txt (next to this script)
rem      NOTE: "select disk" lines in these files are ignored - the disk that
rem      was chosen interactively is always used.
rem
rem  See README.md for the full documentation.
rem  PhK 2026-11-22
rem
rem  License and Disclaimer
rem    Licensed under the MIT License - see LICENSE in the repository root:
rem    https://github.com/PhilipKoerberEmerson/BackupTools
rem    USE ENTIRELY AT YOUR OWN RISK. This script is provided "AS IS" without
rem    warranty or guarantee of any kind. Neither the author(s) nor any
rem    affiliated company assumes any responsibility or liability for data
rem    loss, system failure, or damages resulting from its use. Review and
rem    test it thoroughly before use and always verify your backups.
rem ===========================================================================
setlocal EnableExtensions
set "APP_NAME=SystemBackup"
set "APP_VERSION=2.1.0"
set "backupWim=backup.wim"
set "RC=1"
set "startTime=%time%"

rem --- Writable temp folder ---------------------------------------------------
set "TMPDIR=%TEMP%"
if not defined TEMP set "TMPDIR=."

title %APP_NAME% v%APP_VERSION%
echo.
echo ******************************************************************************
echo         %APP_NAME% v%APP_VERSION% - Windows Backup and Restore Script
echo         Note: Restore requires WinPE, disk restore a PC in UEFI mode
echo ******************************************************************************
echo.

rem --- Locate the backup storage volume via its marker file -------------------
set "bigWimVolume="
for %%V in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist "%%V:\bigWimVolume.txt" set "bigWimVolume=%%V"
if not defined bigWimVolume (
    echo ERROR: No volume with the marker file "bigWimVolume.txt" found.
    echo        Create an empty file named bigWimVolume.txt in the root of the
    echo        NTFS volume that shall store the backup, then run again.
    goto :abort
)
echo Backup storage: %bigWimVolume%:\%backupWim%

rem --- Locate the scripts folder with the DISM exclusion lists ----------------
rem     UFDV is normally set by the WinPE startup environment; fall back to the
rem     drive this script runs from.
if not defined UFDV set "UFDV=%~d0"
set "UFDV=%UFDV::=%"
set "SCRIPTS_DIR=%UFDV%:\scripts"

:mainMenu
echo.
choice /c BRQH /m "Choose B to create a backup, R to restore, Q to quit, H for help"
if errorlevel 4 goto :help
if errorlevel 3 goto :quit
if errorlevel 2 goto :restore


rem ===========================================================================
rem  Backup
rem ===========================================================================
:create
echo.
echo ******************************************************************************
echo         Backup selected
echo ******************************************************************************
echo.
call :makeTimestamp

echo Volumes on this system:
echo list volume | diskpart

:selectVolumeToBackup
set "volumeToBackup="
set /p "volumeToBackup=Drive letter of the volume to back up (typically the Windows installation): "
if not defined volumeToBackup goto :selectVolumeToBackup
set "volumeToBackup=%volumeToBackup::=%"
set "volumeToBackup=%volumeToBackup:"=%"
echo %volumeToBackup%| findstr /r /i /c:"^[A-Z]$" >nul || (echo   Please enter a single drive letter, e.g. C. & goto :selectVolumeToBackup)
if not exist "%volumeToBackup%:\" (echo   Volume %volumeToBackup%: is not accessible. & goto :selectVolumeToBackup)
if /i "%volumeToBackup%"=="%bigWimVolume%" (echo   %volumeToBackup%: is the backup storage volume itself - choose another one. & goto :selectVolumeToBackup)

set "BackupNotes="
set /p "BackupNotes=Optional description of this backup (Enter to skip): "

set "action=Append-Image"
if not exist "%bigWimVolume%:\%backupWim%" set "action=Capture-Image /Compress:max"
set "my_description=Backup from %TS% %BackupNotes%"

rem --- Build the DISM configuration file (exclusions) --------------------------
set "CFG=%TMPDIR%\_sysbackup_backup.ini"
if exist "%SCRIPTS_DIR%\ExclusionList.ini" (
    type "%SCRIPTS_DIR%\ExclusionList.ini" > "%CFG%"
) else (
    echo WARNING: "%SCRIPTS_DIR%\ExclusionList.ini" not found - using built-in defaults.
    > "%CFG%" (
        echo [ExclusionList]
        echo \pagefile.sys
        echo \swapfile.sys
        echo \hiberfil.sys
        echo \System Volume Information
        echo \$Recycle.Bin\*
        echo \Windows\CSC
    )
)
rem OneDrive and WSL folders cause DISM problems - exclude them per user profile
if exist "%volumeToBackup%:\Users\" (
    setlocal EnableDelayedExpansion
    for /d %%U in ("%volumeToBackup%:\Users\*") do (
        set "U=%%~U"
        >>"%CFG%" echo !U:~2!\OneDriv*
        >>"%CFG%" echo !U:~2!\AppData\Local\Packages\CanonicalGroupLimited*
    )
    endlocal
)
>>"%CFG%" echo(
if exist "%SCRIPTS_DIR%\CompressionExclusionList.ini" (
    type "%SCRIPTS_DIR%\CompressionExclusionList.ini" >> "%CFG%"
) else (
    echo WARNING: "%SCRIPTS_DIR%\CompressionExclusionList.ini" not found - using built-in defaults.
    >> "%CFG%" (
        echo [CompressionExclusionList]
        echo *.mp3
        echo *.zip
        echo *.cab
        echo \WINDOWS\inf\*.pnf
    )
)

echo.
echo The following DISM configuration file will be used:
echo ------------------------------------------------------------------------------
type "%CFG%"
echo ------------------------------------------------------------------------------
where notepad >nul 2>&1
if not errorlevel 1 (
    choice /c YN /m "Use this configuration as is (N = edit it in Notepad first)"
    if errorlevel 2 notepad "%CFG%"
)

echo.
echo Command: dism /%action% /ImageFile:"%bigWimVolume%:\%backupWim%" /CaptureDir:%volumeToBackup%:\ /Name:"Backup %TS%" /Description:"%my_description%" /ConfigFile:"%CFG%"
choice /c YN /m "Create the backup now"
if errorlevel 2 goto :mainMenu

set "startTime=%time%"
dism /%action% /ImageFile:"%bigWimVolume%:\%backupWim%" /CaptureDir:%volumeToBackup%:\ /Name:"Backup %TS%" /Description:"%my_description%" /ConfigFile:"%CFG%"
set "DISMRC=%errorlevel%"
if not "%DISMRC%"=="0" (
    echo.
    echo ERROR: DISM failed with exit code %DISMRC% - this backup is NOT usable.
    echo        Verify the existing indexes with:
    echo          dism /Get-WimInfo /WimFile:%bigWimVolume%:\%backupWim%
    goto :abort
)
echo.
echo Writing index overview to %bigWimVolume%:\%backupWim:~0,-4%.txt
dism /Get-WimInfo /WimFile:"%bigWimVolume%:\%backupWim%" > "%bigWimVolume%:\%backupWim:~0,-4%.txt"
copy /y "%CFG%" "%bigWimVolume%:\backup_%TS%.ini" >nul
echo Backup created successfully. Verify it with a test restore, or by mounting:
echo   dism /Mount-Image /ImageFile:%bigWimVolume%:\%backupWim% /Index:^<n^> /MountDir:C:\Mnt /ReadOnly
goto :end


rem ===========================================================================
rem  Restore
rem ===========================================================================
:restore
echo.
echo ******************************************************************************
echo         Restore selected
echo ******************************************************************************
echo.
if not exist "%bigWimVolume%:\%backupWim%" (
    echo ERROR: No backup found at %bigWimVolume%:\%backupWim%.
    goto :mainMenu
)
if not exist X:\Windows\System32\ (
    echo ERROR: Restore can only run from WinPE - boot from the backup drive first.
    goto :mainMenu
)
wpeutil UpdateBootInfo >nul 2>&1
set "Firmware="
for /f "tokens=3" %%A in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType ^| find "PEFirmwareType"') do set "Firmware=%%A"

echo Restore modes:
echo   D = Disk restore (bare metal): ERASES the WHOLE disk, repartitions it
echo       (UEFI layout), applies the backup and makes the disk bootable.
echo   P = Partition restore: re-formats ONLY the selected partition (typically
echo       the Windows partition) and applies the backup to it. The partition
echo       layout and all other partitions stay untouched.
choice /c DPX /m "Choose D (disk), P (partition) or X (back to menu)"
if errorlevel 3 goto :mainMenu
rem In .cmd files a successful SET resets ERRORLEVEL to 0 - evaluate it first
if errorlevel 2 (set "_RESTORE_MODE=partition") else set "_RESTORE_MODE=disk"
if "%_RESTORE_MODE%"=="disk" if not "%Firmware%"=="0x2" (
    echo ERROR: The PC is booted in legacy BIOS mode - disk restore supports UEFI only.
    goto :mainMenu
)

echo.
echo Available restore points in %bigWimVolume%:\%backupWim%:
dism /Get-WimInfo /WimFile:"%bigWimVolume%:\%backupWim%"
:selectIndex
set "_SELECTED_INDEX="
set /p "_SELECTED_INDEX=Index of the backup to restore (usually the highest): "
set "_SELECTED_INDEX=%_SELECTED_INDEX:"=%"
echo %_SELECTED_INDEX%| findstr /r /c:"^[1-9][0-9]*$" >nul || (echo   Please enter a valid index number. & goto :selectIndex)
dism /Get-WimInfo /WimFile:"%bigWimVolume%:\%backupWim%" /Index:%_SELECTED_INDEX%
if errorlevel 1 (echo   Index %_SELECTED_INDEX% does not exist in the backup. & goto :selectIndex)
if "%_RESTORE_MODE%"=="partition" goto :restorePartition

rem --- Disk restore (bare metal) ----------------------------------------------
echo.
echo Disks on this system:
echo list disk | diskpart
:selectDisk
set "_DESTINATION="
set /p "_DESTINATION=Number of the disk to restore onto (X = back to menu): "
set "_DESTINATION=%_DESTINATION:"=%"
if /i "%_DESTINATION%"=="X" goto :mainMenu
echo %_DESTINATION%| findstr /r /c:"^[0-9][0-9]*$" >nul || (echo   Please enter a disk number, e.g. 0. & goto :selectDisk)
> "%TMPDIR%\_sysbackup_detail.tmp" echo select disk %_DESTINATION%
>> "%TMPDIR%\_sysbackup_detail.tmp" echo detail disk
diskpart /s "%TMPDIR%\_sysbackup_detail.tmp" > "%TMPDIR%\_sysbackup_detail.out" 2>&1
if errorlevel 1 (
    type "%TMPDIR%\_sysbackup_detail.out"
    echo   Disk %_DESTINATION% could not be selected - does it exist?
    goto :selectDisk
)
type "%TMPDIR%\_sysbackup_detail.out"
find /i " %bigWimVolume% " "%TMPDIR%\_sysbackup_detail.out" >nul 2>&1
if not errorlevel 1 (
    echo.
    echo   ERROR: Disk %_DESTINATION% contains the backup storage volume %bigWimVolume%: -
    echo          restoring onto it would destroy your backups. Choose another disk.
    echo          To restore only the Windows partition of this disk, go back to
    echo          the menu ^(X^) and use partition restore ^(P^) instead.
    goto :selectDisk
)

echo.
echo ******************************************************************************
echo   ALL DATA ON DISK %_DESTINATION% (shown above) WILL BE ERASED and replaced
echo   with %bigWimVolume%:\%backupWim% index %_SELECTED_INDEX%.
echo ******************************************************************************
choice /c YN /m "Are you really sure"
if errorlevel 2 goto :mainMenu
echo This is the last chance to abort with Ctrl+C.
pause
set "startTime=%time%"

rem --- Partition the target disk (UEFI layout) ---------------------------------
set "DPS=%TMPDIR%\_sysbackup_parts.tmp"
if exist "%~dp0CreatePartitions-UEFI.txt" (
    rem Use the custom layout, but always force the interactively selected disk
    > "%DPS%" echo select disk %_DESTINATION%
    findstr /v /r /i /c:"^ *select *disk" "%~dp0CreatePartitions-UEFI.txt" >> "%DPS%"
) else (
    > "%DPS%" (
        echo select disk %_DESTINATION%
        echo clean
        echo convert gpt
        echo create partition efi size=260
        echo format quick fs=fat32 label="System"
        echo assign letter="S"
        echo create partition msr size=16
        echo create partition primary
        echo shrink minimum=650
        echo format quick fs=ntfs label="Windows"
        echo assign letter="W"
        echo create partition primary
        echo format quick fs=ntfs label="Recovery"
        echo assign letter="R"
        echo set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
        echo gpt attributes=0x8000000000000001
        echo list volume
    )
)
echo Partitioning disk %_DESTINATION%...
diskpart /s "%DPS%"
if errorlevel 1 (echo ERROR: Partitioning disk %_DESTINATION% failed. & goto :abort)
if not exist W:\ (echo ERROR: Windows partition W: was not created by the diskpart script. & goto :abort)
if not exist S:\ (echo ERROR: System partition S: was not created by the diskpart script. & goto :abort)

echo Switching to the high-performance power scheme to speed up deployment...
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1

echo Applying %bigWimVolume%:\%backupWim% index %_SELECTED_INDEX% to W:\ ...
dism /Apply-Image /ImageFile:"%bigWimVolume%:\%backupWim%" /Index:%_SELECTED_INDEX% /ApplyDir:W:\
if errorlevel 1 (
    echo ERROR: DISM /Apply-Image failed - the disk is NOT restored and NOT bootable.
    goto :abort
)

echo Writing boot files to the System partition...
W:\Windows\System32\bcdboot W:\Windows /s S:
if errorlevel 1 (echo ERROR: bcdboot failed - the restored Windows will not boot. & goto :abort)

echo Setting Windows Boot Manager first in the UEFI boot order...
bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst
if errorlevel 1 echo WARNING: Could not change the UEFI boot order - set it in the firmware setup.

echo Hiding the recovery tools partition...
set "DPS=%TMPDIR%\_sysbackup_hide.tmp"
if exist "%~dp0HideRecoveryPartitions-UEFI.txt" (
    > "%DPS%" echo select disk %_DESTINATION%
    findstr /v /r /i /c:"^ *select *disk" "%~dp0HideRecoveryPartitions-UEFI.txt" >> "%DPS%"
) else (
    > "%DPS%" (
        echo select disk %_DESTINATION%
        echo select partition 4
        echo set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
        echo gpt attributes=0x8000000000000001
        echo remove letter="R"
    )
)
diskpart /s "%DPS%"
if errorlevel 1 echo WARNING: Hiding the recovery partition failed - not critical for booting.

echo.
echo Restore finished. Remove the backup drive and reboot into the restored Windows.
goto :end


rem ===========================================================================
rem  Partition restore - only the selected volume is re-formatted
rem ===========================================================================
:restorePartition
echo.
echo Volumes on this system:
echo list volume | diskpart
:selectTargetVolume
set "_TARGETVOL="
set "_TARGETDISK="
set /p "_TARGETVOL=Drive letter of the partition to restore (X = back to menu): "
if not defined _TARGETVOL goto :selectTargetVolume
set "_TARGETVOL=%_TARGETVOL::=%"
set "_TARGETVOL=%_TARGETVOL:"=%"
if /i "%_TARGETVOL%"=="X" goto :mainMenu
echo %_TARGETVOL%| findstr /r /i /c:"^[A-Z]$" >nul || (echo   Please enter a single drive letter, e.g. C. & goto :selectTargetVolume)
if /i "%_TARGETVOL%"=="%bigWimVolume%" (echo   %_TARGETVOL%: is the backup storage volume itself - choose another one. & goto :selectTargetVolume)
if /i "%_TARGETVOL%"=="%UFDV%" (echo   %_TARGETVOL%: is the drive this script runs from - choose another one. & goto :selectTargetVolume)
if /i "%_TARGETVOL%:"=="%~d0" (echo   %_TARGETVOL%: is the drive this script runs from - choose another one. & goto :selectTargetVolume)
if not exist "%_TARGETVOL%:\" (
    echo   Volume %_TARGETVOL%: is not accessible. If it is BitLocker-encrypted, unlock
    echo   it first, e.g.: manage-bde -unlock %_TARGETVOL%: -RecoveryPassword ^<key^>
    goto :selectTargetVolume
)
> "%TMPDIR%\_sysbackup_vol.tmp" echo select volume %_TARGETVOL%
>> "%TMPDIR%\_sysbackup_vol.tmp" echo detail volume
diskpart /s "%TMPDIR%\_sysbackup_vol.tmp" > "%TMPDIR%\_sysbackup_vol.out" 2>&1
if errorlevel 1 (
    type "%TMPDIR%\_sysbackup_vol.out"
    echo   Volume %_TARGETVOL%: could not be selected in diskpart.
    goto :selectTargetVolume
)
type "%TMPDIR%\_sysbackup_vol.out"
rem The disk holding the volume is marked with "*" in the detail output
for /f "usebackq tokens=1-3" %%a in ("%TMPDIR%\_sysbackup_vol.out") do if "%%a"=="*" if not defined _TARGETDISK set "_TARGETDISK=%%c"
if not exist "%_TARGETVOL%:\Windows\System32\" (
    echo.
    echo   WARNING: %_TARGETVOL%: does not contain a Windows installation - are you sure
    echo            this is the right partition?
    choice /c YN /m "Restore onto %_TARGETVOL%: anyway"
    if errorlevel 2 goto :selectTargetVolume
)

echo.
echo ******************************************************************************
echo   ALL DATA ON VOLUME %_TARGETVOL%: (shown above) WILL BE ERASED and replaced
echo   with %bigWimVolume%:\%backupWim% index %_SELECTED_INDEX%.
echo   The partition layout and all other partitions remain untouched.
echo ******************************************************************************
choice /c YN /m "Are you really sure"
if errorlevel 2 goto :mainMenu
echo This is the last chance to abort with Ctrl+C.
pause
set "startTime=%time%"

echo Formatting volume %_TARGETVOL%: ...
> "%TMPDIR%\_sysbackup_fmt.tmp" echo select volume %_TARGETVOL%
>> "%TMPDIR%\_sysbackup_fmt.tmp" echo format quick fs=ntfs label="Windows" override
diskpart /s "%TMPDIR%\_sysbackup_fmt.tmp"
if errorlevel 1 (echo ERROR: Formatting volume %_TARGETVOL%: failed. & goto :abort)
if not exist "%_TARGETVOL%:\" (echo ERROR: Volume %_TARGETVOL%: is not accessible after formatting. & goto :abort)

echo Switching to the high-performance power scheme to speed up deployment...
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1

echo Applying %bigWimVolume%:\%backupWim% index %_SELECTED_INDEX% to %_TARGETVOL%:\ ...
dism /Apply-Image /ImageFile:"%bigWimVolume%:\%backupWim%" /Index:%_SELECTED_INDEX% /ApplyDir:%_TARGETVOL%:\
if errorlevel 1 (
    echo ERROR: DISM /Apply-Image failed - volume %_TARGETVOL%: is NOT restored.
    goto :abort
)

call :refreshBootFiles
echo.
echo Restore finished. Remove the backup drive and reboot into the restored Windows.
goto :end


rem ===========================================================================
rem  Helpers
rem ===========================================================================
rem Re-creates the boot files of %_TARGETVOL%:\Windows on the EFI system
rem partition of disk %_TARGETDISK% (partition restore). Never aborts: the
rem existing boot entry normally still works because the partition is kept.
:refreshBootFiles
if not "%Firmware%"=="0x2" (
    echo NOTE: Legacy BIOS boot - boot files are left unchanged. If Windows does
    echo       not start, repair it with: bcdboot %_TARGETVOL%:\Windows /f BIOS
    exit /b 0
)
if not defined _TARGETDISK goto :refreshBootFilesFailed
set "_ESPPART="
> "%TMPDIR%\_sysbackup_lp.tmp" echo select disk %_TARGETDISK%
>> "%TMPDIR%\_sysbackup_lp.tmp" echo list partition
diskpart /s "%TMPDIR%\_sysbackup_lp.tmp" > "%TMPDIR%\_sysbackup_lp.out" 2>&1
for /f "usebackq tokens=1-3" %%a in ("%TMPDIR%\_sysbackup_lp.out") do if /i "%%c"=="System" if not defined _ESPPART set "_ESPPART=%%b"
if not defined _ESPPART goto :refreshBootFilesFailed
set "_ESPLETTER="
for %%L in (S T U V Q P O N M L K) do if not defined _ESPLETTER if not exist "%%L:\" set "_ESPLETTER=%%L"
if not defined _ESPLETTER goto :refreshBootFilesFailed
echo Writing boot files to the EFI system partition (disk %_TARGETDISK%, partition %_ESPPART%)...
> "%TMPDIR%\_sysbackup_esp.tmp" echo select disk %_TARGETDISK%
>> "%TMPDIR%\_sysbackup_esp.tmp" echo select partition %_ESPPART%
>> "%TMPDIR%\_sysbackup_esp.tmp" echo assign letter=%_ESPLETTER%
diskpart /s "%TMPDIR%\_sysbackup_esp.tmp" >nul 2>&1
if errorlevel 1 goto :refreshBootFilesFailed
set "_BCDRC=0"
"%_TARGETVOL%:\Windows\System32\bcdboot" %_TARGETVOL%:\Windows /s %_ESPLETTER%: /f UEFI || set "_BCDRC=1"
> "%TMPDIR%\_sysbackup_esp.tmp" echo select disk %_TARGETDISK%
>> "%TMPDIR%\_sysbackup_esp.tmp" echo select partition %_ESPPART%
>> "%TMPDIR%\_sysbackup_esp.tmp" echo remove letter=%_ESPLETTER%
diskpart /s "%TMPDIR%\_sysbackup_esp.tmp" >nul 2>&1
if "%_BCDRC%"=="1" goto :refreshBootFilesFailed
exit /b 0
:refreshBootFilesFailed
echo WARNING: The boot files could not be refreshed automatically. The existing
echo          boot entry usually still works. If Windows does not start, assign a
echo          letter to the EFI system partition (e.g. S:) and run:
echo            bcdboot %_TARGETVOL%:\Windows /s S: /f UEFI
exit /b 0

rem Sets TS=yyyy-MM-dd_HH-mm, locale independent where possible
:makeTimestamp
set "TS="
set "LDT="
for /f "tokens=2 delims==" %%T in ('wmic os get localdatetime /value 2^>nul ^| find "LocalDateTime"') do set "LDT=%%T"
if defined LDT set "TS=%LDT:~0,4%-%LDT:~4,2%-%LDT:~6,2%_%LDT:~8,2%-%LDT:~10,2%"
if defined TS exit /b 0
for /f "delims=" %%T in ('powershell -NoProfile -NonInteractive -Command "Get-Date -Format yyyy-MM-dd_HH-mm" 2^>nul') do set "TS=%%T"
if defined TS exit /b 0
rem Last resort: locale dependent, sanitized for use in file names
set "TS=%DATE%_%TIME:~0,5%"
set "TS=%TS:/=-%"
set "TS=%TS:.=-%"
set "TS=%TS::=-%"
set "TS=%TS: =%"
exit /b 0


rem ===========================================================================
rem  Help
rem ===========================================================================
:help
echo.
echo Using the Backup and Restore script
echo ===================================
echo.
echo BACKUP  (B)
echo   1. Boot the PC from the WinPE backup drive (e.g. press F12 for the
echo      one-time boot menu and select the USB drive in UEFI mode).
echo   2. Choose B, then enter the drive letter of the volume to back up -
echo      typically the large Windows partition.
echo   3. Optionally add a description; date and time are stored automatically
echo      with every index.
echo   4. Review the generated DISM configuration file. OneDrive and WSL folders
echo      are excluded automatically; check for hidden OneDriveCloudTemp folders
echo      (dir /a) and additional WSL packages and add them if needed.
echo   5. The first run creates %backupWim%, later runs append a new index.
echo      An index overview is written next to the WIM file after every run.
echo   6. Verify the backup, ideally with a test restore on a similar PC, or at
echo      least by mounting the WIM with dism /Mount-Image.
echo.
echo RESTORE  (R)  -  WinPE only
echo   1. Boot from the WinPE backup drive and choose R.
echo   2. Choose the restore mode:
echo      D = disk restore (bare metal, UEFI only) - ERASES the whole disk
echo      P = partition restore - re-formats only the selected partition, e.g.
echo          when Windows is broken but the disk/partitions are still fine
echo   3. Select the index (restore point) to apply - usually the highest one.
echo   4. D: Select the target disk number carefully - all data on it is erased.
echo         The script shows the disk details first and refuses disks that
echo         contain the backup storage volume. The disk is repartitioned
echo         (UEFI layout), the image is applied and the disk made bootable.
echo      P: Select the drive letter of the partition to restore (in WinPE it
echo         is often not C:). It is formatted, the image is applied and the
echo         boot files on the EFI system partition of that disk are refreshed.
echo.
echo See README.md in this folder for the full documentation.
echo.
goto :mainMenu


rem ===========================================================================
rem  Exit paths
rem ===========================================================================
:quit
set "RC=0"
goto :cleanup

:abort
echo.
echo ******************************************************************************
echo   ABORTED - the operation did NOT complete. Check the messages above.
echo ******************************************************************************
set "RC=1"
goto :cleanup

:end
set "RC=0"
echo.
echo ******************************************************************************
echo   %APP_NAME% worked for you from %startTime:~0,-3% to %time:~0,-3%
echo   Please verify the output above, especially that DISM (Deployment Image
echo   Servicing and Management tool) completed successfully.
echo ******************************************************************************
goto :cleanup

:cleanup
del /q "%TMPDIR%\_sysbackup_*" 2>nul
exit /b %RC%
