import KDEConnectKit
import SwiftUI

/// The main window. It replaces the stock kdeconnect-app window.
struct MainWindow: View {
    static let id = "main"

    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        let _ = UIBenchmark.recordUpdate("MainWindow")
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(selection: $store.selectedDeviceId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
                // The sidebar's toolbar declares its own sidebar button, so
                // that it comes first and the + follows it. With the system
                // button, SwiftUI reorders the items on every toggle and
                // they flash.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                // Content runs up under the glass toolbar, as in the system apps.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        // The device page shows the device name in its header, so the
        // toolbar does not repeat it. The window keeps a title for Mission
        // Control and the Window menu.
        .navigationTitle(store.selectedDevice?.name ?? "KDE Connect")
        .toolbar(removing: .title)
        .sheet(isPresented: $store.isPairingSheetShown) {
            PairingSheet()
        }
        .alert("KDE Connect", isPresented: errorShown) {
            Button("OK") { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
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

    private var errorShown: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })
    }
}

private struct Sidebar: View {
    @Environment(KDEConnectStore.self) private var store
    @Binding var selection: String?
    @State private var unpairCandidate: Device?

    var body: some View {
        let _ = UIBenchmark.recordUpdate("Sidebar")
        let groups = deviceGroups
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.devices) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("Toggle Sidebar", systemImage: "sidebar.left") {
                    // The same action as the system button, so it goes
                    // through SidebarToggleQueue.
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .help("Show or hide the sidebar")
            }
            // Next to the sidebar button, like a "new" button in an app's sidebar.
            ToolbarItem {
                Button("New Device", systemImage: "plus") { store.isPairingSheetShown = true }
                    .help("Pair a new device")
                    .disabled(store.status != .connected)
            }
        }
        .confirmationDialog("Unpair \(unpairCandidate?.name ?? "")?", isPresented: unpairShown, presenting: unpairCandidate) { device in
            let id = device.id
            Button("Unpair", role: .destructive) { store.perform("Unpair") { try await $0.unpair(id) } }
        } message: { _ in
            Text("You must pair again before the devices can connect.")
        }
        .safeAreaBar(edge: .bottom) {
            ThisMacBar()
        }
    }

    /// The non-empty device sections, in display order.
    private var deviceGroups: [(title: String, devices: [Device])] {
        [
            ("Pairing Requests", store.pairingRequests),
            ("Connected", store.pairedDevices.filter(\.isReachable)),
            ("Remembered", store.pairedDevices.filter { !$0.isReachable }),
            ("Available", store.availableDevices),
        ]
        .filter { !$0.devices.isEmpty }
    }

    private func row(_ device: Device) -> some View {
        DeviceRow(device: device)
            .swipeActions(edge: .leading) {
                if device.isReachable, device.has(.findMyPhone) {
                    let id = device.id
                    Button("Ring", systemImage: "speaker.wave.3") { store.perform("Ring") { try await $0.ring(id) } }
                        .tint(.accentColor)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if device.isPaired {
                    Button("Unpair", systemImage: "link.badge.minus", role: .destructive) { unpairCandidate = device }
                }
            }
    }

    private var unpairShown: Binding<Bool> {
        Binding(get: { unpairCandidate != nil }, set: { if !$0 { unpairCandidate = nil } })
    }
}

/// This Mac's name and the settings button, at the bottom of the sidebar.
private struct ThisMacBar: View {
    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        HStack {
            Label {
                Text(store.announcedName.isEmpty ? "This Mac" : store.announcedName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        let _ = UIBenchmark.recordUpdate("DeviceRow")
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
    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("No Device Selected", systemImage: "iphone")
        } description: {
            Text("Select a device in the sidebar, or pair a new one. "
                 + "The other device needs the KDE Connect app.")
        } actions: {
            VStack(spacing: 14) {
                Button("Pair New Device…", systemImage: "plus") { store.isPairingSheetShown = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                GlassEffectContainer {
                    HStack {
                        Link("F-Droid", destination: URL(string: "https://f-droid.org/packages/org.kde.kdeconnect_tp/")!)
                        Link("Google Play",
                             destination: URL(string: "https://play.google.com/store/apps/details?id=org.kde.kdeconnect_tp")!)
                        Link("iOS", destination: URL(string: "https://kdeconnect.kde.org/download.html")!)
                    }
                    .buttonStyle(.glass)
                }
            }
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
                    .buttonStyle(.glassProminent)
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
