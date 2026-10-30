#!/usr/bin/env bash
# Builds "KDE Connect Native.app" into ./build. Pass --install to copy it to
# ~/Applications and restart it.
set -euo pipefail

cd "$(dirname "$0")/.."
install=false
bundle=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        --bundle-kdeconnect) bundle=true ;;
        *) echo "Usage: $0 [--install] [--bundle-kdeconnect]" >&2; exit 2 ;;
    esac
done
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
# actool resolves relative paths in a helper process with another working
# directory, so pass absolute ones. Its plist goes to stdout; errors show.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$partial" >/dev/null
rm -f "$partial"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
    -c "Add :CFBundleIconName string AppIcon" "$app/Contents/Info.plist"
# Copy the upstream bundle, then remove what the daemon does not use. The
# remaining binaries keep their upstream signatures. Do not use codesign
# --deep to re-sign third-party code.
if "$bundle"; then
    upstream="${KDECONNECT_APP_PATH:-}"
    if [[ -z "$upstream" ]]; then upstream="$(Scripts/fetch-kdeconnect.sh)"; fi
    for executable in kdeconnectd dbus-daemon; do
        test -x "$upstream/Contents/MacOS/$executable"
    done
    test -f "$upstream/Contents/Resources/dbus-1/session.conf"
    codesign --verify --deep --strict "$upstream"
    mkdir -p "$app/Contents/Helpers"
    ditto "$upstream" "$app/Contents/Helpers/KDE Connect.app"
    Scripts/prune-kdeconnect.sh "$app/Contents/Helpers/KDE Connect.app"
    cp Resources/ThirdPartyNotices.txt "$app/Contents/Resources/"
fi
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"

if "$install"; then
    dest="$HOME/Applications/KDE Connect Native.app"
    pkill -x KDEConnectNative || true
    # Opening the app while the old instance still quits fails with error -600.
    for _ in {1..50}; do pgrep -x KDEConnectNative >/dev/null || break; sleep 0.1; done
    mkdir -p "$HOME/Applications"
    rm -rf "$dest"
    cp -R "$app" "$dest"
    # LaunchServices can still refuse right after a replace (-600); try again.
    launched=false
    for _ in 1 2 3; do
        if open "$dest"; then
            launched=true
            break
        fi
        sleep 1
    done
    if ! "$launched"; then
        echo "Installed $dest, but could not open it after three attempts" >&2
        exit 1
    fi
    echo "Installed and opened $dest"
fi
