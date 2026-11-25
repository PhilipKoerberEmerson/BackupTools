#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/backupMyData.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export TMPDIR="$ROOT/tmp"
mkdir -p "$TMPDIR" "$ROOT/bin" "$ROOT/source folder"
printf 'backup contents\n' >"$ROOT/source folder/file"
export REAL_RSYNC REAL_DF REAL_CP
REAL_RSYNC="$(command -v rsync)"
REAL_DF="$(command -v df)"
REAL_CP="$(command -v cp)"
export PATH="$ROOT/bin:$PATH"

cat >"$ROOT/bin/df" <<'EOF'
#!/usr/bin/env bash
if [[ ${TEST_FREE:-} == invalid ]]; then
    echo "df: test failure" >&2
    exit 1
fi
if [[ -n ${TEST_FREE:-} ]]; then
    printf 'Avail\n%s\n' "$TEST_FREE"
else
    exec "$REAL_DF" "$@"
fi
EOF
cat >"$ROOT/bin/rsync" <<'EOF'
#!/usr/bin/env bash
dry=0
for arg in "$@"; do [[ $arg == --dry-run ]] && dry=1; done
[[ ${TEST_SLOW:-0} == 1 ]] && sleep 0.4
if [[ ${TEST_ESTIMATE:-0} == 1 ]]; then
    if (( dry )); then
        echo 'Total transferred file size: 1000 bytes'
    else
        echo copied >>"$TEST_COPY_MARKER"
    fi
    exit 0
fi
if (( ! dry )) && [[ ${TEST_FAILURE:-} != "" ]]; then
    case $TEST_FAILURE in
        full11|full23) echo 'rsync: write failed: No space left on device (28)' >&2 ;;
        quota) echo 'rsync: write failed: Disk quota exceeded (122)' >&2 ;;
        io) echo 'rsync: Input/output error (5)' >&2 ;;
        partial) echo 'rsync: symlink failed: Operation not permitted (1)' >&2 ;;
    esac
    case $TEST_FAILURE in
        full23|partial) exit 23 ;;
        *) exit 11 ;;
    esac
fi
exec "$REAL_RSYNC" "$@"
EOF
cat >"$ROOT/bin/cp" <<'EOF'
#!/usr/bin/env bash
if [[ ${TEST_LOG_FAIL:-0} == 1 ]]; then
    echo 'cp: No space left on device' >&2
    exit 1
fi
exec "$REAL_CP" "$@"
EOF
chmod +x "$ROOT/bin/"*

configure() {
    TARGET="$ROOT/$1"
    printf 'TARGET=%s\nMODE=%s\nSOURCE=%s\n' \
        "$TARGET" "${2:-TIMESTAMP}" "$ROOT/source folder" >"$ROOT/config"
}

run_backup() {
    local expected="$1" rc=0
    bash "$SCRIPT" --run --cfg "$ROOT/config" >"$ROOT/output" 2>&1 || rc=$?
    if (( rc != expected )); then
        cat "$ROOT/output"
        echo "Expected exit $expected, got $rc" >&2
        exit 1
    fi
}

assert_logged() {
    grep -q "$1" "$ROOT/output"
    grep -q "$1" "$TARGET/_logs/"*.log
}

assert_no_match() {
    if grep -q "$@"; then
        echo "Unexpected match: $*" >&2
        exit 1
    fi
}

configure "full backup"
run_backup 0
cmp "$ROOT/source folder/file" "$TARGET/"*/"source folder/file"
assert_logged 'Space check passed'
assert_no_match 'elapsed)' "$ROOT/output"
[[ -z $(find "$TMPDIR" -type f) ]]

configure snapshots SNAPSHOT
run_backup 0
first="$(readlink -f "$TARGET/snapshots/latest")"
sleep 1
run_backup 0
second="$(readlink -f "$TARGET/snapshots/latest")"
[[ $first != "$second" ]]
[[ $(stat -c %i "$first/source folder/file") == "$(stat -c %i "$second/source folder/file")" ]]
grep -q 'estimated data 0 bytes' "$ROOT/output"
sleep 1
printf 'changed contents\n' >"$ROOT/source folder/file"
run_backup 0
cmp "$ROOT/source folder/file" "$TARGET/snapshots/latest/source folder/file"
grep -q 'estimated data 17 bytes' "$ROOT/output"
previous="$(readlink -f "$TARGET/snapshots/latest")"
sleep 1
export TEST_FAILURE=full23
run_backup 2
[[ $(readlink -f "$TARGET/snapshots/latest") == "$previous" ]]
unset TEST_FAILURE

configure "source folder/nested target"
run_backup 0
cmp "$ROOT/source folder/file" "$TARGET/"*/"source folder/file"
[[ -z $(find "$TARGET" -mindepth 3 -type d -name 'nested target') ]]

export TEST_ESTIMATE=1 TEST_FREE=67109913 TEST_COPY_MARKER="$ROOT/copied"
configure insufficient
run_backup 2
assert_logged 'Not enough free space'
[[ ! -e $TEST_COPY_MARKER ]]
export TEST_FREE=67109914
configure exact
run_backup 0
[[ -f $TEST_COPY_MARKER ]]
unset TEST_ESTIMATE TEST_FREE

for failure in full11 full23 quota io partial; do
    export TEST_FAILURE="$failure"
    configure "$failure"
    mkdir -p "$ROOT/second source"
    printf 'SOURCE=%s\n' "$ROOT/second source" >>"$ROOT/config"
    expected=2
    [[ $failure == partial ]] && expected=1
    run_backup "$expected"
    case $failure in
        full*) assert_logged 'out of free space' ;;
        quota) assert_logged 'storage quota is exhausted' ;;
        io) assert_logged 'Cannot read or write backup data' ;;
        partial) assert_logged 'Some files could not be backed up' ;;
    esac
    if [[ $failure != partial ]]; then
        [[ $(grep -c 'Copying \[' "$ROOT/output") == 1 ]]
    fi
done
unset TEST_FAILURE

export TEST_FREE=invalid
configure df_failure
run_backup 2
assert_logged 'Cannot read free space'
unset TEST_FREE

export TEST_FAILURE=full11 TEST_LOG_FAIL=1
configure log_failure
run_backup 2
retained="$(sed -n 's/^Log file: //p' "$ROOT/output")"
grep -q 'out of free space' "$retained"
grep -q 'Complete log retained' "$retained"
unset TEST_FAILURE TEST_LOG_FAIL

configure terminal
export TEST_SLOW=1
script -q -e -c "bash '$SCRIPT' --run --cfg '$ROOT/config'" "$ROOT/terminal-output" >/dev/null
grep -q 'Estimating .*elapsed)' "$ROOT/terminal-output"
grep -q 'Backing up .*elapsed)' "$ROOT/terminal-output"
assert_no_match 'elapsed)' "$TARGET/_logs/"*.log
echo "All backup tests passed."
