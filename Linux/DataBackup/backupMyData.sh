#!/usr/bin/env bash
# =============================================================================
#  backupMyData.sh - configurable data backup for Linux
#  Modes   : TIMESTAMP (full rsync copy per run) or
#            SNAPSHOT  (rsync --link-dest hard-link snapshots: unchanged files
#                       are stored only once, each run only costs the changes)
#  Schedule: systemd timer (preferred) or cron fallback
#  Help    : backupMyData.sh --help
#  PhK 2026-11-22
#
#  License and Disclaimer
#    Licensed under the MIT License - see LICENSE in the repository root:
#    https://github.com/PhilipKoerberEmerson/BackupTools
#    USE ENTIRELY AT YOUR OWN RISK. This script is provided "AS IS" without
#    warranty or guarantee of any kind. Neither the author(s) nor any
#    affiliated company assumes any responsibility or liability for data
#    loss, system failure, or damages resulting from its use. Review and
#    test it thoroughly before use and always verify your backups.
# =============================================================================
set -u

APP_NAME="BackupMyData"
APP_VERSION="1.0.0"
UNIT_NAME="backupmydata"
SCRIPT_PATH="$(readlink -f "$0")"
SELF="$(basename "$0")"
CFG="${SCRIPT_PATH%.sh}.conf"

TARGET=""
MODE="TIMESTAMP"
SOURCES=()
USED=()
NAME=""
LOG=""
WARN=0
ERR=0

log() {
    local msg="[$(date '+%F %T')] $*"
    echo "$msg"
    [[ -n $LOG ]] && echo "$msg" >> "$LOG"
}

banner() {
    echo "==============================================================================="
    echo " $APP_NAME v$APP_VERSION  -  Data backup for Linux"
    echo "==============================================================================="
    echo
}

usage() {
    banner
    cat <<EOF
USAGE
  $SELF                Interactive menu
  $SELF --run          Run the backup unattended (used by the schedule)
  $SELF --setup        Configure sources, target and mode, then optionally
                       install the automatic backup schedule
  $SELF --install      Install or update the automatic backup schedule (root)
  $SELF --uninstall    Remove the automatic backup schedule (root)
  $SELF --status       Show configuration and schedule status
  $SELF --cfg FILE     Use another configuration file
                       Default: $CFG
  $SELF -h | --help    Show this help

BACKUP MODES
  TIMESTAMP  Every run creates <TARGET>/yyyy-mm-dd_HH-MM-SS/<SourceName> with a
             full copy (rsync). Browsable with any file manager, needs the full
             amount of space per run.
  SNAPSHOT   Every run creates <TARGET>/snapshots/<timestamp>/<SourceName>.
             Unchanged files are HARD-LINKED to the previous snapshot
             (rsync --link-dest), so each snapshot looks like a full copy but
             only costs the changed data. <TARGET>/snapshots/latest points to
             the most recent snapshot.

RESTORE
  Both modes produce plain directory trees - copy files back with cp or rsync:
    rsync -a <TARGET>/snapshots/latest/Documents/ /home/me/Documents/

AUTOMATIC BACKUP
  Installed as systemd timer "$UNIT_NAME.timer" (or /etc/cron.d/$UNIT_NAME when
  systemd is not available). Schedules: daily, weekly or at boot. Missed runs
  are caught up (Persistent=true).
  Manage with: systemctl list-timers $UNIT_NAME.timer

CONFIGURATION FILE (created by --setup, may be edited manually)
  # comment
  TARGET=/mnt/backup
  MODE=SNAPSHOT               TIMESTAMP or SNAPSHOT
  SOURCE=/home/me/Documents
  SOURCE=/srv/projects        repeat SOURCE= for every folder
  Log files are written to <TARGET>/_logs.
  Before copying, a dry run estimates required space (including snapshot
  savings), plus 5% and 64 MiB headroom. Insufficient space stops the run.
  Interactive terminals show activity while estimating and copying.

EXIT CODES
  0 = success   1 = completed with warnings   2 = error
EOF
}

