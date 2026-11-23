@echo off
rem
rem This script creates and restores indexed Windows backups from an volume containing bigWimVolume.txt
rem Note the restore option will only work for Windows versions to be booted in UEFI mode
rem

echo.
echo ******************************************************************************
echo.        Welcome to the Windows Backup and Restore Script
echo.        Note: The restore is only intended for UEFI-boot
echo ******************************************************************************
echo.

rem Find the volume for the big WIM-file
for %%V in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %%V:\bigWimVolume.txt set bigWimVolume=%%V
if not exist %bigWimVolume%:\bigWimVolume.txt echo %bigWimVolume%:\bigWimVolume.txt, which specifies the storage location for the backup, not found, aborting. && goto :abort
set backupWim=backup.wim


rem The very first is to choose, if a backup shall be created or restored 
:firstquestion
choice /c BRQH /m "Choose B for creating a backup, R for restore, Q for quit or H for help"
if errorlevel 4 goto :help
if errorlevel 3 goto :abort
if errorlevel 2 goto :restore
if errorlevel 1 goto :create


rem Here comes the create-backup-part, which can also append an existing WIM-file
:create
echo.
echo ******************************************************************************
echo.        Backup selected
echo ******************************************************************************
echo.
rem Create Time-Stamp-String
For /f "tokens=1-2 delims=/:" %%a in ("%TIME%") do (set mytime=%%a:%%b)
set _my_date=%DATE%
set _my_date=%_my_date:~-10%
set _delim=%_my_date:~2,1%
if "%_delim%"=="." (
    rem German date format
    for /f "tokens=1,2,3 delims=." %%a in ('echo %_my_date%') do set mydate=%%b-%%a-%%c
) else (
    rem English date format
    for /f "tokens=1,2,3 delims=/" %%a in ('echo %_my_date%') do set mydate=%%a-%%b-%%c
)
rem Select image partition to capture
echo list volume > _CAPTURE.TMP
echo exit >> _CAPTURE.TMP
diskpart < _CAPTURE.TMP
del _CAPTURE.TMP
:selectVolumeToBackup
set /p volumeToBackup="Enter the volume-letter which should be captured as backup (Typically the Windows Installation): "
if errorlevel 1 goto :selectVolumeToBackup
set /p BackupNotes="Here you can add a description of the backup or just hit enter: "
set action=append-image
if not exist %bigWimVolume%:\%backupWim% set action=capture-image /compress:max
set my_description=Backup from %mydate% at %mytime% %BackupNotes%
echo Now we have to exclude OneDrive and WSL things, as those can make serious problems for the backup.
type nul > OneDriveFolders.txt
type nul > LinuxSubsystems.txt
setlocal EnableDelayedExpansion
  for /d %%u in (%volumeToBackup%:\Users\*.*) do (
    set Y=%%u
    echo !Y:~2!\OneDriv*                                        >> OneDriveFolders.txt
    echo !Y:~2!\AppData\Local\Packages\CanonicalGroupLimited*   >> LinuxSubsystems.txt      )
