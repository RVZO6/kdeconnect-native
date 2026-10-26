import KDEConnectKit
import SwiftUI

/// The page for one device: a header with status, then tabs for the
/// overview (actions and notifications), plugins and details.
struct DeviceDetail: View {
    enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case plugins = "Plugins"
        case details = "Details"
        var id: Self { self }
    }

    @Environment(KDEConnectStore.self) private var store
    let device: Device
    /// The selected tab. Only the page slots and the tab picker read it, so a
    /// switch does not re-evaluate and lay out the whole device view.
    @State private var selection = PageSelection()
    @State private var confirmUnpair = false
    @State private var dropTargeted = false
    @State private var settingsPlugin: PluginSheetItem?

    @Environment(\.displayScale) private var displayScale
    @State private var overviewScroll = ScrollPosition()

    var body: some View {
        let _ = UIBenchmark.recordUpdate("DeviceDetail")
        Group {
            if device.isPaired {
                // All three pages stay built; a switch only changes which one
                // shows. Rebuilding a page on every switch cost 50-75 ms on
                // the main thread, which showed as a stutter.
                ZStack {
                    PageSlot(selection: selection, page: .overview) { overviewPage }
                    PageSlot(selection: selection, page: .plugins) {
                        Form { pluginsSection }
                            .formStyle(.grouped)
                    }
                    PageSlot(selection: selection, page: .details) {
                        Form {
                            detailsSection
                            Section {
                                Button("Unpair \(device.name)…", role: .destructive) { confirmUnpair = true }
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
            } else {
                Form {
                    pairingSection
                    detailsSection
                }
                .formStyle(.grouped)
            }
        }
        // The header and the tabs stay at the top; the page scrolls under
        // them with the system scroll edge effect.
        // The tabs sit in the window toolbar, centred, apart from the
        // device header below it.
        .toolbar {
            if device.isPaired {
                ToolbarItem(placement: .principal) {
                    PagePicker(selection: selection)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugSelectPage)) { note in
            if let name = note.object as? String, let target = Page(rawValue: name) { selection.page = target }
        }
        .safeAreaBar(edge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if device.isPaired, device.isReachable {
                    actionsBar.frame(maxWidth: .infinity)
                }
            }
            // Same width and inset as the grouped form's rows, so the tile
            // lines up with the row content below.
            .padding(.horizontal, 11)
            .frame(maxWidth: 704)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            // The system draws a hairline under the bar. This one pixel, on
            // top of it in both states, makes the line clearer and keeps it
            // the same whether or not content is under the bar.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1 / displayScale)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard canShare else { return false }
            FileSender.send(urls, to: device, store: store)
            return true
        } isTargeted: { dropTargeted = $0 && canShare }
        .confirmationDialog("Unpair \(device.name)?", isPresented: $confirmUnpair) {
            let id = device.id
            Button("Unpair", role: .destructive) { store.perform("Unpair") { try await $0.unpair(id) } }
        } message: {
            Text("You must pair again before the devices can connect.")
        }
        .sheet(item: $settingsPlugin) { item in
            PluginSettingsSheet(device: device, plugin: item.id)
        }
    }

    /// Cards, not form rows, so that a card can be swiped off.
    private var overviewPage: some View {
        ScrollView {
            // Battery, plugin and header updates must not rebuild
            // an unchanged notification list.
            NotificationCards(deviceId: device.id, isReachable: device.isReachable,
                              notifications: device.notifications)
                .equatable()
                .frame(maxWidth: 704)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
        }
        .scrollPosition($overviewScroll)
        .onReceive(NotificationCenter.default.publisher(for: .debugScrollPage)) { _ in
            overviewScroll.scrollTo(y: 160)
        }
    }

    private var canShare: Bool { device.isReachable && device.has(.share) }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 16) {
            IconTile(symbol: device.kind.symbol, color: device.kind.tint, size: 44, muted: !device.isReachable)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name).font(.title.weight(.semibold)).lineLimit(1)
                    RefreshButton()
                }
                Text(statusLine).foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = device.battery {
                Label("\(battery.charge)%", systemImage: batterySymbol(battery))
                    .labelStyle(.titleAndIcon)
                    .font(.title3)
                    .foregroundStyle(battery.charge <= 15 && !battery.isCharging ? .red : .primary)
                    .help(battery.isCharging ? "Charging" : "On battery")
            }
        }
        .padding(.vertical, 2)
    }

    private var statusLine: String {
        if !device.isPaired { return device.isReachable ? "Not paired" : "Not paired, not reachable" }
        guard device.isReachable else { return "Not reachable" }
        var parts = ["Connected"]
        if !device.activeProviders.isEmpty { parts.append("via " + device.activeProviders.joined(separator: ", ")) }
        if let cellular = device.cellular { parts.append(cellular.networkType) }
        return parts.joined(separator: " · ")
    }

    private var pairingSection: some View {
        Section {
            let id = device.id
            if device.isPairRequestedByPeer {
                LabeledContent("\(device.name) wants to pair with this Mac.") {
                    HStack {
                        Button("Reject") { store.perform("Reject pairing") { try await $0.cancelPairing(id) } }
                            .buttonStyle(.glass)
                        Button("Accept") { store.perform("Accept pairing") { try await $0.acceptPairing(id) } }
                            .buttonStyle(.glassProminent)
                    }
                }
                verificationKeyRow
            } else if device.isPairRequested {
                LabeledContent("Waiting for \(device.name) to accept…") {
                    Button("Cancel") { store.perform("Cancel pairing") { try await $0.cancelPairing(id) } }
                        .buttonStyle(.glass)
                }
                verificationKeyRow
            } else {
                LabeledContent("This device is not paired.") {
                    Button("Request Pairing") { store.perform("Pair") { try await $0.requestPairing(id) } }
                        .buttonStyle(.glassProminent)
                        .disabled(!device.isReachable)
                }
            }
        } header: {
            Text("Pairing")
        }
    }

    /// The device actions as one row of glass buttons in the header bar,
    /// not in a card of their own.
    private var actionsBar: some View {
        let id = device.id
        // One container, so that the glass buttons blend and morph together.
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if device.has(.findMyPhone) {
                    ActionButton("Ring", symbol: "speaker.wave.3") {
                        store.perform("Ring") { try await $0.ring(id) }
                    }
                }
                if device.has(.ping) {
                    ActionButton("Ping", symbol: "dot.radiowaves.left.and.right") {
                        store.perform("Ping") { try await $0.ping(id) }
                    }
                }
                if device.has(.clipboard) {
                    ActionButton("Send Clipboard", symbol: "doc.on.clipboard") {
                        store.perform("Send clipboard") { try await $0.sendClipboard(id) }
                    }
                }
                if device.has(.share) {
                    ActionButton("Send Files…", symbol: "paperplane") { FileSender.choose(for: device, store: store) }
                        .help("Choose files to send. You can also drop files on this window.")
                }
                if device.has(.sms) {
                    ActionButton("Messages", symbol: "message") { store.openSMSApp() }
                }
            }
        }
    }

    private var pluginsSection: some View {
        Section {
            if device.supportedPlugins.isEmpty {
                Text("No plugins reported.").foregroundStyle(.secondary)
            }
            ForEach(sortedPlugins, id: \.self) { plugin in
                LabeledContent {
                    HStack(spacing: 10) {
                        // Every row keeps the gear's space, so that the
                        // switches stay in one column.
                        Button("Settings", systemImage: "gearshape") { settingsPlugin = PluginSheetItem(id: plugin) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("\(Plugin.displayName(for: plugin)) settings")
                            .opacity(PluginConfig.configurablePlugins.contains(plugin) ? 1 : 0)
                            .disabled(!PluginConfig.configurablePlugins.contains(plugin))
                            .accessibilityHidden(!PluginConfig.configurablePlugins.contains(plugin))
                        Toggle(Plugin.displayName(for: plugin), isOn: pluginBinding(plugin))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                } label: {
                    let tile = Plugin.tile(for: plugin)
                    Label {
                        Text(Plugin.displayName(for: plugin))
                    } icon: {
                        IconTile(symbol: tile.symbol, color: tile.color,
                                 muted: store.pluginStates[device.id]?[plugin] == false)
                    }
                }
            }
        } footer: {
            if store.pluginStates[device.id] == nil, !device.supportedPlugins.isEmpty {
                Text("Reading plugin states…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            if device.isPaired { verificationKeyRow }
            if !device.reachableAddresses.isEmpty {
                LabeledContent("Addresses", value: device.reachableAddresses.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            if !device.activeProviders.isEmpty {
                LabeledContent("Connection", value: device.activeProviders.joined(separator: ", "))
            }
            LabeledContent("Device ID") {
                Text(device.id).font(.body.monospaced()).textSelection(.enabled)
            }
        }
    }

    private var verificationKeyRow: some View {
        LabeledContent("Verification key") {
            Text(device.verificationKey.isEmpty ? "—" : device.verificationKey)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }

    // MARK: Helpers

    private var sortedPlugins: [String] {
        device.supportedPlugins.sorted {
            Plugin.displayName(for: $0).localizedCaseInsensitiveCompare(Plugin.displayName(for: $1)) == .orderedAscending
        }
    }

    /// Reads the store's cached state, so the switches show their real
    /// value from the first frame instead of flickering while loading.
    private func pluginBinding(_ plugin: String) -> Binding<Bool> {
        Binding {
            store.pluginStates[device.id]?[plugin] ?? false
        } set: { enabled in
            store.setPluginEnabled(deviceId: device.id, plugin: plugin, enabled: enabled)
        }
    }

    private func batterySymbol(_ battery: Device.Battery) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.charge {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct PluginSheetItem: Identifiable {
    let id: String
}

/// Reconnects and reads the device again. The arrow spins while it runs.
private struct RefreshButton: View {
    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        Button {
            store.refreshNetwork()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .symbolEffect(.rotate.clockwise.byLayer, options: .repeat(.continuous), isActive: store.isRefreshing)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help("Reconnect and refresh")
        .disabled(store.status != .connected)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .buttonStyle(.glass)
            .controlSize(.large)
    }
}

extension Notification.Name {
    /// Debug aid: scrolls the Overview page, so that captures can show
    /// content under the header bar.
    static let debugScrollPage = Notification.Name("KDEConnectNativeDebugScrollPage")
    /// Debug aid: selects a page of the device view by its name.
    static let debugSelectPage = Notification.Name("KDEConnectNativeDebugSelectPage")
    /// Debug aid: expands or collapses every notification stack.
    static let debugToggleStacks = Notification.Name("KDEConnectNativeDebugToggleStacks")
}

/// The selected tab of a device view.
@MainActor
@Observable
private final class PageSelection {
    var page: DeviceDetail.Page = .overview
}

/// One device page. It stays built while hidden; only this small view
/// updates when the tab changes, not the page inside it.
private struct PageSlot<Content: View>: View {
    let selection: PageSelection
    let page: DeviceDetail.Page
    @ViewBuilder let content: Content

    var body: some View {
        let visible = selection.page == page
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

private struct PagePicker: View {
    @Bindable var selection: PageSelection

    var body: some View {
        Picker("Page", selection: $selection.page) {
            ForEach(DeviceDetail.Page.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.tabs)
        .labelsHidden()
    }
}
