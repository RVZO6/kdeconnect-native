#!/usr/bin/env bash
# Build a self-contained Apple Silicon alpha archive for GitHub distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
    echo "Release tag $RELEASE_TAG does not match VERSION ($version)" >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Release packaging requires an Apple Silicon Mac." >&2
    exit 1
fi
# Include the matching upstream source and its license texts with the release.
source Scripts/kdeconnect-version.env
mkdir -p build/release
source_archive="build/release/kdeconnect-kde-$KDECONNECT_VERSION.tar.xz"
curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
    "$KDECONNECT_SOURCE_URL" --output "$source_archive"
printf '%s  %s\n' "$KDECONNECT_SOURCE_SHA256" "$source_archive" | shasum -a 256 --check --status
Scripts/build-app.sh --bundle-kdeconnect
app="build/KDE Connect Native.app"
mkdir -p "$app/Contents/Resources/UpstreamLicenses"
tar -xf "$source_archive" -C "$app/Contents/Resources/UpstreamLicenses" \
    --strip-components 2 "kdeconnect-kde-$KDECONNECT_VERSION/LICENSES"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# Keep the release label and bundle versions consistent.
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "${version%%-*}"
archive="KDE-Connect-Native-$version-macos-arm64.zip"
mkdir -p build/release
ditto -c -k --sequesterRsrc --keepParent "$app" "build/release/$archive"
(cd build/release && shasum -a 256 "$archive" "kdeconnect-kde-$KDECONNECT_VERSION.tar.xz" > "$archive.sha256")
printf 'Packaged build/release/%s\n' "$archive"
