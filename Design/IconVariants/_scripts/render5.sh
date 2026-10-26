#!/usr/bin/env bash
# Render the finals with ictool and actool, then build contact-final.png (a-c) and contact-final-2.png (d-f).
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$S/.." && pwd)"
ICT="${ICTOOL:-$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool}"
TMP="$S/actool-work"

actool_png() { # $1 = .icon path, $2 = output png
  rm -rf "$TMP"; mkdir -p "$TMP/out"
  cp -R "$1" "$TMP/AppIcon.icon"
  xcrun actool "$TMP/AppIcon.icon" --compile "$TMP/out" --platform macosx --minimum-deployment-target 27.0 \
    --app-icon AppIcon --output-partial-info-plist "$TMP/out/p.plist" >/dev/null
  sips -s format png "$TMP/out/AppIcon.icns" --out "$2" -Z 512 >/dev/null
}

mkdir -p "$S/actool-ref"
for ref in v25b3-r4-graded-out v25b3-r4-gap-out v25b3-r4-two-bold; do
  actool_png "$OUT/$ref.icon" "$S/actool-ref/$ref-actool.png"
done
for v in a b c d e f; do
  n="v25b3-final-$v"
  "$ICT" "$OUT/$n.icon" --export-image --output-file "$OUT/renders/$n-default.png" --platform macOS --rendition Default --width 512 --height 512 --scale 1 >/dev/null
  "$ICT" "$OUT/$n.icon" --export-image --output-file "$OUT/renders/$n-dark.png" --platform macOS --rendition Dark --width 256 --height 256 --scale 1 >/dev/null
  actool_png "$OUT/$n.icon" "$OUT/renders/$n-actool.png"
  for f in "$OUT/renders/$n-default.png" "$OUT/renders/$n-dark.png" "$OUT/renders/$n-actool.png"; do
    [ -s "$f" ] || { echo "EMPTY: $f" >&2; exit 1; }
  done
done
rm -rf "$TMP"
R="$OUT/renders"; A="$S/actool-ref"
cd "$S"
swift sheet.swift "$OUT/contact-final.png" 5 300 \
  "$R/v25b3-r4-graded-out-default.png" "$R/v25b3-r4-gap-out-default.png" "$R"/v25b3-final-{a,b,c}-default.png \
  "$A/v25b3-r4-graded-out-actool.png" "$A/v25b3-r4-gap-out-actool.png" "$R"/v25b3-final-{a,b,c}-actool.png
swift sheet.swift "$OUT/contact-final-2.png" 4 300 \
  "$R/v25b3-r4-two-bold-default.png" "$R"/v25b3-final-{d,e,f}-default.png \
  "$A/v25b3-r4-two-bold-actool.png" "$R"/v25b3-final-{d,e,f}-actool.png
