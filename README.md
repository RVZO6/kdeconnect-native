# KDE Connect Native

A native SwiftUI menu bar app for KDE Connect on macOS. It replaces the Qt
indicator, but keeps the official `kdeconnectd` daemon from
`/Applications/KDE Connect.app`. The protocol, pairing and plugins stay
upstream code. This app is only the UI and a supervisor.

## Why

The stock macOS indicator can lose its link to the daemon. The cause is the
macOS bootstrap. KDE Connect does not use a system session bus on macOS:

1. The launcher starts a private `dbus-daemon --address unix:tmpdir=/tmp`.
2. It writes the bus address to `/tmp/private_dbus_address`.
3. It starts `kdeconnectd` with that bus in its environment.

When the daemon or the bus restarts, the address changes. Clients that stay
on the old bus look "de-attached", and old `dbus-daemon` processes stay
behind. This app reads the address file again on every check, reconnects,
and restarts the daemon when it is missing or on a dead bus.

## Features

- Menu bar icon with the phone battery level.
- Per device: battery, cellular network type, Ring, Ping, Send clipboard,
  Send files (button or drag and drop onto the device card).
- Phone notifications: list, dismiss and reply.
- Pair, accept and reject pairing requests. Unpair from the context menu.
- Supervisor: starts `kdeconnectd` when it is missing, and restarts it with a
  fresh bus when its bus is gone. Asks for a new network announcement after
  wake. "Restart KDE Connect Service" also removes stale buses.
- Opens the stock KDE Connect settings and SMS apps on the correct bus.
- Open at login.

## Requirements

- macOS 14 or later.
- KDE Connect.app (the official build) in `/Applications`. Tested with 26.08.

## Build and install

```sh
Scripts/build-app.sh            # builds "build/KDE Connect Native.app"
Scripts/build-app.sh --install  # also copies it to ~/Applications and opens it
swift test                      # D-Bus marshalling tests
```

Then remove the stock "KDE Connect" from **System Settings → General → Login
Items**, and turn on "Open at login" in this app's settings. The stock
indicator can run at the same time, but then two menu bar icons show.

## Design

| Module | Contents |
| --- | --- |
| `DBusKit` | Small pure-Swift D-Bus client: wire format, SASL EXTERNAL auth, method calls, signals. No libdbus. |
| `KDEConnectKit` | Typed `kdeconnectd` API (`KDEConnectClient`), process control (`DaemonProcess`), and the observable app state with the supervisor loop (`KDEConnectStore`). |
| `KDEConnectNative` | The SwiftUI menu bar app. |
| `dbus-probe` | Development tool: `dbus-probe introspect <path>` and `dbus-probe call <path> <iface> <member> [args]`. |

The app starts `kdeconnectd` and `dbus-daemon` with `posix_spawn` and
disclaims responsibility for them. macOS then applies the privacy permissions
(Bluetooth, local network) of KDE Connect.app, not of this app. Without
this, TCC stops `kdeconnectd` because this app does not declare Bluetooth use.

## Debugging

- Supervisor log: `log stream --predicate 'subsystem == "app.kdeconnect-native"' --info`
- Daemon output: `~/Library/Logs/KDEConnectNative/kdeconnectd.log`
- Render the menu panel to a PNG: `"build/KDE Connect Native.app/Contents/MacOS/KDEConnectNative" --snapshot /tmp/menu.png`
