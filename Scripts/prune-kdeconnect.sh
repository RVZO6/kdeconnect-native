#!/usr/bin/env bash
# Removes the parts of a copied upstream KDE Connect.app that kdeconnectd,
# dbus-daemon and kdeconnect-sms do not use, then signs the bundle seal again.
# Each remaining binary keeps its upstream signature, so library validation
# still passes. Usage: Scripts/prune-kdeconnect.sh <path to KDE Connect.app>
set -euo pipefail

helper="$(cd "$1" && pwd)"
contents="$helper/Contents"
test -x "$contents/MacOS/kdeconnectd"
cd "$contents"

# Qt and CMake build tools, and the Qt UIs that this app replaces.
for tool in cmake_automoc_parser moc qlalr qmlaotstats qmlcachegen qmlimportscanner \
    qmljsrootgen qmltyperegistrar qvkgen rcc syncqt tracegen tracepointgen uic kdeconnect-app; do
    rm -f "MacOS/$tool"
done

# This app is English only, so keep only the English translations.
find Resources/locale -mindepth 1 -maxdepth 1 ! -name en -exec rm -rf {} +
find Resources/Translations -type f ! -name '*_en.qm' -delete

# Qt plugins that nothing loads. The darwin multimedia backend stays, so the
# ffmpeg libraries become unused.
rm -rf PlugIns/qmlls PlugIns/generic \
    PlugIns/multimedia/libffmpegmediaplugin.dylib \
    PlugIns/texttospeech/libqtexttospeech_mock.dylib

# QML modules and styles that kdeconnect-sms and the presenter plugin do not
# import. The macOS style falls back to Fusion, so Basic, Fusion and macOS
# stay. Both presenter pointer effects import QtQuick.Particles.
rm -rf Resources/qml/QtTest Resources/qml/QmlTime \
    Resources/qml/QtQuick/{VectorImage,LocalStorage,tooling} \
    Resources/qml/QtQuick/Controls/{FluentWinUI3,Imagine,Material,Universal,iOS,designer} \
    Resources/qml/Qt/labs/{StyleKit,wavefrontmesh} \
    Resources/qml/org/kde/kirigami/styles/Material

# Remove the libraries that no remaining binary links. Removing one library
# can make others unused, so repeat until nothing changes.
linked_names() {
    find MacOS Frameworks PlugIns Resources/qml -type f \
        \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 |
        xargs -0 otool -L 2>/dev/null |
        sed -nE 's|^[[:space:]]+[^ ]*/Frameworks/([^/ ]+).*|\1|p' | sort -u
}
while true; do
    keep="$(linked_names)"
    # A linked symlink keeps the file that it points to.
    for name in $keep; do
        target="Frameworks/$name"
        while [[ -L "$target" ]]; do
            target="Frameworks/$(readlink "$target")"
            keep+=$'\n'"$(basename "$target")"
        done
    done
    removed=false
    # Other entries, such as ossl-modules, are data that libraries load by path.
    for entry in Frameworks/*.dylib Frameworks/*.framework; do
        if ! grep -qxF "$(basename "$entry")" <<<"$keep"; then
            rm -rf "$entry"
            removed=true
        fi
    done
    "$removed" || break
done

codesign --force --sign - --timestamp=none "$helper"
