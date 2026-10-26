import KDEConnectKit
import SwiftUI

/// The main window. It replaces the stock kdeconnect-app window.
struct MainWindow: View {
    static let id = "main"

    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(selection: $store.selectedDeviceId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if store.status != .connected {
                ServiceUnavailableView()
            } else if let device = store.selectedDevice {
                // A new identity per device, so that view state such as a
                // reply draft never moves to another device.
                DeviceDetail(device: device)
                    .id(device.id)
            } else {
                NoDeviceSelectedView()
            }
        }
        .navigationTitle(store.selectedDevice?.name ?? "KDE Connect")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { store.refreshNetwork() }
                    .help("Search for devices on all networks again")
                    .disabled(store.status != .connected)
            }
        }
        .alert("KDE Connect", isPresented: errorShown) {
            Button("OK") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            WindowOpener.shared.isMainWindowVisible = true
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            // Without a window, the app lives only in the menu bar again.
            WindowOpener.shared.isMainWindowVisible = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })
    }
}

private struct Sidebar: View {
    @Environment(KDEConnectStore.self) private var store
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if !store.pairingRequests.isEmpty {
                Section("Pairing Requests") {
                    ForEach(store.pairingRequests) { DeviceRow(device: $0) }
                }
            }
            let connected = store.pairedDevices.filter(\.isReachable)
            if !connected.isEmpty {
                Section("Connected") {
                    ForEach(connected) { DeviceRow(device: $0) }
                }
            }
            let remembered = store.pairedDevices.filter { !$0.isReachable }
            if !remembered.isEmpty {
                Section("Remembered") {
                    ForEach(remembered) { DeviceRow(device: $0) }
                }
            }
            if !store.availableDevices.isEmpty {
                Section("Available") {
                    ForEach(store.availableDevices) { DeviceRow(device: $0) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.status == .connected && store.devices.isEmpty {
                ContentUnavailableView("No Devices", systemImage: "iphone.slash",
                                       description: Text("Open KDE Connect on your other devices."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    Text(store.announcedName.isEmpty ? "This Mac" : store.announcedName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Settings")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: device.kind.symbol)
        }
        .tag(device.id)
    }

    private var status: String {
        if device.isPairRequestedByPeer { return "Wants to pair" }
        if !device.isPaired { return device.isPairRequested ? "Waiting for pairing…" : "Not paired" }
        guard device.isReachable else { return "Not reachable" }
        if let battery = device.battery {
            return "Connected · \(battery.charge)%\(battery.isCharging ? ", charging" : "")"
        }
        return "Connected"
    }
}

private struct NoDeviceSelectedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Device Selected", systemImage: "iphone")
        } description: {
            Text("Install KDE Connect on your other devices, then select one in the sidebar.")
        } actions: {
            HStack {
                Link("F-Droid", destination: URL(string: "https://f-droid.org/packages/org.kde.kdeconnect_tp/")!)
                Link("Google Play",
                     destination: URL(string: "https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp")!)
                Link("iOS", destination: URL(string: "https://kdeconnect.kde.org/download.html")!)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ServiceUnavailableView: View {
    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: store.status == .starting ? "hourglass" : "exclamationmark.triangle")
        } description: {
            Text(detail)
        } actions: {
            if store.status == .daemonStopped {
                Button("Restart KDE Connect Service") { Task { await store.restartDaemon() } }
            }
        }
    }

    private var title: String {
        switch store.status {
        case .connected, .starting: "Starting KDE Connect…"
        case .daemonStopped: "KDE Connect Is Not Running"
        case .notInstalled: "KDE Connect Is Not Installed"
        }
    }

    private var detail: String {
        switch store.status {
        case .connected, .starting: "Waiting for the KDE Connect service."
        case .daemonStopped:
            store.autoStartDaemon ? "The service will start again in a moment." : "Automatic start is off in Settings."
        case .notInstalled: "This app uses the service from KDE Connect.app. Install it in the Applications folder."
        }
    }
}
