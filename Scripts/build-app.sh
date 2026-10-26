#!/usr/bin/env bash
# Builds "KDE Connect Native.app" into ./build. Pass --install to copy it to
# ~/Applications and restart it.
set -euo pipefail

cd "$(dirname "$0")/.."
config=release
app="build/KDE Connect Native.app"

swift build -c "$config" --product KDEConnectNative
bin="$(swift build -c "$config" --show-bin-path)/KDEConnectNative"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/KDEConnectNative"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Reuse the KDE Connect icon when it is installed.
icon="/Applications/KDE Connect.app/Contents/Resources/sc-apps-kdeconnect.icns"
if [[ -f "$icon" ]]; then
    cp "$icon" "$app/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
fi
codesign --force --sign - --timestamp=none "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    dest="$HOME/Applications/KDE Connect Native.app"
    pkill -x KDEConnectNative || true
    mkdir -p "$HOME/Applications"
    rm -rf "$dest"
    cp -R "$app" "$dest"
    open "$dest"
    echo "Installed $dest"
fi
