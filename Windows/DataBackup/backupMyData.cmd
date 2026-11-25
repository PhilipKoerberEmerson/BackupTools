@echo off
:: ===========================================================================
::  backupMyData.cmd - configurable data backup for Windows 10 / 11
::  Modes   : TIMESTAMP (robocopy full copy per run) or WIM (incremental DISM)
::  Schedule: Windows Task Scheduler (daily / weekly / logon / startup)
::  Help    : backupMyData.cmd /?
::  PhK 2026-11-19
:: ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "APP_NAME=BackupMyData"
set "APP_VERSION=1.0.0"
set "TASK_NAME=BackupMyData"
set "SCRIPT=%~f0"
set "SELF=%~nx0"
set "CFG=%~dpn0.ini"
set "ACTION="

:parseArgs
if "%~1"=="" goto :argsDone
set "ARG=%~1"
if "!ARG:~0,2!"=="--" set "ARG=/!ARG:~2!"
if "!ARG:~0,1!"=="-" set "ARG=/!ARG:~1!"
if "!ARG!"=="/?" goto :help
if /i "!ARG!"=="/h"         goto :help
if /i "!ARG!"=="/help"      goto :help
if /i "!ARG!"=="/run"       (set "ACTION=doBackup"   & shift & goto :parseArgs)
if /i "!ARG!"=="/setup"     (set "ACTION=setup"      & shift & goto :parseArgs)
if /i "!ARG!"=="/install"   (set "ACTION=installTask"& shift & goto :parseArgs)
if /i "!ARG!"=="/uninstall" (set "ACTION=removeTask" & shift & goto :parseArgs)
if /i "!ARG!"=="/status"    (set "ACTION=showStatus" & shift & goto :parseArgs)
if /i "!ARG!"=="/cfg" (
    if "%~2"=="" (echo ERROR: /cfg requires a file path. & exit /b 2)
    set "CFG=%~f2"
    shift & shift & goto :parseArgs
)
echo ERROR: Unknown argument "%~1". Use "%SELF% /?" for help.
exit /b 2

:argsDone
if not defined ACTION goto :menu
call :%ACTION%
exit /b !errorlevel!


