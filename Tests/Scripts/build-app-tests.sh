#!/usr/bin/env bash
# Exercise launch retries without building, signing, opening apps, or killing processes.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/kdeconnect-build-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/repo/Scripts" "$scratch/repo/Resources" "$scratch/stubs" "$scratch/bin"
cp "$root/Scripts/build-app.sh" "$scratch/repo/Scripts/"
cp "$root/Resources/Info.plist" "$scratch/repo/Resources/"
printf 'placeholder\n' > "$scratch/bin/KDEConnectNative"
cat > "$scratch/stubs/swift" <<'STUB'
#!/bin/sh
case "$*" in *--show-bin-path*) printf '%s\n' "$TEST_BIN" ;; esac
STUB
cat > "$scratch/stubs/open" <<'STUB'
#!/bin/sh
count=0
if [ -f "$TEST_COUNT" ]; then count=$(cat "$TEST_COUNT"); fi
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_COUNT"
[ "$count" -eq "$TEST_SUCCEED_AT" ]
STUB
for command in codesign xcrun sleep; do
    printf '#!/bin/sh\nexit 0\n' > "$scratch/stubs/$command"
done
for command in pkill pgrep; do
    printf '#!/bin/sh\nexit 1\n' > "$scratch/stubs/$command"
done
chmod +x "$scratch/stubs/"*
export PATH="$scratch/stubs:$PATH" TEST_BIN="$scratch/bin" TEST_COUNT="$scratch/count"
export HOME="$scratch/home"
for success in 1 3 0; do
    export TEST_SUCCEED_AT="$success"
    rm -f "$TEST_COUNT"
    status=0
    bash "$scratch/repo/Scripts/build-app.sh" --install > "$scratch/output" 2>&1 || status=$?
    if [[ "$success" == 0 ]]; then
        test "$status" -ne 0
        test "$(cat "$TEST_COUNT")" -eq 3
        grep -q 'could not open it after three attempts' "$scratch/output"
        if grep -q 'Installed and opened' "$scratch/output"; then
            echo 'Failed launch reported success' >&2
            exit 1
        fi
    else
        test "$status" -eq 0
        test "$(cat "$TEST_COUNT")" -eq "$success"
        grep -q 'Installed and opened' "$scratch/output"
    fi
done
echo 'build-app launch retry tests passed'
