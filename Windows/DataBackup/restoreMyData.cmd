@echo off
:: ===========================================================================
::  restoreMyData.cmd - safe, interactive restore for backupMyData.cmd backups
::  Modes   : TIMESTAMP (robocopy folders) and WIM (DISM images, needs admin)
::  Safety  : read-only until the final confirmation, free-space check before
::            the start, never deletes files, overwrites only on explicit request
::  Help    : restoreMyData.cmd /?
::  PhK 2026-11-22
::
::  License and Disclaimer
::    Licensed under the MIT License - see LICENSE in the repository root:
::    https://github.com/PhilipKoerberEmerson/BackupTools
::    USE ENTIRELY AT YOUR OWN RISK. This script is provided "AS IS" without
::    warranty or guarantee of any kind. Neither the author(s) nor any
::    affiliated company assumes any responsibility or liability for data
::    loss, system failure, or damages resulting from its use. Review and
::    test it thoroughly before use and always verify your backups.
:: ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "APP_NAME=RestoreMyData"
set "APP_VERSION=1.0.0"
set "SCRIPT=%~f0"
set "SELF=%~nx0"
set "CFG=%~dp0backupMyData.ini"
set "BROOT_ARG="

:parseArgs
if "%~1"=="" goto :argsDone
set "ARG=%~1"
if "!ARG:~0,2!"=="--" set "ARG=/!ARG:~2!"
if "!ARG:~0,1!"=="-" set "ARG=/!ARG:~1!"
if "!ARG!"=="/?" goto :help
if /i "!ARG!"=="/h"    goto :help
if /i "!ARG!"=="/help" goto :help
if /i "!ARG!"=="/cfg" (
    if "%~2"=="" (echo ERROR: /cfg requires a file path. & exit /b 2)
    set "CFG=%~f2"
    shift & shift & goto :parseArgs
)
if /i "!ARG!"=="/backup" (
    if "%~2"=="" (echo ERROR: /backup requires a folder path. & exit /b 2)
    set "BROOT_ARG=%~f2"
    shift & shift & goto :parseArgs
)
echo ERROR: Unknown argument "%~1". Use "%SELF% /?" for help.
exit /b 2

:argsDone
title %APP_NAME% v%APP_VERSION%
set "ADMIN=0"
call :isAdmin && set "ADMIN=1"
set "RS_SCRIPT=!SCRIPT!"
set "RS_CFG=!CFG!"
set "RS_BROOT=!BROOT_ARG!"
call :timestamp || (pause & exit /b 2)
set "WORK=!TEMP!\%APP_NAME%_!TS!_!RANDOM!"
mkdir "!WORK!" 2>nul
if not exist "!WORK!\" (echo ERROR: Cannot create work folder "!WORK!". & pause & exit /b 2)
set "RS_WORK=!WORK!"
set "MNT=!WORK!\mnt"
set "MOUNTED=0"

cls
call :banner
call :intro
call :checkAdmin
if errorlevel 1 (call :removeWork & exit /b 0)

