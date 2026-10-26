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
# Compile the Icon Composer document into Assets.car and AppIcon.icns.
partial="$(mktemp -t kdeconnect-icon)"
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$partial" >/dev/null
rm -f "$partial"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
    -c "Add :CFBundleIconName string AppIcon" "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    dest="$HOME/Applications/KDE Connect Native.app"
    pkill -x KDEConnectNative || true
    # Opening the app while the old instance still quits fails with error -600.
    for _ in {1..50}; do pgrep -x KDEConnectNative >/dev/null || break; sleep 0.1; done
    mkdir -p "$HOME/Applications"
    rm -rf "$dest"
    cp -R "$app" "$dest"
    open "$dest"
    echo "Installed $dest"
fi
