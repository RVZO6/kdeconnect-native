Early alpha of the native SwiftUI front end for KDE Connect.

## Requirements and installation

- Apple Silicon Mac with macOS 27 or later. Intel Macs are not supported by this build.
- Download and extract the ZIP. Move **KDE Connect Native.app** to Applications before opening it.
- The official pre-built KDE Connect app is included. No separate KDE Connect installation is required.
- Remove the stock KDE Connect app from Login Items. Do not run its indicator or daemon at the same time.
- Install KDE Connect on the other device, then pair it with this Mac.

This alpha is ad-hoc signed, not Developer ID signed or notarized. macOS can
block the download. If you trust this release, use **System Settings → Privacy
& Security → Open Anyway** after the first launch attempt. Do not disable
Gatekeeper for the whole system.

Expect bugs. This is not an official KDE release. Upstream licenses and source
links are included in `Contents/Resources/ThirdPartyNotices.txt` and the nested
KDE Connect app. See `Scripts/kdeconnect-version.env` at this release tag for
the exact upstream version and SHA-256. The matching KDE Connect source archive and checksums are supplied beside the ZIP.