:again
call :wizard
set "RC=!errorlevel!"
call :cleanup
echo(
choice /c YN /m "Restore something else"
if not errorlevel 2 (cls & call :banner & goto :again)
call :removeWork
exit /b !RC!


:: ===========================================================================
::  Help
:: ===========================================================================
:help
call :banner
echo USAGE
echo   %SELF%                    Start the interactive restore wizard
echo   %SELF% /cfg ^<file^>        Read the backup location from another configuration
echo                                   file. Default: %~dp0backupMyData.ini
echo   %SELF% /backup ^<folder^>   Restore from this backup location, e.g. a USB disk
echo                                   that now has another drive letter
echo   %SELF% /? ^| /h ^| -h       Show this help
echo   All options accept "/" or "-" as prefix. There is deliberately no unattended mode.
echo(
echo HOW IT WORKS - nothing is written before the final confirmation
echo   1. Backup location  taken from TARGET= in the configuration file, can be changed
echo   2. Backup type      TIMESTAMP or WIM - if both exist you choose; the latest is shown
echo   3. Backup version   newest first; older versions help when something was deleted
echo                       or damaged before the latest backup ran. The status of each
echo                       version is read from ^<TARGET^>\_logs\backup_*.log
echo   4. Backed-up folder one of the SOURCE folders, original location from the log
echo   5. What to restore  everything, a sub-folder or a single file
echo   6. Destination      [1] new empty folder - safest, recommended
echo                       [2] original location, only ADD MISSING files
echo                       [3] original location, REPLACE differing files - optional
echo                           safety copy of every file before it is replaced
echo   7. Plan             size in MB/GB, files to copy/replace, free space check.
echo                       The restore does NOT start if the space is insufficient.
echo   Files that exist only at the destination are never deleted.
echo(
echo NOTES
echo   - WIM backups need administrator rights; the image is mounted read-only to
echo     %%TEMP%% and unmounted afterwards. After an interrupted run use, elevated:
echo        dism /Cleanup-Mountpoints
echo   - Mapped network drives are not visible in an elevated console, use \\server\share.
echo   - Restore logs are written to ^<TARGET^>\_logs\restore_*.log, or to %%TEMP%% if the
echo     backup location is read-only.
echo   - Paths containing "^!" are not supported.
echo(
echo EXIT CODES
echo   0 = restored   1 = restored with warnings   2 = error   3 = cancelled, nothing done
exit /b 0

:banner
echo ===============================================================================
echo  %APP_NAME% v%APP_VERSION%  -  Safe data restore for Windows 10 / 11
echo ===============================================================================
echo(
exit /b 0

:intro
echo This wizard restores data from backups created by backupMyData.cmd.
echo It only READS until you confirm the final restore plan:
echo   - you choose location, backup type, version, folder and destination,
echo   - the required space is calculated and checked BEFORE anything is copied,
echo   - existing files are never deleted, and only replaced if you explicitly say so.
echo You can cancel at every step.
echo(
exit /b 0

:checkAdmin
if "!ADMIN!"=="1" exit /b 0
echo NOTE: This console has NO administrator rights.
echo   TIMESTAMP backups can be restored, but files with restrictive permissions may fail.
echo   WIM backups can only be listed and restored with administrator rights.
echo   [E] Restart this tool as administrator - recommended
echo   [C] Continue without administrator rights
echo   [Q] Quit
choice /c ECQ /n /m "Select: "
set "SEL=!errorlevel!"
if "!SEL!"=="2" (echo( & exit /b 0)
if not "!SEL!"=="1" exit /b 1
call :ps elevate
if errorlevel 1 (echo Elevation was cancelled or failed. & echo( & goto :checkAdmin)
echo The elevated window has been opened. This window can be closed.
exit /b 1


:: ===========================================================================
::  Wizard
:: ===========================================================================
:wizard
call :stepLocation || exit /b 3
call :stepScan     || exit /b 3
call :stepMode     || exit /b 3
call :stepVersion  || exit /b 3
call :stepItem     || exit /b 3
call :stepPart     || exit /b 3
call :stepDest     || exit /b 3
call :stepPlan
if errorlevel 1 exit /b
call :runRestore
exit /b

:: ---------------------------------------------------------------------------
:stepLocation
echo --- Step 1/7: Backup location ---
call :loadConfig
if exist "!CFG!" (echo Configuration file : !CFG!) else (echo Configuration file : !CFG! - not found)
if defined TARGET echo Backup target      : !TARGET!
set "DEF=!TARGET!"
if defined BROOT_ARG set "DEF=!BROOT_ARG!"
:locAsk
set "IN="
if defined DEF (set /p "IN=Backup location to restore from [!DEF!], Q = quit: ") else (set /p "IN=Backup location to restore from, Q = quit: ")
if not defined IN set "IN=!DEF!"
if not defined IN goto :locAsk
if /i "!IN!"=="Q" exit /b 1
call :absPath IN || goto :locAsk
if not exist "!IN!\" (
    echo   Folder not found: !IN!
    if "!ADMIN!"=="1" echo   Mapped network drives are not visible in an elevated console - use \\server\share.
    goto :locAsk
)
set "BROOT=!IN!"
set "RS_ROOT=!BROOT!"
echo(
exit /b 0

:loadConfig
set "TARGET="
if not exist "!CFG!" exit /b 1
for /f "usebackq eol=; tokens=1,* delims==" %%A in ("!CFG!") do if /i "%%A"=="TARGET" set "TARGET=%%B"
exit /b 0

:: ---------------------------------------------------------------------------
:stepScan
echo Scanning !BROOT! - read-only, this may take a moment...
del /q "!WORK!\runs.lst" "!WORK!\items.lst" 2>nul
set "RS_ADMIN=!ADMIN!"
call :ps scan
if errorlevel 1 (echo ERROR: Scanning the backup location failed. & exit /b 1)
set "N_TS=0"
set "N_WIM=0"
set "LATEST_MODE="
set "LATEST_TS="
set "TS_LATEST="
set "WIM_LATEST="
if exist "!WORK!\runs.lst" for /f "usebackq tokens=1,2 delims=|" %%A in ("!WORK!\runs.lst") do (
    if not defined LATEST_MODE (set "LATEST_MODE=%%A" & set "LATEST_TS=%%B")
    if /i "%%A"=="TIMESTAMP" (
        set /a N_TS+=1
        if not defined TS_LATEST set "TS_LATEST=%%B"
    )
    if /i "%%A"=="WIM" (
        set /a N_WIM+=1
        if not defined WIM_LATEST set "WIM_LATEST=%%B"
    )
)
set /a N_ALL=N_TS+N_WIM
if !N_ALL! EQU 0 (
    echo(
    echo No restorable backups found in !BROOT!.
    echo Expected yyyy-MM-dd_HH-mm-ss folders - TIMESTAMP mode - or ^<name^>.wim files - WIM mode.
    exit /b 1
)
echo(
exit /b 0

:: ---------------------------------------------------------------------------
:stepMode
echo --- Step 2/7: Backup type ---
call :fmtTs TS_LATEST F_TS
call :fmtTs WIM_LATEST F_WIM
call :fmtTs LATEST_TS F_ALL
if !N_TS! GTR 0 if !N_WIM! GTR 0 goto :modeAsk
if !N_TS! GTR 0 (set "SEL_MODE=TIMESTAMP") else (set "SEL_MODE=WIM")
echo Only !SEL_MODE! backups were found - latest from !F_ALL!.
echo(
exit /b 0
:modeAsk
echo Both backup types were found in !BROOT!:
echo   [1] TIMESTAMP - !N_TS! backup(s), latest from !F_TS!
echo   [2] WIM       - !N_WIM! version(s), latest from !F_WIM!
echo   [C] Cancel
echo The most recent backup overall is the !LATEST_MODE! backup from !F_ALL!.
choice /c 12C /n /m "Select backup type: "
if errorlevel 3 exit /b 1
if errorlevel 2 (set "SEL_MODE=WIM") else (set "SEL_MODE=TIMESTAMP")
echo(
exit /b 0

:: ---------------------------------------------------------------------------
:stepVersion
echo --- Step 3/7: Backup version ---
set "RUN_N=0"
for /f "usebackq tokens=1-4 delims=|" %%A in ("!WORK!\runs.lst") do (
    if /i "%%A"=="!SEL_MODE!" (
        set /a RUN_N+=1
        set "RUN_!RUN_N!_TS=%%B"
        set "RUN_!RUN_N!_ST=%%C"
        set "RUN_!RUN_N!_CNT=%%D"
    )
)
echo Available !SEL_MODE! backups, newest first:
for /l %%I in (1,1,!RUN_N!) do (
    set "T=!RUN_%%I_TS!"
    set "NUM=   %%I"
    set "MARK="
    if %%I EQU 1 set "MARK=   <-- LATEST"
    echo   [!NUM:~-3!] !T:~0,10! !T:~11,2!:!T:~14,2!:!T:~17,2!   folders: !RUN_%%I_CNT!   status: !RUN_%%I_ST!!MARK!
)
echo Choose an older version if something was deleted or damaged before the latest backup.
:verAsk
set "IN="
set /p "IN=Select backup number [1 = latest], C = cancel: "
if not defined IN set "IN=1"
if /i "!IN!"=="C" exit /b 1
call :isNumber IN 1 !RUN_N! || goto :verAsk
set "SEL_TS=!RUN_%IN%_TS!"
set "SEL_ST=!RUN_%IN%_ST!"
call :fmtTs SEL_TS F_SEL
echo Selected: !SEL_MODE! backup from !F_SEL! - status: !SEL_ST!
if /i not "!SEL_ST!"=="OK" (
    echo   WARNING: According to its log this backup did not finish cleanly, or no log exists.
    echo            Files may be missing in it. Log: !BROOT!\_logs\backup_!SEL_TS!.log
    choice /c YN /m "  Continue with this backup"
    if errorlevel 2 goto :verAsk
)
echo(
exit /b 0

:: ---------------------------------------------------------------------------
:stepItem
echo --- Step 4/7: Backed-up folder ---
set "IT_N=0"
for /f "usebackq tokens=1-7 delims=|" %%A in ("!WORK!\items.lst") do (
    if /i "%%A"=="!SEL_MODE!" if "%%B"=="!SEL_TS!" (
        set /a IT_N+=1
        set "IT_!IT_N!_NAME=%%C"
        set "IT_!IT_N!_ORIG=%%D"
        set "IT_!IT_N!_ST=%%E"
        set "IT_!IT_N!_LOC=%%F"
        set "IT_!IT_N!_IDX=%%G"
    )
)
if !IT_N! EQU 0 (echo ERROR: No folders found in this backup. & exit /b 1)
set "IN=1"
if !IT_N! EQU 1 goto :itemSel
echo This backup contains !IT_N! folders:
for /l %%I in (1,1,!IT_N!) do (
    set "NUM=   %%I"
    set "O=!IT_%%I_ORIG!"
    if "!O!"=="-" set "O=unknown"
    echo   [!NUM:~-3!] !IT_%%I_NAME!   - originally !O!   - status: !IT_%%I_ST!
)
:itemAsk
set "IN="
set /p "IN=Select folder number, C = cancel: "
if /i "!IN!"=="C" exit /b 1
call :isNumber IN 1 !IT_N! || goto :itemAsk
:itemSel
set "NAME=!IT_%IN%_NAME!"
set "ORIG=!IT_%IN%_ORIG!"
if "!ORIG!"=="-" set "ORIG="
set "IST=!IT_%IN%_ST!"
set "LOC=!IT_%IN%_LOC!"
set "IDX=!IT_%IN%_IDX!"
echo Selected folder   : !NAME!
if defined ORIG (echo Original location : !ORIG!) else (echo Original location : unknown - not found in the backup log)
if /i "!IST!"=="FAILED" (
    echo   WARNING: The backup log reports that this folder FAILED - its data may be incomplete.
    choice /c YN /m "  Continue anyway"
    if errorlevel 2 exit /b 1
)
if /i "!SEL_MODE!"=="WIM" (call :mountWim || exit /b 1) else (set "BASE=!LOC!")
echo(
exit /b 0

:mountWim
call :isAdmin || (echo ERROR: Restoring from WIM requires administrator rights. & exit /b 1)
mkdir "!MNT!" 2>nul
echo Mounting image !IDX! of !LOC! read-only - the backup itself is not changed...
dism /English /Mount-Image /ImageFile:"!LOC!" /Index:!IDX! /MountDir:"!MNT!" /ReadOnly
if errorlevel 1 (
    echo ERROR: DISM could not mount the image. After an interrupted earlier run, execute
    echo        dism /Cleanup-Mountpoints   in an elevated console and try again.
    dism /English /Unmount-Image /MountDir:"!MNT!" /Discard >nul 2>&1
    rd "!MNT!" 2>nul
    exit /b 1
)
set "MOUNTED=1"
set "BASE=!MNT!"
exit /b 0

:: ---------------------------------------------------------------------------
:stepPart
echo --- Step 5/7: What to restore ---
set "PART=ALL"
set "REL="
echo   [A] Everything in "!NAME!"
echo   [P] Only a sub-folder or a single file - e.g. something deleted by accident
echo   [B] Browse this backup in Explorer first - only look, do not change anything there
echo   [C] Cancel
choice /c APBC /n /m "Select: "
set "SEL=!errorlevel!"
if "!SEL!"=="3" (start "" explorer.exe "!BASE!" & echo( & goto :stepPart)
if "!SEL!"=="1" goto :partDone
if not "!SEL!"=="2" exit /b 1
echo Enter the path relative to the backed-up folder, e.g.  Projects\2025  or  Letters\Offer.docx
echo A full path inside the backup or inside the original location is accepted as well.
:relAsk
set "PART=ALL"
set "IN="
set /p "IN=  Path, empty = back: "
if not defined IN (echo( & goto :stepPart)
set "IN=!IN:"=!"
set "REL=!IN!"
call :pathIn IN BASE && set "REL=!PI_REST!"
if defined ORIG call :pathIn IN ORIG && set "REL=!PI_REST!"
:relTrim
if not defined REL goto :partDone
if "!REL:~0,1!"=="\" (set "REL=!REL:~1!" & goto :relTrim)
if "!REL:~-1!"=="\" (set "REL=!REL:~0,-1!" & goto :relTrim)
if not "!REL::=!"=="!REL!" goto :relBad
if not "!REL:..=!"=="!REL!" goto :relBad
for /f "delims=*?" %%X in ("x!REL!x") do if not "%%X"=="x!REL!x" goto :relBad
if exist "!BASE!\!REL!\" (
    set "PART=DIR"
) else if exist "!BASE!\!REL!" (
    set "PART=FILE"
) else (
    echo   Not found in this backup: !REL!
    goto :relAsk
)
goto :partDone
:relBad
echo   Invalid path. Use a path inside the backed-up folder, without "..", "*" or "?".
goto :relAsk
:partDone
if "!PART!"=="ALL" (set "SRC=!BASE!") else (set "SRC=!BASE!\!REL!")
echo Measuring the selected data - read-only...
set "RS_SRC=!SRC!"
set "RS_DST="
set "RS_POLICY=NEW"
call :measure || exit /b 1
echo   Selected: !M_FILES! file(s), !M_BYTES_H!
if "!M_FILES!"=="0" (echo   The selection contains no files - nothing to restore. & exit /b 1)
echo(
exit /b 0

:: ---------------------------------------------------------------------------
:stepDest
echo --- Step 6/7: Restore destination ---
set "SRC_DIR=!SRC!"
set "SRC_FILE="
set "ODEST="
if "!PART!"=="FILE" for %%F in ("!SRC!") do (set "SRC_DIR=%%~dpF" & set "SRC_FILE=%%~nxF")
call :normPath SRC_DIR
if defined ORIG (
    if "!PART!"=="ALL"  set "ODEST=!ORIG!"
    if "!PART!"=="DIR"  set "ODEST=!ORIG!\!REL!"
    if "!PART!"=="FILE" for %%F in ("!ORIG!\!REL!") do set "ODEST=%%~dpF"
)
if defined ODEST call :normPath ODEST
if defined ODEST (set "OTXT=!ODEST!") else (set "OTXT=original location unknown - you will be asked for the folder")
echo   [1] Into a NEW, EMPTY folder - safest, nothing existing is touched (recommended)
echo   [2] Original location, ONLY ADD MISSING files - existing files stay unchanged
echo       !OTXT!
echo   [3] Original location, REPLACE files that differ from the backup - DANGEROUS
echo       Newer changes in replaced files are lost unless you keep the offered safety copy.
echo   [C] Cancel
echo   Files that exist only at the destination are NEVER deleted by any method.
choice /c 123C /n /m "Select method: "
set "SEL=!errorlevel!"
set "POLICY="
if "!SEL!"=="1" (set "POLICY=NEW" & set "DEF=!USERPROFILE!\RestoreMyData\!NAME!_!SEL_TS!")
if "!SEL!"=="2" (set "POLICY=MISSING" & set "DEF=!ODEST!")
if "!SEL!"=="3" (set "POLICY=OVERWRITE" & set "DEF=!ODEST!")
if not defined POLICY exit /b 1
:destAsk
set "IN="
if defined DEF (set /p "IN=Destination folder [!DEF!], C = cancel: ") else (set /p "IN=Destination folder, C = cancel: ")
if not defined IN set "IN=!DEF!"
if not defined IN goto :destAsk
if /i "!IN!"=="C" exit /b 1
call :absPath IN || goto :destAsk
set "DST=!IN!"
call :pathIn DST BROOT && (echo   Not allowed: the destination lies inside the backup location. & goto :destAsk)
call :pathIn BROOT DST && (echo   Not allowed: the backup location lies inside the destination. & goto :destAsk)
call :pathIn DST WORK  && (echo   Not allowed: this is the temporary work folder of this tool. & goto :destAsk)
if exist "!DST!" if not exist "!DST!\" (echo   Not allowed: a FILE with this name exists. & goto :destAsk)
if "!POLICY!"=="NEW" (
    call :isEmptyDir DST || (echo   The folder is not empty. Choose a new or empty folder, or another method. & goto :destAsk)
) else (
    if not exist "!DST!\" echo   Note: the folder does not exist and will be created.
    if defined ODEST if /i not "!DST!"=="!ODEST!" echo   Note: this is NOT the original location !ODEST!
)
echo(
exit /b 0

:: ---------------------------------------------------------------------------
:stepPlan
echo --- Step 7/7: Restore plan and space check ---
call :timestamp || exit /b 2
set "RUN_TS=!TS!"
echo Comparing backup and destination - read-only...
set "RS_SRC=!SRC!"
set "RS_DST=!DST!"
set "RS_POLICY=!POLICY!"
call :measure || exit /b 2
if "!POLICY!"=="NEW"       set "PTXT=copy into a new, empty folder"
if "!POLICY!"=="MISSING"   set "PTXT=ADD MISSING FILES ONLY - existing files are not changed"
if "!POLICY!"=="OVERWRITE" set "PTXT=REPLACE files that differ from the backup"
if "!PART!"=="ALL"  set "WTXT=everything"
if "!PART!"=="DIR"  set "WTXT=sub-folder !REL!"
if "!PART!"=="FILE" set "WTXT=single file !REL!"
set "OTXT=!ORIG!"
if not defined OTXT set "OTXT=unknown"
echo(
echo ===============================================================================
echo  RESTORE PLAN - nothing has been changed so far
echo ===============================================================================
echo  Backup           : !SEL_MODE! backup from !F_SEL!, status: !SEL_ST!
if /i "!SEL_MODE!"=="WIM" (
    echo  WIM image        : !LOC!, index !IDX!
) else (
    echo  Backup folder    : !LOC!
)
echo  Backed-up folder : !NAME!, originally !OTXT!
echo  What             : !WTXT!
echo  Restore to       : !DST!
echo  Method           : !PTXT!
echo  Files to copy    : !M_FILES! files = !M_BYTES_H!
if not "!POLICY!"=="NEW" echo  Left unchanged   : !M_KEPT! files already at the destination
if "!POLICY!"=="OVERWRITE" echo  REPLACED         : !M_OVER! existing files = !M_OVER_H! get the backup version
echo  Free space       : !M_FREE_H! on the destination drive, file system !M_FS!
echo  Space needed     : about !M_REQ_H! - data plus 5%% and 64 MB headroom
echo ===============================================================================
if not "!M_SCANERR!"=="0" echo WARNING: !M_SCANERR! folders could not be read - the numbers above may be too low.
if "!M_FILES!"=="0" (echo Nothing to do: the destination already contains all selected files. Restore NOT started. & exit /b 3)
if "!M_FAT!"=="1" (echo ERROR: The destination uses FAT32, which cannot store files of 4 GB or more. Restore NOT started. & exit /b 2)
if "!M_SPACE!"=="LOW" (
    echo ERROR: NOT ENOUGH FREE SPACE on the destination: needed about !M_REQ_H!, available !M_FREE_H!.
    echo        Free some space or choose another destination. Restore NOT started.
    exit /b 2
)
if "!M_SPACE!"=="UNKNOWN" (
    echo WARNING: The free space of the destination could not be determined.
    choice /c YN /m "Continue WITHOUT a space check"
    if errorlevel 2 (echo Cancelled - nothing was changed. & exit /b 3)
)
set "SAFETY="
if "!POLICY!"=="OVERWRITE" if not "!M_OVER!"=="0" (
    call :askSafety
    if errorlevel 1 exit /b
)
echo(
if "!POLICY!"=="OVERWRITE" if not "!M_OVER!"=="0" goto :confirmHard
choice /c YN /m "Start the restore now"
if errorlevel 2 (echo Cancelled - nothing was changed. & exit /b 3)
exit /b 0
:confirmHard
echo !M_OVER! existing files will be REPLACED by their backup version.
if not defined SAFETY echo Without a safety copy this cannot be undone.
set "IN="
set /p "IN=Type OVERWRITE in capital letters to start, anything else cancels: "
if not "!IN!"=="OVERWRITE" (echo Cancelled - nothing was changed. & exit /b 3)
exit /b 0

:askSafety
choice /c YN /m "Show the list of files that will be replaced"
if not errorlevel 2 more < "!WORK!\overwrite.txt"
set "SAFETY=!DST!_before_restore_!RUN_TS!"
echo A safety copy saves the current version of the !M_OVER! files before they are replaced, to:
echo   !SAFETY!
choice /c YN /m "Keep a safety copy (strongly recommended)"
if errorlevel 2 (set "SAFETY=" & exit /b 0)
if "!M_SPACES!"=="LOW" (
    echo NOT ENOUGH FREE SPACE for data plus safety copy: needed about !M_REQS_H!, available !M_FREE_H!.
    echo   [N] Continue WITHOUT safety copy   [C] Cancel - nothing is changed
    choice /c NC /n /m "Select: "
    if errorlevel 2 (echo Cancelled - nothing was changed. & exit /b 3)
    set "SAFETY="
)
exit /b 0

:: ---------------------------------------------------------------------------
:runRestore
set "LOG=!BROOT!\_logs\restore_!RUN_TS!.log"
if exist "!BROOT!\_logs\" (type nul >> "!LOG!") 2>nul
if not exist "!LOG!" set "LOG=!TEMP!\restore_!RUN_TS!.log"
call :log "===== %APP_NAME% v%APP_VERSION% - restore started ====="
call :log "Computer: !COMPUTERNAME!  User: !USERNAME!  Backup: !SEL_MODE! !SEL_TS!  Folder: !NAME!"
if /i "!SEL_MODE!"=="WIM" call :log "Image: !LOC! index !IDX!"
call :log "Source: !SRC!"
call :log "Destination: !DST!  Method: !POLICY!  Files: !M_FILES!  Size: !M_BYTES_H!  Replaced: !M_OVER!"
if defined SAFETY (
    call :log "Creating safety copy of !M_OVER! files in !SAFETY!"
    set "RS_DST=!DST!"
    set "RS_SAFETY=!SAFETY!"
    call :ps safety
    if errorlevel 1 (
        call :log "ERROR: Safety copy failed - restore NOT started, nothing was overwritten."
        echo Log file: !LOG!
        exit /b 2
    )
    call :log "OK: safety copy created"
)
set "ROBO_OPT=/COPY:DAT /DCOPY:T /R:2 /W:5 /XJ /MT:8 /NP /NDL"
if not "!PART!"=="FILE" set "ROBO_OPT=!ROBO_OPT! /E"
:: /XC /XN /XO = skip every file that already exists at the destination
if "!POLICY!"=="MISSING" set "ROBO_OPT=!ROBO_OPT! /XC /XN /XO"
:: Restore mode (/B) writes files regardless of ACLs, only possible when elevated
if "!ADMIN!"=="1" set "ROBO_OPT=!ROBO_OPT! /B"
:: robocopy would read "D:\" as an escaped quote, so drive roots get a doubled backslash
set "S_ARG=!SRC_DIR!"
if "!S_ARG:~-1!"=="\" set "S_ARG=!S_ARG!\"
set "D_ARG=!DST!"
if "!D_ARG:~-1!"=="\" set "D_ARG=!D_ARG!\"
if "!PART!"=="FILE" (
    robocopy "!S_ARG!" "!D_ARG!" "!SRC_FILE!" !ROBO_OPT! /TEE /LOG+:"!LOG!"
) else (
    robocopy "!S_ARG!" "!D_ARG!" !ROBO_OPT! /TEE /LOG+:"!LOG!"
)
set "RRC=!errorlevel!"
set "RC=0"
if !RRC! GEQ 8 (
    call :log "ERROR: robocopy failed with exit code !RRC! - see the log for files that could not be restored"
    set "RC=2"
) else if !RRC! GEQ 4 (
    call :log "WARNING: robocopy reported mismatches, exit code !RRC!"
    set "RC=1"
) else (
    call :log "OK: restore completed, robocopy exit code !RRC!"
)
call :log "===== Restore finished, exit code !RC! ====="
echo(
echo Log file: !LOG!
if defined SAFETY echo Safety copy of the replaced files: !SAFETY!
choice /c YN /m "Open the destination folder in Explorer"
if not errorlevel 2 start "" explorer.exe "!DST!"
exit /b !RC!

:: ---------------------------------------------------------------------------
:cleanup
if not "!MOUNTED!"=="1" exit /b 0
echo Unmounting the read-only WIM image...
:cleanupRetry
dism /English /Unmount-Image /MountDir:"!MNT!" /Discard >nul
if not errorlevel 1 (set "MOUNTED=0" & rd "!MNT!" 2>nul & exit /b 0)
echo WARNING: The image could not be unmounted. Close all Explorer windows and programs
echo          that show files from !MNT!
choice /c RS /m "Retry or Skip"
if errorlevel 2 (
    echo Unmount it later in an elevated console with:
    echo   dism /Unmount-Image /MountDir:"!MNT!" /Discard
    exit /b 1
)
goto :cleanupRetry

:removeWork
if not defined WORK exit /b 0
if "!MOUNTED!"=="1" exit /b 0
del /q "!WORK!\*.lst" "!WORK!\*.txt" 2>nul
rd "!MNT!" 2>nul
rd "!WORK!" 2>nul
exit /b 0


:: ===========================================================================
::  Helpers
:: ===========================================================================
:: Run an operation of the PowerShell helper embedded at the end of this file.
:: Parameters are passed in RS_* environment variables.
:ps
set "RS_OP=%~1"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:RS_SCRIPT);$i=$f.LastIndexOf('#'+'#PSHELPER##');if($i -lt 0){exit 9};& ([ScriptBlock]::Create($f.Substring($i)))"
exit /b !errorlevel!

:measure
del /q "!WORK!\measure.txt" "!WORK!\overwrite.lst" "!WORK!\overwrite.txt" 2>nul
for %%K in (FILES BYTES_H OVER OVER_H KEPT REQ_H REQS_H FREE_H SPACE SPACES SCANERR FS FAT) do set "M_%%K="
call :ps measure
if errorlevel 1 (echo ERROR: Measuring the data failed. & exit /b 1)
for /f "usebackq tokens=1,* delims==" %%A in ("!WORK!\measure.txt") do set "M_%%A=%%B"
exit /b 0

:: Require an absolute path in variable %1 (X:\... or \\server\share) and normalise it
:absPath
set "AP=!%~1!"
set "AP=!AP:"=!"
if "!AP:~1,1!"==":" goto :absPathOk
if "!AP:~0,2!"=="\\" goto :absPathOk
echo   Please enter a full path, e.g. D:\Backup or \\server\share\Backup.
exit /b 1
:absPathOk
set "%~1=!AP!"
call :normPath %~1
exit /b 0

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

:: errorlevel 0 if the path in variable %1 equals or lies inside the folder in variable %2;
:: the remaining relative part is returned in PI_REST
:pathIn
set "PI_C=!%~1!"
set "PI_P=!%~2!"
set "PI_REST="
if "!PI_P:~-1!"=="\" set "PI_P=!PI_P:~0,-1!"
if /i "!PI_C!"=="!PI_P!" exit /b 0
set "PI_P=!PI_P!\"
call :strLen PI_P PI_L
for %%L in (!PI_L!) do if /i "!PI_C:~0,%%L!"=="!PI_P!" (set "PI_REST=!PI_C:~%%L!" & exit /b 0)
exit /b 1

:strLen
set "SL_S=!%~1!#"
set "SL_N=0"
for %%P in (4096 2048 1024 512 256 128 64 32 16 8 4 2 1) do (
    if not "!SL_S:~%%P,1!"=="" (set /a SL_N+=%%P & set "SL_S=!SL_S:~%%P!")
)
set "%~2=!SL_N!"
exit /b 0

:: errorlevel 0 if the folder in variable %1 does not exist or is empty
:isEmptyDir
if not exist "!%~1!\" exit /b 0
for /f "delims=" %%X in ('dir /a /b "!%~1!" 2^>nul ^| findstr /v /i /x /c:"System Volume Information" /c:"$RECYCLE.BIN"') do exit /b 1
exit /b 0

:: errorlevel 0 if variable %1 holds a whole number from %2 to %3
:isNumber
set "INUM=!%~1!"
set "INUM_T=!INUM!"
if not defined INUM_T goto :isNumberBad
for %%D in (0 1 2 3 4 5 6 7 8 9) do if defined INUM_T set "INUM_T=!INUM_T:%%D=!"
if defined INUM_T goto :isNumberBad
if "!INUM:~0,1!"=="0" goto :isNumberBad
if not "!INUM:~5!"=="" goto :isNumberBad
if !INUM! LSS %~2 goto :isNumberBad
if !INUM! GTR %~3 goto :isNumberBad
exit /b 0
:isNumberBad
echo   Please enter a number from %~2 to %~3.
exit /b 1

:: Format the yyyy-MM-dd_HH-mm-ss value of variable %1 as "yyyy-MM-dd HH:mm:ss" into variable %2
:fmtTs
set "FT=!%~1!"
if not defined FT (set "%~2=" & exit /b 0)
set "%~2=!FT:~0,10! !FT:~11,2!:!FT:~14,2!:!FT:~17,2!"
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

:: The PowerShell helper below is read by :ps; cmd.exe never executes it.
goto :eof
##PSHELPER## Embedded PowerShell helper of restoreMyData.cmd
# Operation in RS_OP (scan, measure, safety, elevate), parameters in RS_* environment variables.
$ErrorActionPreference = 'Stop'
$conEnc = [Console]::OutputEncoding
if ($conEnc.CodePage -eq 65001) { $conEnc = New-Object System.Text.UTF8Encoding $false }
$utf8 = New-Object System.Text.UTF8Encoding $false
$tsPattern = '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$'

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

# Status and original source paths of one backup run, read from <TARGET>\_logs\backup_<ts>.log
$logCache = @{}
function Get-LogInfo([string]$LogDir, [string]$Ts) {
    if ($logCache.ContainsKey($Ts)) { return $logCache[$Ts] }
    $r = @{ Status = 'no log'; Src = @{}; Images = @{}; Item = @{} }
    $f = Join-Path $LogDir "backup_$Ts.log"
    if (Test-Path -LiteralPath $f -PathType Leaf) {
        $r.Status = 'incomplete'
        foreach ($l in [IO.File]::ReadAllLines($f, $conEnc)) {
            if ($l -match 'Copying \[(.+?)\] to \[(.+)\]\s*$') { $r.Src[[IO.Path]::GetFileName($Matches[2])] = $Matches[1] }
            elseif ($l -match 'OK: \[(.+?)\] stored as image \[(.+)\]\s*$') { $r.Images[$Matches[2]] = $Matches[1]; $r.Item[$Matches[1]] = 'OK' }
            elseif ($l -match 'OK: \[(.+?)\] robocopy exit code') { $r.Item[$Matches[1]] = 'OK' }
            elseif ($l -match 'WARNING: robocopy reported mismatches for \[(.+?)\]') { $r.Item[$Matches[1]] = 'warnings' }
            elseif ($l -match 'ERROR: (?:robocopy|DISM) failed for \[(.+?)\]') { $r.Item[$Matches[1]] = 'FAILED' }
            elseif ($l -match 'Backup finished: (\d+) error\(s\), (\d+) warning\(s\)') {
                if ([int]$Matches[1] -gt 0) { $r.Status = "$($Matches[1]) error(s)" }
                elseif ([int]$Matches[2] -gt 0) { $r.Status = "$($Matches[2]) warning(s)" }
                else { $r.Status = 'OK' }
            }
        }
    }
    $logCache[$Ts] = $r
    return $r
}

function Get-ItemStatus($Info, [string]$Orig) {
    if ($Orig -and $Info.Item.ContainsKey($Orig)) { return $Info.Item[$Orig] }
    return 'unknown'
}

function Invoke-Scan {
    $root = $env:RS_ROOT
    $logDir = Join-Path $root '_logs'
    $runs = New-Object System.Collections.ArrayList
    $items = New-Object System.Collections.ArrayList

    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $tsPattern })) {
        $subs = @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue)
        if ($subs.Count -eq 0) { continue }
        $info = Get-LogInfo $logDir $d.Name
        [void]$runs.Add("TIMESTAMP|$($d.Name)|$($info.Status)|$($subs.Count)")
        foreach ($s in $subs) {
            $orig = $info.Src[$s.Name]
            $st = Get-ItemStatus $info $orig
            if (-not $orig) { $orig = '-' }
            [void]$items.Add("TIMESTAMP|$($d.Name)|$($s.Name)|$orig|$st|$($s.FullName)|0")
        }
    }

    $wims = @(Get-ChildItem -LiteralPath $root -Filter '*.wim' -File -Force -ErrorAction SilentlyContinue)
    if ($wims.Count -gt 0 -and $env:RS_ADMIN -ne '1') {
        Write-Host "  NOTE: $($wims.Count) WIM backup file(s) found, but WIM versions can only be read with"
        Write-Host "        administrator rights. Restart this tool as administrator to restore from them."
        $wims = @()
    }
    $wimRuns = @{}
    foreach ($w in $wims) {
        try { $images = @(Get-WindowsImage -ImagePath $w.FullName) }
        catch { Write-Host "  WARNING: Cannot read $($w.FullName): $($_.Exception.Message)"; continue }
        foreach ($img in $images) {
            if ($img.ImageName -notmatch '^(.+) (\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})$') {
                Write-Host "  NOTE: Image $($img.ImageIndex) '$($img.ImageName)' in $($w.Name) was not created by backupMyData - skipped."
                continue
            }
            $name = $Matches[1]; $ts = $Matches[2]
            $info = Get-LogInfo $logDir $ts
            $orig = $info.Images[$img.ImageName]
            if (-not $orig -and $img.ImageDescription -match '^(.+) on [^ ]+$') { $orig = $Matches[1] }
            $st = Get-ItemStatus $info $orig
            if (-not $orig) { $orig = '-' }
            [void]$items.Add("WIM|$ts|$name|$orig|$st|$($w.FullName)|$($img.ImageIndex)")
            $wimRuns[$ts] = 1 + [int]$wimRuns[$ts]
        }
    }
    foreach ($ts in $wimRuns.Keys) { [void]$runs.Add("WIM|$ts|$((Get-LogInfo $logDir $ts).Status)|$($wimRuns[$ts])") }

    $sortedRuns = @($runs | Sort-Object -Descending -Property { ($_ -split '\|')[1] }, { ($_ -split '\|')[0] })
    $sortedItems = @($items | Sort-Object)
    [IO.File]::WriteAllLines((Join-Path $env:RS_WORK 'runs.lst'), [string[]]$sortedRuns, $conEnc)
    [IO.File]::WriteAllLines((Join-Path $env:RS_WORK 'items.lst'), [string[]]$sortedItems, $conEnc)
}

# Walk a folder tree like robocopy /E /XJ: files only, junctions/symlinked folders are not followed.
# Returns @(FileInfo, relative path); the relative path is tracked during the walk because
# .NET may return long names for a base path given in 8.3 short form.
function Get-SourceFiles([string]$Path, $Stats) {
    if ([IO.File]::Exists($Path)) { $fi = [IO.FileInfo]::new($Path); return ,@($fi, $fi.Name) }
    $stack = New-Object System.Collections.Stack
    $stack.Push(@([IO.DirectoryInfo]::new($Path), ''))
    while ($stack.Count -gt 0) {
        $dir, $prefix = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { $Stats.Errors++; continue }
        foreach ($e in $entries) {
            if ($e -is [IO.DirectoryInfo]) {
                if (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push(@($e, ($prefix + $e.Name + '\'))) }
            } else { ,@($e, ($prefix + $e.Name)) }
        }
    }
}

# Bytes and files robocopy will copy for the chosen policy, plus free space on the destination
function Invoke-Measure {
    $src = $env:RS_SRC; $dst = $env:RS_DST; $policy = $env:RS_POLICY
    $dstExists = $dst -and [IO.Directory]::Exists($dst)
    $stats = @{ Errors = 0 }
    $files = 0; $bytes = [int64]0; $over = 0; $overBytes = [int64]0; $kept = 0; $maxFile = [int64]0
    $listUtf = [IO.StreamWriter]::new((Join-Path $env:RS_WORK 'overwrite.lst'), $false, $utf8)
    $listCon = [IO.StreamWriter]::new((Join-Path $env:RS_WORK 'overwrite.txt'), $false, $conEnc)
    try {
        Get-SourceFiles $src $stats | ForEach-Object {
            $f, $rel = $_
            if ($f.Length -gt $maxFile) { $maxFile = $f.Length }
            $copy = $true
            if ($dstExists) {
                $t = [IO.FileInfo]::new([IO.Path]::Combine($dst, $rel))
                if ($t.Exists) {
                    if ($policy -eq 'OVERWRITE' -and ($t.Length -ne $f.Length -or $t.LastWriteTimeUtc -ne $f.LastWriteTimeUtc)) {
                        $over++; $overBytes += $t.Length
                        $listUtf.WriteLine($rel); $listCon.WriteLine("  $rel")
                    } else { $copy = $false; $kept++ }
                }
            }
            if ($copy) { $files++; $bytes += $f.Length }
        }
    } finally { $listUtf.Close(); $listCon.Close() }

    $free = [int64]-1; $fs = 'unknown'
    if ($dst) {
        $p = $dst
        while ($p -and -not [IO.Directory]::Exists($p)) { $p = [IO.Path]::GetDirectoryName($p) }
        if ($p) {
            try {
                $fso = New-Object -ComObject Scripting.FileSystemObject
                $drv = $fso.GetDrive($fso.GetDriveName($p))
                $free = [int64]$drv.AvailableSpace; $fs = $drv.FileSystem
            } catch {
                try { $di = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($p)); $free = $di.AvailableFreeSpace; $fs = $di.DriveFormat } catch { }
            }
        }
    }
    $headroom = [int64]($bytes / 20) + 64MB
    $req = $bytes + $headroom
    $reqSafe = $req + $overBytes
    $space = 'UNKNOWN'; $spaceSafe = 'UNKNOWN'
    if ($free -ge 0) {
        $space = if ($req -le $free) { 'OK' } else { 'LOW' }
        $spaceSafe = if ($reqSafe -le $free) { 'OK' } else { 'LOW' }
    }
    $fat = if ($fs -eq 'FAT32' -and $maxFile -ge 4GB) { 1 } else { 0 }
    $out = @(
        "FILES=$files", "BYTES_H=$(Format-Size $bytes)", "OVER=$over", "OVER_H=$(Format-Size $overBytes)",
        "KEPT=$kept", "REQ_H=$(Format-Size $req)", "REQS_H=$(Format-Size $reqSafe)",
        "FREE_H=$(if ($free -ge 0) { Format-Size $free } else { 'unknown' })",
        "SPACE=$space", "SPACES=$spaceSafe", "SCANERR=$($stats.Errors)", "FS=$fs", "FAT=$fat"
    )
    [IO.File]::WriteAllLines((Join-Path $env:RS_WORK 'measure.txt'), [string[]]$out, $conEnc)
}

# Copy every destination file that is about to be replaced into the safety folder first
function Invoke-Safety {
    $n = 0
    foreach ($rel in [IO.File]::ReadAllLines((Join-Path $env:RS_WORK 'overwrite.lst'), $utf8)) {
        if (-not $rel) { continue }
        $to = [IO.Path]::Combine($env:RS_SAFETY, $rel)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
        [IO.File]::Copy([IO.Path]::Combine($env:RS_DST, $rel), $to, $false)
        $n++
    }
    Write-Host "  $n file(s) saved to $($env:RS_SAFETY)"
}

function Invoke-Elevate {
    $a = '/cfg "' + $env:RS_CFG + '"'
    if ($env:RS_BROOT) { $a += ' /backup "' + $env:RS_BROOT + '"' }
    Start-Process -FilePath $env:RS_SCRIPT -ArgumentList $a -Verb RunAs
}

try {
    switch ($env:RS_OP) {
        'scan'    { Invoke-Scan }
        'measure' { Invoke-Measure }
        'safety'  { Invoke-Safety }
        'elevate' { Invoke-Elevate }
        default   { throw "Unknown helper operation '$($env:RS_OP)'" }
    }
    exit 0
} catch {
    Write-Host "  ERROR: $($_.Exception.Message)"
    exit 2
}