setlocal DisableDelayedExpansion
echo This will be excluded from the backup with following configfile %UFDV%:\scripts\backup.ini for DISM:
type %UFDV%:\scripts\ExclusionList.ini > %UFDV%:\scripts\backup.ini
type OneDriveFolders.txt >> %UFDV%:\scripts\backup.ini
type LinuxSubsystems.txt >> %UFDV%:\scripts\backup.ini
echo. >> %UFDV%:\scripts\backup.ini
del OneDriveFolders.txt
del LinuxSubsystems.txt
type %UFDV%:\scripts\CompressionExclusionList.ini >> %UFDV%:\scripts\backup.ini
type %UFDV%:\scripts\backup.ini
echo Creating backup (%action%) into %bigWimVolume%:\%backupWim% from the volume with the letter %volumeToBackup%
echo With description: "%my_description%"
echo Deployment Image Servicing and Management tool will use above configfile %UFDV%:\scripts\backup.ini
echo Command-line: dism /%action% /imagefile:%bigWimVolume%:\%backupWim% /capturedir:%volumeToBackup%: /name:"Backup %mydate% %mytime%" /description:"%my_description%" /configFile:%UFDV%:\scripts\backup.ini
choice /c YN /m "You are OK with above configfile and you do not want to edit %UFDV%:\scripts\backup.ini by your own?"
if errorlevel 2 notepad %UFDV%:\scripts\backup.ini
choice /c YN /m "Are you really sure to create now the backup?"
if errorlevel 2 goto :firstquestion
set startTime=%time%
dism /%action% /imagefile:%bigWimVolume%:\%backupWim% /capturedir:%volumeToBackup%: /name:"Backup %mydate% %mytime%" /description:"%my_description%" /configFile:%UFDV%:\scripts\backup.ini
echo Writing detailed info about all backups in %bigWimVolume%:\%backupWim% to %bigWimVolume%:\%backupWim:~0,-4%.txt
dism /get-wiminfo /wimfile:%bigWimVolume%:\%backupWim% > %bigWimVolume%:\%backupWim:~0,-4%.txt
move /y %UFDV%:\scripts\backup.ini %bigWimVolume%:
goto :end


rem Here comes the restore-backup-part
:restore
echo.
echo ******************************************************************************
echo.        Restore selected - Attention this may delete all your data!
echo ******************************************************************************
echo.
rem First set _DESTINATION to NOTSET inorder to avoid serious data-loss due to an possibly wrong preset
set _DESTINATION=NOTSET
echo Lets look into your %bigWimVolume%:\%backupWim% for available restore-points:
pause
dism /get-wiminfo /wimfile:%bigWimVolume%:\%backupWim%
set /p _SELECTED_INDEX="Choose an index, for specifying the backup to be used: "
echo. && echo Now its time to choose the Disk to restore...
if "%_DESTINATION%" == "" goto :select_disk
if "%_DESTINATION%" == "NOTSET" goto :select_disk
echo Attention - Using preset deployment destination - %_DESTINATION%
goto :last_check_before_restore
:select_disk
diskpart /s %DEPLOYTOOLS%\ListDisk.txt
set /p _DESTINATION="Disk to restore not set, please choose disk-number or answer with 'X' if you want to abort: "
set _DESTINATION=Disk %_DESTINATION%
if not x"%_DESTINATION:x=%" == x"%_DESTINATION%" goto :abort
if x"%_DESTINATION:dis=%" == x"%_DESTINATION%" goto :select_disk
:last_check_before_restore
echo.
choice /c YN /m "Restore %_DESTINATION% with %bigWimVolume%:\%backupWim% index %_SELECTED_INDEX%, are you really sure?"
if errorlevel 2 goto :firstquestion
echo.
echo All data on %_DESTINATION% will be deleted soon!
echo Here is the last chance to exit with Ctrl+C
echo.
pause
set startTime=%time%
if not exist X:\Windows\System32 echo ERROR: This script is built to run only in WindowsPE.
if not exist X:\Windows\System32 goto :abort
echo Checking if the PC has booted in UEFI mode...
wpeutil UpdateBootInfo
for /f "tokens=2* delims=	 " %%A in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType') DO SET Firmware=%%B
if %Firmware%==0x2 echo OK, the PC is booted in UEFI mode.
if %Firmware%==0x1 echo The PC is booted in BIOS mode! && goto :abort
diskpart /s %~dp0CreatePartitions-UEFI.txt
echo Set high-performance power scheme to speed up deployment...
call powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
echo Applying %bigWimVolume%:\%backupWim% index %_SELECTED_INDEX% to W:\ on %_DESTINATION%...
echo Command-line: dism /Apply-Image /ImageFile:%bigWimVolume%:\%backupWim% /Index:%_SELECTED_INDEX% /ApplyDir:W:\
dism /Apply-Image /ImageFile:%bigWimVolume%:\%backupWim% /Index:%_SELECTED_INDEX% /ApplyDir:W:\
echo Copy boot files to the System partition...
W:\Windows\System32\bcdboot W:\Windows /s S:
echo Seting this Windows Boot Manager as first item in the UEFI boot order...
bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst
echo Hiding the recovery tools partition...
diskpart /s %~dp0HideRecoveryPartitions-UEFI.txt
goto :end


