import KDEConnectKit
import SwiftUI

/// The menu bar menu: a plain NSMenu with one submenu per paired device.
struct StatusMenu: View {
    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        if store.status != .connected {
            Text(statusText)
        }
        ForEach(store.pairingRequests) { device in
            let id = device.id
            Button("Accept Pairing from \(device.name)") {
                store.perform("Accept pairing") { try await $0.acceptPairing(id) }
            }
        }
        ForEach(store.pairedDevices) { device in
            if device.isReachable {
                Menu(menuTitle(device)) { DeviceMenu(device: device) }
            } else {
                Button("\(device.name) (not reachable)") { show(device) }
            }
        }
        Divider()
        Button("Open KDE Connect") { WindowOpener.shared.showMainWindow() }
        Button("Pair Device…") {
            WindowOpener.shared.showMainWindow()
            store.isPairingSheetShown = true
        }
        .disabled(store.status != .connected)
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit KDE Connect Native") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch store.status {
        case .connected: ""
        case .starting: "Starting KDE Connect…"
        case .daemonStopped: "KDE Connect is not running"
        case .notInstalled: "KDE Connect.app is missing"
        }
    }

    private func menuTitle(_ device: Device) -> String {
        guard let battery = device.battery else { return device.name }
        return "\(device.name) — \(battery.charge)%\(battery.isCharging ? " ⚡︎" : "")"
    }

    private func show(_ device: Device) {
        store.selectedDeviceId = device.id
        WindowOpener.shared.showMainWindow()
    }
}

private struct DeviceMenu: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device

    var body: some View {
        let id = device.id
        if device.has(.findMyPhone) {
            Button("Ring") { store.perform("Ring") { try await $0.ring(id) } }
        }
        if device.has(.ping) {
            Button("Ping") { store.perform("Ping") { try await $0.ping(id) } }
        }
        if device.has(.clipboard) {
            Button("Send Clipboard") { store.perform("Send clipboard") { try await $0.sendClipboard(id) } }
        }
        if device.has(.share) {
            Button("Send Files…") { FileSender.choose(for: device, store: store) }
        }
        if device.has(.sms) {
            Button("Messages…") {
                store.selectedDeviceId = id
                WindowOpener.shared.showMainWindow()
                Task {
                    await store.contacts(for: id).requestAccess()
                    // The pop-up needs its button in a window on screen.
                    try? await Task.sleep(for: .milliseconds(400))
                    store.messagesDeviceId = id
                }
            }
        }
        Divider()
        Button("Show Details") {
            store.selectedDeviceId = id
            WindowOpener.shared.showMainWindow()
        }
    }
}

enum FileSender {
    @MainActor
    static func choose(for device: Device, store: KDEConnectStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(device.name)"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        send(panel.urls, to: device, store: store)
    }

    @MainActor
    static func send(_ urls: [URL], to device: Device, store: KDEConnectStore) {
        store.sendFiles(urls, to: device.id)
    }
}