:: ===========================================================================
::  Interactive menu
:: ===========================================================================
:menu
title %APP_NAME% v%APP_VERSION%
cls
call :banner
if not exist "!CFG!" (
    echo No configuration found: !CFG!
    choice /c YN /m "Create a configuration now"
    if not errorlevel 2 (call :setup & pause)
    cls
    call :banner
)
echo   [1] Run backup now
echo   [2] Configure backup (sources, target, mode, schedule)
echo   [3] Install / update automatic backup schedule
echo   [4] Remove automatic backup schedule
echo   [5] Show configuration and status
echo   [H] Help
echo   [Q] Quit
echo(
choice /c 12345HQ /n /m "Select option: "
set "SEL=!errorlevel!"
echo(
if "!SEL!"=="1" (call :doBackup    & pause)
if "!SEL!"=="2" (call :setup       & pause)
if "!SEL!"=="3" (call :installTask & pause)
if "!SEL!"=="4" (call :removeTask  & pause)
if "!SEL!"=="5" (call :showStatus  & pause)
if "!SEL!"=="6" (call :helpText    & pause)
if "!SEL!"=="7" exit /b 0
goto :menu


:: ===========================================================================
::  Help
:: ===========================================================================
:help
call :helpText
exit /b 0

:helpText
call :banner
echo USAGE
echo   %SELF%                 Interactive menu
echo   %SELF% /run            Run the backup unattended (used by the scheduled task)
echo   %SELF% /setup          Configure sources, target and mode, then optionally
echo                                   install the automatic backup schedule
echo   %SELF% /install        Install or update the automatic backup schedule (admin)
echo   %SELF% /uninstall      Remove the automatic backup schedule (admin)
echo   %SELF% /status         Show configuration and schedule status
echo   %SELF% /? ^| /h ^| -h    Show this help
echo(
echo OPTIONS
echo   /cfg ^<file^>   Use another configuration file.
echo                 Default: %~dpn0.ini
echo   All options accept "/" or "-" as prefix, e.g. -run
echo(
echo BACKUP MODES
echo   TIMESTAMP  Every run creates ^<TARGET^>\yyyy-MM-dd_HH-mm-ss\^<SourceName^> with a
echo              full copy (robocopy). Browsable with Explorer, needs full space per run.
echo   WIM        Every source is kept in ^<TARGET^>\^<SourceName^>.wim. The first run
echo              captures an image, later runs append a new image (DISM). Unchanged
echo              files are stored only once, so each version only costs the changes.
echo              Requires administrator rights. Open/locked files make DISM fail,
echo              so close applications that use the source data.
echo(
echo RESTORE
echo   Easiest and safest: restoreMyData.cmd - interactive wizard for both modes.
echo   Manually in WIM mode, elevated console:
echo   List versions : dism /Get-ImageInfo /ImageFile:"E:\Backup\Documents.wim"
echo   Restore       : dism /Apply-Image /ImageFile:"E:\Backup\Documents.wim" /Index:3 /ApplyDir:"C:\Restore"
echo   Browse        : dism /Mount-Image /ImageFile:"E:\Backup\Documents.wim" /Index:3 /MountDir:"C:\Mnt" /ReadOnly
echo                   dism /Unmount-Image /MountDir:"C:\Mnt" /Discard
echo   7-Zip can open .wim files directly as well.
echo(
echo AUTOMATIC BACKUP
echo   Installed as Task Scheduler task "%TASK_NAME%" - the supported way on Windows 10/11
echo   to run a script unattended (a .cmd file cannot be a native Windows service).
echo   Schedules: daily, weekly, at user logon or at system startup. The task runs with
echo   highest privileges, catches up missed runs and also runs on battery power.
echo   Run as SYSTEM for local/USB targets, or as your user for network share targets.
echo   Manage with: taskschd.msc   or   schtasks /Run /TN "%TASK_NAME%"
echo(
echo CONFIGURATION FILE (created by /setup, may be edited manually, no spaces around "=")
echo   ; comment
echo   TARGET=E:\Backup
echo   MODE=TIMESTAMP              TIMESTAMP or WIM
echo   WIM_COMPRESS=max            none, fast or max (WIM mode only)
echo   SOURCE=C:\Users\me\Documents
echo   SOURCE=D:\Projects          repeat SOURCE= for every folder
echo   Log files are written to ^<TARGET^>\_logs. Paths containing "^!" are not supported.
echo(
echo EXIT CODES
echo   0 = success   1 = completed with warnings   2 = error
exit /b 0

:banner
echo ===============================================================================
echo  %APP_NAME% v%APP_VERSION%  -  Data backup for Windows 10 / 11
echo ===============================================================================
echo(
exit /b 0


:: ===========================================================================
::  Setup / configuration
:: ===========================================================================
:setup
call :configure || exit /b 2
echo(
choice /c YN /m "Install an automatic backup schedule (daily/weekly/logon/startup)"
if errorlevel 2 (echo No schedule installed. Use "%SELF% /install" later if needed. & exit /b 0)
call :installTask
exit /b !errorlevel!

:configure
call :loadConfig
echo === Backup configuration ===
echo Configuration file: !CFG!
echo(
if !SRC_COUNT! GTR 0 (
    echo Current source folders:
    for /l %%I in (1,1,!SRC_COUNT!) do echo    [%%I] !SRC_%%I!
    choice /c YN /m "Keep these source folders"
    if errorlevel 2 set "SRC_COUNT=0"
)
echo(
echo Enter the folders to back up, one per line. Empty line = done.
:cfgSrcLoop
set "IN="
set /p "IN=  Source folder: "
if not defined IN goto :cfgSrcDone
call :normPath IN
if not exist "!IN!\" (
    echo   WARNING: Folder does not exist: !IN!
    choice /c YN /m "  Add anyway"
    if errorlevel 2 goto :cfgSrcLoop
)
set /a SRC_COUNT+=1
set "SRC_!SRC_COUNT!=!IN!"
goto :cfgSrcLoop
:cfgSrcDone
if !SRC_COUNT! LSS 1 (echo   At least one source folder is required. & goto :cfgSrcLoop)

echo(
:cfgTarget
set "IN="
if defined TARGET (set /p "IN=Backup target folder [!TARGET!]: ") else (set /p "IN=Backup target folder: ")
if defined IN (call :normPath IN & set "TARGET=!IN!")
if not defined TARGET goto :cfgTarget
if not exist "!TARGET!\" (
    choice /c YN /m "Target folder does not exist. Create it now"
    if not errorlevel 2 (mkdir "!TARGET!" || goto :cfgTarget)
)

echo(
echo Backup mode:
echo   [1] TIMESTAMP - new folder with a full copy for every backup (robocopy)
echo   [2] WIM       - incremental versions, one WIM file per source (DISM, admin)
choice /c 12 /n /m "Select mode [1/2]: "
if errorlevel 2 (set "MODE=WIM") else (set "MODE=TIMESTAMP")
if /i not "!MODE!"=="WIM" goto :cfgSave
echo(
echo WIM compression: [1] max (smallest)  [2] fast  [3] none
choice /c 123 /n /m "Select compression [1/2/3]: "
if errorlevel 3 (set "WIM_COMPRESS=none") else if errorlevel 2 (set "WIM_COMPRESS=fast") else (set "WIM_COMPRESS=max")
call :isAdmin || echo NOTE: WIM mode needs administrator rights - run elevated or use the scheduled task.

:cfgSave
call :saveConfig || exit /b 1
echo(
echo Configuration saved to !CFG!
exit /b 0

:loadConfig
set "TARGET="
set "MODE=TIMESTAMP"
set "WIM_COMPRESS=max"
set "SRC_COUNT=0"
if not exist "!CFG!" exit /b 1
for /f "usebackq eol=; tokens=1,* delims==" %%A in ("!CFG!") do (
    if /i "%%A"=="SOURCE" if not "%%B"=="" (
        set /a SRC_COUNT+=1
        set "SRC_!SRC_COUNT!=%%B"
    )
    if /i "%%A"=="TARGET"       set "TARGET=%%B"
    if /i "%%A"=="MODE"         set "MODE=%%B"
    if /i "%%A"=="WIM_COMPRESS" set "WIM_COMPRESS=%%B"
)
exit /b 0

:saveConfig
(
    echo(; %APP_NAME% configuration - written !date! !time!
    echo(; MODE = TIMESTAMP or WIM, WIM_COMPRESS = none, fast or max
    echo(; Add one SOURCE= line per folder to back up.
    echo(TARGET=!TARGET!
    echo(MODE=!MODE!
    echo(WIM_COMPRESS=!WIM_COMPRESS!
    for /l %%I in (1,1,!SRC_COUNT!) do echo(SOURCE=!SRC_%%I!
) > "!CFG!" 2>nul || (echo ERROR: Cannot write "!CFG!". & exit /b 1)
exit /b 0

:validateConfig
set "VERR=0"
if !SRC_COUNT! LSS 1 (echo ERROR: No SOURCE folder configured in "!CFG!". & set "VERR=1")
if not defined TARGET (echo ERROR: No TARGET configured in "!CFG!". & set "VERR=1")
if /i not "!MODE!"=="TIMESTAMP" if /i not "!MODE!"=="WIM" (echo ERROR: Invalid MODE "!MODE!" - use TIMESTAMP or WIM. & set "VERR=1")
set "OKC=0"
for %%C in (none fast max) do if /i "!WIM_COMPRESS!"=="%%C" set "OKC=1"
if "!OKC!"=="0" (echo ERROR: Invalid WIM_COMPRESS "!WIM_COMPRESS!" - use none, fast or max. & set "VERR=1")
exit /b !VERR!

:: Normalise the path stored in variable %1: no quotes, absolute, no trailing "\" (except drive roots)
:normPath
set "NP=!%~1!"
set "NP=!NP:"=!"
if "!NP:~-1!"==":" set "NP=!NP!\"
for %%P in ("!NP!") do set "NP=%%~fP"
:normPathTrim
if "!NP:~-1!"=="\" if not "!NP:~-2!"==":\" (set "NP=!NP:~0,-1!" & goto :normPathTrim)
set "%~1=!NP!"
exit /b 0


:: ===========================================================================
::  Backup
:: ===========================================================================
:doBackup
set "LOG="
call :loadConfig
if errorlevel 1 (echo ERROR: Configuration not found: "!CFG!". Run "%SELF% /setup" first. & exit /b 2)
call :validateConfig || exit /b 2
call :timestamp || exit /b 2

set "TB=!TARGET!"
if "!TB:~-1!"=="\" set "TB=!TB:~0,-1!"
if not exist "!TB!\" mkdir "!TB!" 2>nul
if not exist "!TB!\" (echo ERROR: Backup target not reachable: !TARGET! & exit /b 2)
set "LOG_DIR=!TB!\_logs"
if not exist "!LOG_DIR!\" mkdir "!LOG_DIR!" 2>nul
set "LOG=!LOG_DIR!\backup_!TS!.log"

set "WARN=0"
set "ERR=0"
set "USED=/"
call :log "===== %APP_NAME% v%APP_VERSION% - backup started ====="
call :log "Computer: !COMPUTERNAME!  User: !USERNAME!  Mode: !MODE!  Target: !TARGET!"
if /i "!MODE!"=="WIM" (call :backupWim) else (call :backupTimestamp)

set "RC=0"
if !WARN! GTR 0 set "RC=1"
if !ERR!  GTR 0 set "RC=2"
call :log "===== Backup finished: !ERR! error(s), !WARN! warning(s), exit code !RC! ====="
echo Log file: !LOG!
exit /b !RC!

:backupTimestamp
set "DEST_ROOT=!TB!\!TS!"
mkdir "!DEST_ROOT!" 2>nul
if not exist "!DEST_ROOT!\" (call :log "ERROR: Cannot create !DEST_ROOT!" & set /a ERR+=1 & exit /b 2)
set "ROBO_OPT=/E /COPY:DAT /DCOPY:T /R:2 /W:5 /XJ /MT:8 /NP /NFL /NDL"
:: Backup mode (/B) reads files regardless of ACLs, only possible when elevated
call :isAdmin && set "ROBO_OPT=!ROBO_OPT! /B"
set "I=0"
:tsLoop
set /a I+=1
if !I! GTR !SRC_COUNT! exit /b 0
set "SRC=!SRC_%I%!"
if not exist "!SRC!\" (
    call :log "WARNING: Source not found, skipped: !SRC!"
    set /a WARN+=1
    goto :tsLoop
)
call :makeName "!SRC!"
set "DST=!DEST_ROOT!\!SNAME!"
:: robocopy would read "D:\" as an escaped quote, so drive roots get a doubled backslash
set "SRC_ARG=!SRC!"
if "!SRC_ARG:~-1!"=="\" set "SRC_ARG=!SRC_ARG!\"
call :log "Copying [!SRC!] to [!DST!]"
robocopy "!SRC_ARG!" "!DST!" !ROBO_OPT! /XD "!TB!" "$RECYCLE.BIN" "System Volume Information" /TEE /LOG+:"!LOG!"
set "RC=!errorlevel!"
if !RC! GEQ 8 (
    call :log "ERROR: robocopy failed for [!SRC!] with exit code !RC!"
    set /a ERR+=1
) else if !RC! GEQ 4 (
    call :log "WARNING: robocopy reported mismatches for [!SRC!], exit code !RC!"
    set /a WARN+=1
) else (
    call :log "OK: [!SRC!] robocopy exit code !RC!"
)
goto :tsLoop

:backupWim
call :isAdmin || (call :log "ERROR: WIM mode requires administrator rights. Run elevated or via the scheduled task." & set /a ERR+=1 & exit /b 2)
set "DISM_LOG=!LOG_DIR!\dism_!TS!.log"
set "I=0"
:wimLoop
set /a I+=1
if !I! GTR !SRC_COUNT! exit /b 0
set "SRC=!SRC_%I%!"
if not exist "!SRC!\" (
    call :log "WARNING: Source not found, skipped: !SRC!"
    set /a WARN+=1
    goto :wimLoop
)
call :makeName "!SRC!"
set "WIM=!TB!\!SNAME!.wim"
set "IMG_NAME=!SNAME! !TS!"
:: Drive roots ("D:\") must be passed unquoted, see robocopy note above
if "!SRC:~-1!"=="\" (set "CAPDIR=!SRC!") else (set CAPDIR="!SRC!")
if exist "!WIM!" (
    call :log "Appending image [!IMG_NAME!] to [!WIM!]"
    dism /English /Append-Image /ImageFile:"!WIM!" /CaptureDir:!CAPDIR! /Name:"!IMG_NAME!" /Description:"!SRC! on !COMPUTERNAME!" /CheckIntegrity /LogPath:"!DISM_LOG!"
) else (
    call :log "Creating [!WIM!] with image [!IMG_NAME!], compression !WIM_COMPRESS!"
    dism /English /Capture-Image /ImageFile:"!WIM!" /CaptureDir:!CAPDIR! /Name:"!IMG_NAME!" /Description:"!SRC! on !COMPUTERNAME!" /Compress:!WIM_COMPRESS! /CheckIntegrity /LogPath:"!DISM_LOG!"
)
set "RC=!errorlevel!"
if !RC! NEQ 0 (
    call :log "ERROR: DISM failed for [!SRC!] with exit code !RC! - see !DISM_LOG!"
    set /a ERR+=1
) else (
    call :log "OK: [!SRC!] stored as image [!IMG_NAME!]"
)
goto :wimLoop

:: Derive a unique folder/file name (SNAME) for source %1 within this run
:makeName
set "SNAME=%~nx1"
if not defined SNAME (set "P=%~1" & set "SNAME=Drive_!P:~0,1!")
set "BASE=!SNAME!"
set "N=1"
:makeNameLoop
if not "!USED:/%SNAME%/=!"=="!USED!" (set /a N+=1 & set "SNAME=!BASE!_!N!" & goto :makeNameLoop)
set "USED=!USED!!SNAME!/"
exit /b 0

:timestamp
set "TS="
for /f "delims=" %%T in ('powershell -NoProfile -NonInteractive -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "TS=%%T"
if not defined TS (echo ERROR: Could not determine timestamp via PowerShell. & exit /b 1)
exit /b 0

:log
set "LMSG=%~1"
echo [%date% %time:~0,8%] !LMSG!
if defined LOG (>>"!LOG!" echo [%date% %time:~0,8%] !LMSG!)
exit /b 0

:isAdmin
fltmc >nul 2>&1
exit /b %errorlevel%


:: ===========================================================================
::  Scheduled task
:: ===========================================================================
:installTask
call :isAdmin || (echo ERROR: Installing the schedule requires administrator rights. & echo Right-click the console or script and choose "Run as administrator". & exit /b 2)
call :loadConfig
call :validateConfig || (echo Please configure the backup first: %SELF% /setup & exit /b 2)
echo === Automatic backup schedule ===
echo   [1] Daily at a fixed time
echo   [2] Weekly on a given day at a fixed time
echo   [3] At every user logon
echo   [4] At system startup (5 minutes delay)
echo   [C] Cancel
choice /c 1234C /n /m "Select schedule: "
set "SEL=!errorlevel!"
if "!SEL!"=="5" (echo Cancelled. & exit /b 0)
if "!SEL!"=="1" (call :askTime & set "SCHED=/SC DAILY /ST !ST!")
if "!SEL!"=="2" (call :askDay & call :askTime & set "SCHED=/SC WEEKLY /D !DAY! /ST !ST!")
if "!SEL!"=="3" set "SCHED=/SC ONLOGON"
if "!SEL!"=="4" set "SCHED=/SC ONSTART /DELAY 0005:00"

echo(
echo Run the backup as:
echo   [1] SYSTEM - no password, recommended for local and USB disks
echo   [2] !USERDOMAIN!\!USERNAME! - required for network share targets, password is asked
choice /c 12 /n /m "Select account [1/2]: "
if errorlevel 2 (set RUNAS=/RU "!USERDOMAIN!\!USERNAME!") else (set "RUNAS=/RU SYSTEM")

set "TR=\"!SCRIPT!\" /run /cfg \"!CFG!\""
schtasks /Create /TN "!TASK_NAME!" /TR "!TR!" !SCHED! !RUNAS! /RL HIGHEST /F
if errorlevel 1 (echo ERROR: Creating the scheduled task failed. & exit /b 2)

:: schtasks.exe cannot set these; defaults would skip backups on battery and missed runs
powershell -NoProfile -NonInteractive -Command "$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 12); Set-ScheduledTask -TaskName '%TASK_NAME%' -Settings $s | Out-Null" >nul 2>&1
if errorlevel 1 echo NOTE: Could not set battery/catch-up options. Adjust them in taskschd.msc if needed.
echo(
schtasks /Query /TN "!TASK_NAME!" /FO LIST
echo Scheduled task "!TASK_NAME!" installed.
exit /b 0

:askTime
set "ST="
set /p "ST=Start time HH:MM, 24h [20:00]: "
if not defined ST set "ST=20:00"
echo !ST!| findstr /r /c:"^[01][0-9]:[0-5][0-9]$" /c:"^2[0-3]:[0-5][0-9]$" >nul || (echo Invalid time, use e.g. 07:30 or 20:00. & goto :askTime)
exit /b 0

:askDay
echo Day: [1] Mon  [2] Tue  [3] Wed  [4] Thu  [5] Fri  [6] Sat  [7] Sun
choice /c 1234567 /n /m "Select day: "
for /f "tokens=%errorlevel%" %%D in ("MON TUE WED THU FRI SAT SUN") do set "DAY=%%D"
exit /b 0

:removeTask
schtasks /Query /TN "!TASK_NAME!" >nul 2>&1 || (echo No scheduled task "!TASK_NAME!" installed. & exit /b 0)
call :isAdmin || (echo ERROR: Removing the schedule requires administrator rights. & exit /b 2)
schtasks /Delete /TN "!TASK_NAME!" /F || exit /b 2
exit /b 0


:: ===========================================================================
::  Status
:: ===========================================================================
:showStatus
echo Configuration file : !CFG!
call :loadConfig
if errorlevel 1 (echo   not found - run "%SELF% /setup" & goto :statusTask)
echo Target             : !TARGET!
echo Mode               : !MODE!
if /i "!MODE!"=="WIM" echo WIM compression    : !WIM_COMPRESS!
echo Source folders     :
for /l %%I in (1,1,!SRC_COUNT!) do (
    if exist "!SRC_%%I!\" (echo    [ok]      !SRC_%%I!) else (echo    [missing] !SRC_%%I!)
)
:statusTask
echo(
echo Scheduled task "!TASK_NAME!":
schtasks /Query /TN "!TASK_NAME!" /FO LIST 2>nul || echo    not installed
exit /b 0