:help
echo.
echo Using the Backup and Restore script
echo ===================================
echo.
echo 1. Backup
echo ---------
echo.
echo a) Plug the backup drive (currently Samsung Portable SSD T7 (USB-C with internal NVMe)) into a USB port on your PC. 
echo    (Preferably to a USB-3 SuperSpeed, but not to a USB-C, even if it would be even faster. Tests with a DELL 
echo    Precission 3660 workstation have shown that this then leads to I/O problems under WinPE with the DISM).
echo b) Turn on the PC, press F12-key several times until the "One-Time-Boot-Menu" appears. Select "UEFI Samsung PSSD T7
echo    Option" and boot from it.
echo c) The backup and restore script should start automatically, if not, enter "backup". For advanced options, the 
echo    script can also be terminated immediately and further CMD windows can be opened with "cmdus”, "cmdde" or "start", 
echo    with which you can then do further things during the backup or intervene if problems occur. Otherwise, simply 
echo    continue with "b". The letter of the drive to be backed up must then be entered. This is typically the large 
echo    Windows partition. You can then enter a comment about the backup that may be helpful when restoring. It is not 
echo    necessary to enter a date here, as every index in the WIM backup receives this information anyway. Last but not 
echo    least, the backup.ini can be edited, which is then used as the DISM configuration file. This is where it really 
echo    gets down to business. OneDrive and the subsystem for Linux are the things that cause the most problems here. So 
echo    if OneDrive folders have already been found, it is worth checking whether hidden OneDriveCloudTemp folders exist 
echo    alongside them. To do this, look in the corresponding path with dir /a. The critical files of the WSL (Windows 
echo    Subsystem for Liunx) are typically located in a path such as: 
echo    c:\Users\Joe\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_79rhkp. These folders should also be included 
echo    in the [ExclusionList].
echo d) After a successful backup, this should be tested on another, similar PC using the restore function. Alternatively, 
echo    you can also first mount the WIM backup with DISM, as this can also be used to detect any problems. However, only 
echo    a genuinely successful restore attempt can provide certainty.
echo.
echo 2. Restore
echo ----------
echo.
echo a) Plug the backup drive into a USB port of your PC and boot from it (for details see 1. Backup point a) and b))
echo b) The restore part is selected with an "r". Then look into the backup.wim, where various indexes may be displayed. 
echo    Each of these indexes hopefully represents a complete backup at the respective point in time, with a comment. 
echo    Select the appropriate one here. Typically the last one, the index with the highest number.
echo c) Finally, the corresponding mass storage device to which the backup will be unpacked must be selected. This is 
echo    typically the built-in hard disk or SSD. You can use the size as a guide. Attention: the backup drive is almost 
echo    2 terabytes in size. Selecting this would be fatal in an emergency. So extreme caution is required here. At the end
echo    there are a few more keystrokes to be on the safe side, whereby you can still cancel with Ctrl+C in the event 
echo    of an error. Then the corresponding drive is set up for the UEFI boot according to Windows 10 specifications, 
echo    partitioned and provided with the backup. Finally, it is made bootable. The script should then finish properly, with 
echo    the information from when to when it worked.
echo.
echo 3. Further Details and Troubleshooting
echo --------------------------------------
echo.
echo Find this information in http://elog.aug.emrsn.org:8080/Windows/560
echo.
goto :firstquestion



:abort
set startTime=%time%


:end
echo.
echo ******************************************************************************
echo Backup and Restore Script worked for you from %startTime:~0,-3% to %time:~0,-3%
echo Please verify above output, especially if DISM (Deployment Image Servicing and
echo Management tool) finished completely and successfully. 
echo ******************************************************************************
echo.