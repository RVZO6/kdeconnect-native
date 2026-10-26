#!/usr/bin/env bash
# Verify a fresh extraction, not just the app in the build directory.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
(cd build/release && shasum -a 256 --check "KDE-Connect-Native-$version-macos-arm64.zip.sha256")
ditto -x -k "build/release/KDE-Connect-Native-$version-macos-arm64.zip" "$scratch"
app="$scratch/KDE Connect Native.app"
helper="$app/Contents/Helpers/KDE Connect.app"
codesign --verify --deep --strict "$app"
test "$(lipo -archs "$app/Contents/MacOS/KDEConnectNative")" = arm64
test -f "$app/Contents/Resources/ThirdPartyNotices.txt"
test -d "$helper/Contents/Resources/licenses"
test -f "$app/Contents/Resources/UpstreamLicenses/GPL-2.0-or-later.txt"
QT_QPA_PLATFORM=offscreen "$helper/Contents/MacOS/kdeconnectd" --version
# Real D-Bus startup checks relocation and the bundled config without touching
# the user's shared address file or starting KDE Connect on their network.
"$helper/Contents/MacOS/dbus-daemon" --config-file "$helper/Contents/Resources/dbus-1/session.conf" \
    --address "unix:tmpdir=$scratch" --fork --print-address=1 --print-pid=1 > "$scratch/bus"
pid="$(tail -1 "$scratch/bus")"
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$scratch"' EXIT
grep -q '^unix:' "$scratch/bus"
kill "$pid"
trap 'rm -rf "$scratch"' EXIT
echo 'Release archive, signatures, architecture, and relocated D-Bus verified.'