# --- configuration -----------------------------------------------------------
load_config() {
    TARGET=""; MODE="TIMESTAMP"; SOURCES=()
    [[ -f $CFG ]] || return 1
    local key val
    while IFS='=' read -r key val; do
        key="${key//[[:space:]]/}"
        case "$key" in
            TARGET) TARGET="$val" ;;
            MODE)   MODE="${val^^}" ;;
            SOURCE) [[ -n $val ]] && SOURCES+=("$val") ;;
        esac
    done < <(grep -v '^[[:space:]]*[#;]' "$CFG" 2>/dev/null)
    return 0
}

save_config() {
    {
        echo "# $APP_NAME configuration - written $(date '+%F %T')"
        echo "# MODE = TIMESTAMP or SNAPSHOT"
        echo "# Add one SOURCE= line per folder to back up."
        echo "TARGET=$TARGET"
        echo "MODE=$MODE"
        local s
        for s in "${SOURCES[@]}"; do echo "SOURCE=$s"; done
    } > "$CFG" || { echo "ERROR: Cannot write $CFG."; return 1; }
    return 0
}

validate_config() {
    local rc=0
    (( ${#SOURCES[@]} >= 1 )) || { echo "ERROR: No SOURCE folder configured in $CFG."; rc=1; }
    [[ -n $TARGET ]] || { echo "ERROR: No TARGET configured in $CFG."; rc=1; }
    [[ $MODE == TIMESTAMP || $MODE == SNAPSHOT ]] || { echo "ERROR: Invalid MODE '$MODE' - use TIMESTAMP or SNAPSHOT."; rc=1; }
    return $rc
}

setup() {
    load_config || true
    echo "=== Backup configuration ==="
    echo "Configuration file: $CFG"
    echo
    local a p t
    if (( ${#SOURCES[@]} > 0 )); then
        echo "Current source folders:"
        printf '   %s\n' "${SOURCES[@]}"
        read -rp "Keep these source folders? [Y/n] " a
        [[ ${a,,} == n* ]] && SOURCES=()
    fi
    echo "Enter the folders to back up, one per line. Empty line = done."
    while :; do
        read -rp "  Source folder: " p
        if [[ -z $p ]]; then
            (( ${#SOURCES[@]} >= 1 )) && break
            echo "  At least one source folder is required."
            continue
        fi
        p="$(readlink -m "$p")"
        if [[ ! -d $p ]]; then
            read -rp "  WARNING: Folder does not exist: $p - add anyway? [y/N] " a
            [[ ${a,,} == y* ]] || continue
        fi
        SOURCES+=("$p")
    done
    echo
    while :; do
        read -rp "Backup target folder${TARGET:+ [$TARGET]}: " t
        [[ -n $t ]] && TARGET="$(readlink -m "$t")"
        [[ -n $TARGET ]] || continue
        if [[ ! -d $TARGET ]]; then
            read -rp "Target folder does not exist. Create it now? [Y/n] " a
            if [[ ${a,,} != n* ]]; then mkdir -p "$TARGET" || continue; fi
        fi
        break
    done
    echo
    echo "Backup mode:"
    echo "  [1] TIMESTAMP - new folder with a full copy for every backup (rsync)"
    echo "  [2] SNAPSHOT  - hard-link snapshots, unchanged files stored only once"
    read -rp "Select mode [1/2]: " a
    if [[ $a == 2 ]]; then MODE="SNAPSHOT"; else MODE="TIMESTAMP"; fi
    save_config || return 2
    echo
    echo "Configuration saved to $CFG"
    read -rp "Install an automatic backup schedule now? [y/N] " a
    [[ ${a,,} == y* ]] && install_schedule
    return 0
}

# --- backup -------------------------------------------------------------------
unique_name() {  # derive a unique folder name for source $1 within this run
    local n; n="$(basename "$1")"
    [[ $n == / || -z $n ]] && n="root"
    local base="$n" i=1
    while [[ " ${USED[*]-} " == *" $n "* ]]; do
        i=$((i+1)); n="${base}_$i"
    done
    USED+=("$n")
    NAME="$n"
}

with_activity() (  # with_activity <label> <output file> <command...>
    local label="$1" output="$2"; shift 2
    if [[ ! -t 1 ]]; then
        "$@" >"$output" 2>&1
        return $?
    fi
    local pid rc frame=0 started=$SECONDS
    local frames=('|' '/' '-' "\\")
    "$@" >"$output" 2>&1 &
    pid=$!
    trap 'kill -TERM "$pid" 2>/dev/null; wait "$pid"; printf "\r\033[K"; exit 130' INT
    trap 'kill -TERM "$pid" 2>/dev/null; wait "$pid"; printf "\r\033[K"; exit 143' TERM
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s %s (%ss elapsed)' "${frames[frame % 4]}" "$label" "$((SECONDS-started))"
        frame=$((frame+1))
        sleep 0.2
    done
    wait "$pid"; rc=$?
    printf '\r\033[K'
    return "$rc"
)

rsync_options() {  # shared by the estimate and the actual copy
    local src="$1" prev="$2" name="$3"
    RSYNC_OPTS=()
    [[ -n $prev && -d $prev/$name ]] && RSYNC_OPTS+=(--link-dest "$prev/$name")
    [[ $TARGET == "$src"/* ]] && RSYNC_OPTS+=(--exclude "/${TARGET#"$src"/}")
    return 0
}

report_rsync_error() {
    local src="$1" rc="$2" output="$3"
    if grep -Eq 'No space left on device|Disk quota exceeded' "$output"; then
        log "ERROR: Backup destination [$TARGET] is out of free space or its storage quota is exhausted. Backup is incomplete. Free space or choose a larger destination, then run the backup again."
        ERR=$((ERR+1))
    else
        case $rc in
            23|24) log "WARNING: Some files could not be backed up from [$src] (rsync exit $rc). Files may have changed, access may be denied, or the destination filesystem may not support Linux symlinks, special files or filenames. See the rsync details in the log."
                   WARN=$((WARN+1)) ;;
            11)    log "ERROR: Cannot read or write backup data for [$src] (rsync exit 11). Check destination free space, permissions and disk health; see the log for details."
                   ERR=$((ERR+1)) ;;
            *)     log "ERROR: rsync failed for [$src] with exit code $rc; see the log for details."
                   ERR=$((ERR+1)) ;;
        esac
    fi
}

check_space() {
    local ts="$1" dest_root="$TARGET/$1" prev="" src estimate rc
    local total=0 available required headroom
    [[ $MODE == SNAPSHOT ]] && dest_root="$TARGET/snapshots/$ts"
    if [[ $MODE == SNAPSHOT && -d $TARGET/snapshots/latest ]]; then
        prev="$(readlink -f "$TARGET/snapshots/latest")"
    fi
    mkdir -p "$dest_root" || { log "ERROR: Cannot create $dest_root. Check free space and permissions."; ERR=$((ERR+1)); return 1; }
    log "Estimating backup space (scanning source folders; no files are copied)..."
    for src in "${SOURCES[@]}"; do
        [[ -d $src ]] || continue
        unique_name "$src"
        local RSYNC_OPTS=()
        rsync_options "$src" "$prev" "$NAME"
        with_activity "Estimating [$src]" "$LOG.rsync" \
            env LC_ALL=C rsync -aH --dry-run --stats --no-human-readable \
            "${RSYNC_OPTS[@]}" "$src/" "$dest_root/$NAME/"
        rc=$?
        cat "$LOG.rsync" >>"$LOG"
        if (( rc != 0 )); then
            report_rsync_error "$src" "$rc" "$LOG.rsync"
            if (( rc != 23 && rc != 24 )) || (( ERR > 0 )); then
                return 1
            fi
            log "WARNING: Space estimate may be incomplete because some source files could not be scanned."
        fi
        estimate="$(sed -n 's/^Total transferred file size: \([0-9][0-9]*\) bytes$/\1/p' "$LOG.rsync")"
        if [[ ! $estimate =~ ^[0-9]+$ ]]; then
            log "ERROR: Cannot determine required backup space for [$src]. Backup stopped before copying."
            ERR=$((ERR+1)); return 1
        fi
        total=$((total+estimate))
    done
    USED=()
    available="$(LC_ALL=C df -B1 --output=avail "$TARGET" 2>>"$LOG")"
    rc=$?
    available="${available##*$'\n'}"
    available="${available//[[:space:]]/}"
    if (( rc != 0 )) || [[ ! $available =~ ^[0-9]+$ ]]; then
        log "ERROR: Cannot read free space on [$TARGET]. Backup stopped before copying."
        ERR=$((ERR+1)); return 1
    fi
    headroom=$((total/20+64*1024*1024))
    required=$((total+headroom))
    log "Space check: estimated data $total bytes ($(numfmt --to=iec-i --suffix=B "$total")); required with headroom $(numfmt --to=iec-i --suffix=B "$required"); available $(numfmt --to=iec-i --suffix=B "$available")."
    if (( required > available )); then
        log "ERROR: Not enough free space on backup destination [$TARGET]. Need approximately $(numfmt --to=iec-i --suffix=B "$required") including headroom, but only $(numfmt --to=iec-i --suffix=B "$available") is available. Free space or choose a larger destination. Backup stopped before copying."
        ERR=$((ERR+1)); return 1
    fi
    log "Space check passed. This is an estimate; source changes, filesystem overhead or other programs can still exhaust free space."
}

run_rsync() {  # run_rsync <src> <dst> [extra rsync options...]
    local src="$1" dst="$2"; shift 2
    with_activity "Backing up [$src]" "$LOG.rsync" \
        env LC_ALL=C rsync -aH --info=stats1 "$@" "$src/" "$dst/"
    local rc=$?
    cat "$LOG.rsync" >>"$LOG"
    case $rc in
        0) log "OK: [$src] rsync exit code 0" ;;
        *) report_rsync_error "$src" "$rc" "$LOG.rsync" ;;
    esac
}

backup_timestamp() {
    local ts="$1" dest_root="$TARGET/$1" src
    mkdir -p "$dest_root" || { log "ERROR: Cannot create $dest_root"; ERR=$((ERR+1)); return; }
    for src in "${SOURCES[@]}"; do
        if [[ ! -d $src ]]; then
            log "WARNING: Source not found, skipped: $src"; WARN=$((WARN+1)); continue
        fi
        unique_name "$src"
        local RSYNC_OPTS=()
        rsync_options "$src" "" "$NAME"
        log "Copying [$src] to [$dest_root/$NAME]"
        run_rsync "$src" "$dest_root/$NAME" "${RSYNC_OPTS[@]}"
        (( ERR > 0 )) && break
    done
}

backup_snapshot() {
    local ts="$1" snap_root="$TARGET/snapshots" src prev=""
    local dest="$TARGET/snapshots/$1"
    mkdir -p "$dest" || { log "ERROR: Cannot create $dest"; ERR=$((ERR+1)); return; }
    [[ -d $snap_root/latest ]] && prev="$(readlink -f "$snap_root/latest")"
    for src in "${SOURCES[@]}"; do
        if [[ ! -d $src ]]; then
            log "WARNING: Source not found, skipped: $src"; WARN=$((WARN+1)); continue
        fi
        unique_name "$src"
        local RSYNC_OPTS=()
        rsync_options "$src" "$prev" "$NAME"
        log "Snapshotting [$src] to [$dest/$NAME]${prev:+ (hard-linking unchanged files)}"
        run_rsync "$src" "$dest/$NAME" "${RSYNC_OPTS[@]}"
        (( ERR > 0 )) && break
    done
    if (( ERR == 0 )); then
        ln -sfn "$dest" "$snap_root/latest"
        log "Updated $snap_root/latest -> $dest"
    fi
}

do_backup() {
    load_config || { echo "ERROR: Configuration not found: $CFG. Run '$SELF --setup' first."; return 2; }
    validate_config || return 2
    command -v rsync >/dev/null || { echo "ERROR: rsync is not installed."; return 2; }
    local ts work_dir final_log; ts="$(date +%F_%H-%M-%S)"
    TARGET="$(readlink -m "$TARGET")"
    mkdir -p "$TARGET" 2>/dev/null
    [[ -d $TARGET && -w $TARGET ]] || { echo "ERROR: Backup target not reachable or not writable: $TARGET"; return 2; }
    work_dir="$(mktemp -d)" || { echo "ERROR: Cannot create temporary backup log directory."; return 2; }
    LOG="$work_dir/backup_$ts.log"
    final_log="$TARGET/_logs/backup_$ts.log"
    WARN=0; ERR=0; USED=()
    log "===== $APP_NAME v$APP_VERSION - backup started ====="
    log "Host: $(hostname)  User: $(id -un)  Mode: $MODE  Target: $TARGET"
    log "Working log (also available if the destination fills up): $LOG"
    if check_space "$ts"; then
        if [[ $MODE == SNAPSHOT ]]; then backup_snapshot "$ts"; else backup_timestamp "$ts"; fi
    fi
    local rc=0
    (( WARN > 0 )) && rc=1
    (( ERR  > 0 )) && rc=2
    log "===== Backup finished: $ERR error(s), $WARN warning(s), exit code $rc ====="
    if { mkdir -p "$TARGET/_logs" && cp "$LOG" "$final_log"; } 2>"$LOG.rsync"; then
        echo "Log file: $final_log"
        rm -f "$LOG" "$LOG.rsync"
        rmdir "$work_dir"
    else
        cat "$LOG.rsync" >>"$LOG"
        log "ERROR: Cannot save the log to [$final_log]. The destination may be full or not writable. Complete log retained at: $LOG"
        ERR=$((ERR+1)); rc=2
        log "===== Backup finished: $ERR error(s), $WARN warning(s), exit code $rc ====="
        echo "Log file: $LOG"
    fi
    return $rc
}

# --- schedule ------------------------------------------------------------------
require_root() {
    [[ $(id -u) -eq 0 ]] || { echo "ERROR: This action requires root - run with sudo."; return 2; }
}

has_systemd() { command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; }

ask_time() {  # sets T (HH:MM)
    read -rp "Start time HH:MM, 24h [20:00]: " T
    T="${T:-20:00}"
    while ! [[ $T =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        read -rp "Invalid time, use e.g. 07:30 or 20:00: " T
    done
}

ask_day() {  # sets D (Mon..Sun)
    read -rp "Day (Mon..Sun) [Sun]: " D
    case ${D,,} in
        mon*) D=Mon ;; tue*) D=Tue ;; wed*) D=Wed ;; thu*) D=Thu ;;
        fri*) D=Fri ;; sat*) D=Sat ;; *) D=Sun ;;
    esac
}

install_schedule() {
    require_root || return 2
    load_config && validate_config || { echo "Please configure the backup first: $SELF --setup"; return 2; }
    echo "=== Automatic backup schedule ==="
    echo "  [1] Daily at a fixed time"
    echo "  [2] Weekly on a given day at a fixed time"
    echo "  [3] At every boot (5 minutes delay)"
    local sel T D oncal="" cronline=""
    read -rp "Select schedule [1-3, other = cancel]: " sel
    case $sel in
        1) ask_time; oncal="*-*-* $T:00";      cronline="${T#*:} ${T%:*} * * *" ;;
        2) ask_day; ask_time
           oncal="$D *-*-* $T:00";             cronline="${T#*:} ${T%:*} * * ${D,,}" ;;
        3) : ;;
        *) echo "Cancelled."; return 0 ;;
    esac
    if has_systemd; then
        cat > "/etc/systemd/system/$UNIT_NAME.service" <<EOF
[Unit]
Description=$APP_NAME data backup

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash "$SCRIPT_PATH" --run --cfg "$CFG"
Nice=10
IOSchedulingClass=idle
EOF
        {
            echo "[Unit]"
            echo "Description=$APP_NAME backup schedule"
            echo ""
            echo "[Timer]"
            if [[ $sel == 3 ]]; then
                echo "OnBootSec=5min"
            else
                echo "OnCalendar=$oncal"
                echo "Persistent=true"
            fi
            echo ""
            echo "[Install]"
            echo "WantedBy=timers.target"
        } > "/etc/systemd/system/$UNIT_NAME.timer"
        systemctl daemon-reload
        systemctl enable --now "$UNIT_NAME.timer" || { echo "ERROR: Enabling the timer failed."; return 2; }
        systemctl list-timers "$UNIT_NAME.timer" --no-pager
        echo "systemd timer '$UNIT_NAME.timer' installed."
    else
        local prefix=""
        [[ $sel == 3 ]] && { cronline="@reboot"; prefix="sleep 300 && "; }
        echo "$cronline root $prefix/usr/bin/env bash \"$SCRIPT_PATH\" --run --cfg \"$CFG\"" \
            > "/etc/cron.d/$UNIT_NAME" || { echo "ERROR: Writing /etc/cron.d/$UNIT_NAME failed."; return 2; }
        chmod 644 "/etc/cron.d/$UNIT_NAME"
        echo "Cron schedule /etc/cron.d/$UNIT_NAME installed."
    fi
    return 0
}

remove_schedule() {
    require_root || return 2
    local removed=0
    if has_systemd && [[ -f /etc/systemd/system/$UNIT_NAME.timer ]]; then
        systemctl disable --now "$UNIT_NAME.timer" 2>/dev/null
        rm -f "/etc/systemd/system/$UNIT_NAME.timer" "/etc/systemd/system/$UNIT_NAME.service"
        systemctl daemon-reload
        echo "systemd timer '$UNIT_NAME.timer' removed."
        removed=1
    fi
    if [[ -f /etc/cron.d/$UNIT_NAME ]]; then
        rm -f "/etc/cron.d/$UNIT_NAME"
        echo "Cron schedule /etc/cron.d/$UNIT_NAME removed."
        removed=1
    fi
    (( removed )) || echo "No automatic backup schedule installed."
    return 0
}

show_status() {
    echo "Configuration file : $CFG"
    if load_config; then
        echo "Target             : $TARGET"
        echo "Mode               : $MODE"
        echo "Source folders     :"
        local s
        for s in "${SOURCES[@]}"; do
            if [[ -d $s ]]; then echo "   [ok]      $s"; else echo "   [missing] $s"; fi
        done
    else
        echo "   not found - run '$SELF --setup'"
    fi
    echo
    echo "Schedule:"
    local found=0
    if has_systemd && systemctl list-unit-files "$UNIT_NAME.timer" --no-pager 2>/dev/null | grep -q "$UNIT_NAME"; then
        systemctl list-timers "$UNIT_NAME.timer" --no-pager
        found=1
    fi
    [[ -f /etc/cron.d/$UNIT_NAME ]] && { echo "   cron: $(cat /etc/cron.d/$UNIT_NAME)"; found=1; }
    (( found )) || echo "   not installed"
    return 0
}

# --- interactive menu ----------------------------------------------------------
menu() {
    local sel a
    banner
    if [[ ! -f $CFG ]]; then
        read -rp "No configuration found: $CFG - create one now? [Y/n] " a
        [[ ${a,,} == n* ]] || setup
    fi
    while :; do
        echo
        echo "  [1] Run backup now"
        echo "  [2] Configure backup (sources, target, mode, schedule)"
        echo "  [3] Install / update automatic backup schedule"
        echo "  [4] Remove automatic backup schedule"
        echo "  [5] Show configuration and status"
        echo "  [h] Help"
        echo "  [q] Quit"
        read -rp "Select option: " sel
        echo
        case ${sel,,} in
            1) do_backup ;;
            2) setup ;;
            3) install_schedule ;;
            4) remove_schedule ;;
            5) show_status ;;
            h) usage ;;
            q) return 0 ;;
            *) continue ;;
        esac
    done
}

# --- argument parsing -----------------------------------------------------------
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)       ACTION=do_backup ;;
        --setup)     ACTION=setup ;;
        --install)   ACTION=install_schedule ;;
        --uninstall) ACTION=remove_schedule ;;
        --status)    ACTION=show_status ;;
        --cfg)
            shift
            [[ $# -ge 1 ]] || { echo "ERROR: --cfg requires a file path."; exit 2; }
            CFG="$(readlink -m "$1")"
            ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "ERROR: Unknown argument '$1'. Use '$SELF --help'."; exit 2 ;;
    esac
    shift
done

if [[ -n $ACTION ]]; then
    "$ACTION"
    exit $?
fi
menu
exit 0
