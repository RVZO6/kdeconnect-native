import KDEConnectKit
import SwiftUI

/// The main window. It replaces the stock kdeconnect-app window.
struct MainWindow: View {
    static let id = "main"

    @Environment(KDEConnectStore.self) private var store
    @State private var sidebarShown = true
    /// The width the user dragged the sidebar to.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 250

    static let sidebarWidthRange: ClosedRange<Double> = 200...340

    var body: some View {
        let _ = UIBenchmark.recordUpdate("MainWindow")
        @Bindable var store = store
        // Two columns of our own instead of NavigationSplitView: AppKit's
        // split view animates the sidebar itself, lays the page out only at
        // the end (so it jumps), and moves the sidebar's toolbar items into
        // the overflow menu when it collapses. Here SwiftUI animates the
        // sidebar width, so the page moves with it on every frame.
        HStack(spacing: 0) {
            Sidebar(selection: $store.selectedDeviceId)
                .frame(width: sidebarWidth)
                // The sidebar slides out to the left while its column shrinks.
                .frame(width: sidebarShown ? sidebarWidth : 0, alignment: .trailing)
                .clipped()
                // After the clip, so that the material also fills the strip
                // under the toolbar, as a system sidebar does.
                .background { SidebarMaterial().ignoresSafeArea() }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .ignoresSafeArea()
                        .opacity(sidebarShown ? 1 : 0)
                }
                .overlay(alignment: .trailing) {
                    if sidebarShown { SidebarResizeHandle(width: $sidebarWidth, range: Self.sidebarWidthRange) }
                }
                // Above the page, so the handle's half over the page edge
                // still receives the drag.
                .zIndex(1)
                .accessibilityHidden(!sidebarShown)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Content runs up under the glass toolbar, as in the system apps.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .toolbar {
            // In the window's toolbar, not in a split column, so the
            // buttons keep their place and never go to the overflow menu.
            ToolbarItem(placement: .navigation) {
                SidebarControls(shown: $sidebarShown)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // The device page shows the device name in its header, so the
        // toolbar does not repeat it. The window keeps a title for Mission
        // Control and the Window menu.
        // Wide enough for the sidebar and one form column, and no larger than
        // the content uses: the form column (704 pt) with margins and the
        // sidebar, and a height that shows a full page without empty space.
        .frame(minWidth: 720, idealWidth: 900, maxWidth: 1000, minHeight: 480, idealHeight: 620, maxHeight: 780)
        .navigationTitle(store.selectedDevice?.name ?? "KDE Connect")
        .toolbar(removing: .title)
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarRequest)) { _ in
            SidebarAnimator.shared.toggle($sidebarShown)
        }
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
        .confirmationDialog("Unpair \(unpairCandidate?.name ?? "")?", isPresented: unpairShown, presenting: unpairCandidate) { device in
            let id = device.id
            Button("Unpair", role: .destructive) { store.perform("Unpair") { try await $0.unpair(id) } }
        } message: { _ in
            Text("You must pair again before the devices can connect.")
        }
        // The system's bottom edge effect draws a line only while the window
        // is inactive. Our own bar draws one line in both states instead.
        .scrollEdgeEffectHidden(true, for: .bottom)
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
        // The same material as the sidebar, so rows that scroll under the
        // bar stay hidden, and a separator line above it.
        .background { SidebarMaterial() }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        let _ = UIBenchmark.recordUpdate("DeviceRow")
        // Not a Label: a Label aligns its icon to the first text line, which
        // puts the tile above the middle of the two-line row.
        HStack(alignment: .center, spacing: 8) {
            IconTile(symbol: device.kind.symbol, color: device.kind.tint, size: 24, muted: !device.isReachable)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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

/// The system sidebar material behind our own sidebar column.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A thin strip on the sidebar's edge that resizes it, as a split view
/// divider does: the resize cursor on hover, the width follows the drag.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .accessibilityHidden(true)
    }
}
