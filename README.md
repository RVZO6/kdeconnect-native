# KDE Connect Native

A native SwiftUI app for KDE Connect on macOS. It replaces the Qt window
(`kdeconnect-app`) and the Qt menu bar indicator, but keeps the official
`kdeconnectd` daemon from
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

- **Main window** (replaces `kdeconnect-app`): devices in a sidebar
  (connected, remembered, available, pairing requests), with "Pair New
  Device…" as the last row and swipe actions (Ring, Unpair). The device
  page has a header with status, battery, a refresh button and the actions
  (glass buttons: Ring, Ping, Send clipboard, Send files, Messages), then
  tabs: Overview (notification cards: swipe a card off to either side with
  two fingers to dismiss it; reply on hover or from the context menu),
  Plugins (switches and settings) and Details. Drop files on the window to
  send them.
- **Plugin settings**: the gear next to a plugin opens its settings, the
  same set as the stock app: clipboard (auto share, passwords, file size),
  share (download folder), run commands (commands that devices can run on
  this Mac) and presentation pointer.
- **Pairing**: "Pair Device…" (⌘N, toolbar, menu bar) lists devices nearby,
  adds a device by IP address, and shows this Mac's addresses. A pairing
  request from a device shows an Accept/Reject alert.
- **Settings window**: this Mac's device name, open at login, connection
  types (LAN, Bluetooth), device addresses for networks without discovery
  (for example Tailscale), and service supervision.
- **Menu bar**: a plain native menu with one submenu per device.
- **Supervisor**: starts `kdeconnectd` when it is missing, and restarts it
  with a fresh bus when its bus is gone. Asks for a new network announcement
  after wake.
- A manual launch opens the window. A launch at login stays in the menu bar.

## Requirements

- macOS 27 or later.
- KDE Connect.app (the official build) in `/Applications`. Tested with 26.08.

## Build and install

```sh
Scripts/build-app.sh            # builds "build/KDE Connect Native.app"
Scripts/build-app.sh --install  # also copies it to ~/Applications and opens it
swift test                      # unit and regression tests
```

Then remove the stock "KDE Connect" from **System Settings → General → Login
Items**, and turn on "Open at login" in this app's settings. Do not run the
stock indicator or `kdeconnect-app` at the same time.

## Design

| Module | Contents |
| --- | --- |
| `DBusKit` | Small pure-Swift D-Bus client: wire format, SASL EXTERNAL auth, method calls, signals. No libdbus. |
| `KDEConnectKit` | Typed `kdeconnectd` API (`KDEConnectClient`), process control (`DaemonProcess`), and the observable app state with the supervisor loop (`KDEConnectStore`). |
| `KDEConnectNative` | The SwiftUI app: main window, settings and menu bar menu. |
| `dbus-probe` | Development tool: `dbus-probe introspect <path>` and `dbus-probe call <path> <iface> <member> [args]`. |

The app starts `kdeconnectd` and `dbus-daemon` with `posix_spawn` and
disclaims responsibility for them. macOS then applies the privacy permissions
(Bluetooth, local network) of KDE Connect.app, not of this app. Without
this, TCC stops `kdeconnectd` because this app does not declare Bluetooth use.

## Debugging

- Supervisor log: `log stream --predicate 'subsystem == "app.kdeconnect-native"' --info`
- Daemon output: `~/Library/Logs/KDEConnectNative/kdeconnectd.log`
- Print the sidebar position while it toggles (one toggle, then a fast burst): `"build/KDE Connect Native.app/Contents/MacOS/KDEConnectNative" --sidebar-test`
- Save an image of the real window, title bar included: `"build/KDE Connect Native.app/Contents/MacOS/KDEConnectNative" --window-snapshot /tmp/window.png`
- Fill the window with a sample connected phone, without the daemon: add `--demo` (for example with `--window-snapshot`, which also saves a capture with the page scrolled)
- Post a synthetic two-finger swipe each way over the first notification and save captures: `--demo --swipe-test /tmp/swipe`
- Expand and collapse the notification stacks and save frames during the animation: `--demo --stack-test /tmp/stack`
- Drag the sidebar edge with posted mouse events, then open Settings and print the window levels: `--demo --resize-test`
- Switch the device tabs and print the main-thread layout and draw time of each switch: `--demo --tab-test`
- Print which view a click in the toolbar row reaches over the page centre: `--demo --hit-test`
- Render the main window to a PNG: `"build/KDE Connect Native.app/Contents/MacOS/KDEConnectNative" --snapshot /tmp/window.png`
- Run the scrolling workload without a daemon: add `--demo --demo-notifications 300 --demo-apps 20 --ui-benchmark /tmp/ui.json`
- See [performance measurements and test commands](Benchmarks/README.md).
