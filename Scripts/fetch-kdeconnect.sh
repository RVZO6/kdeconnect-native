#!/usr/bin/env bash
# Prints the path to a verified, extracted upstream app. Diagnostics go to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/kdeconnect-version.env
cache="${KDECONNECT_CACHE_DIR:-$PWD/build/upstream}"
mkdir -p "$cache"
cache="$(cd "$cache" && pwd)"
dmg="$cache/$KDECONNECT_DMG_SHA256.dmg"

verify() {
    printf '%s  %s\n' "$KDECONNECT_DMG_SHA256" "$dmg" | shasum -a 256 --check --status
}

# Verify cache hits too. Never extract a partial or changed download.
if [[ ! -f "$dmg" ]] || ! verify; then
    temp="$(mktemp "$cache/download.XXXXXX")"
    trap 'rm -f "$temp"' EXIT
    curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
        "$KDECONNECT_DMG_URL" --output "$temp" >&2
    printf '%s  %s\n' "$KDECONNECT_DMG_SHA256" "$temp" | shasum -a 256 --check --status
    mv -f "$temp" "$dmg"
    trap - EXIT
fi

# Always extract from the verified image, not from a mutable extracted cache.
mount="$(mktemp -d)"
staging="$(mktemp -d "$cache/extract.XXXXXX")"
cleanup() {
    hdiutil detach "$mount" -quiet >&2 || true
    rmdir "$mount" 2>/dev/null || true
    rm -rf "$staging"
}
trap cleanup EXIT
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" -quiet >&2
ditto "$mount/KDE Connect.app" "$staging/KDE Connect.app"
app="$staging/KDE Connect.app"
for executable in kdeconnectd dbus-daemon; do
    test -x "$app/Contents/MacOS/$executable"
done
test -f "$app/Contents/Resources/dbus-1/session.conf"
test -d "$app/Contents/Resources/licenses"
codesign --verify --deep --strict "$app" >&2
rm -rf "$cache/KDE Connect.app"
mv "$app" "$cache/KDE Connect.app"
printf '%s\n' "$cache/KDE Connect.app"
