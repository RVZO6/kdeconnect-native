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
    @State private var drop = DropState()
    @State private var settingsPlugin: PluginSheetItem?

    @Environment(\.displayScale) private var displayScale
    /// Puts the tabs in the vertical middle of the toolbar row.
    private static let tabsTopInset: CGFloat = 11

    @State private var overviewScroll = ScrollPosition()

    var body: some View {
        let _ = UIBenchmark.recordUpdate("DeviceDetail")
        DropZone(drop: drop, deviceName: device.name) {
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
        // The tabs float over the toolbar row, centred on this page column
        // and apart from the device header. In our own content, not in the
        // toolbar, so the page moves them with the sidebar in one animation.
        .overlay(alignment: .top) {
            if device.isPaired {
                PagePicker(selection: selection)
                    .padding(.top, Self.tabsTopInset)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugDropTarget)) { note in
            withAnimation(.snappy(duration: 0.22)) { drop.isTargeted = note.object as? Bool ?? false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugSelectPage)) { note in
            if let name = note.object as? String, let target = Page(rawValue: name) { selection.page = target }
        }
        // The actions float at the bottom of the page, as icons in one
        // glass capsule; the page scrolls under them.
        .safeAreaBar(edge: .bottom) {
            if device.isPaired, device.isReachable {
                ActionsBar(device: device)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .safeAreaBar(edge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                header
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
        .dropDestination(for: URL.self) { urls, _ in
            guard canShare else { return false }
            FileSender.send(urls, to: device, store: store)
            return true
        } isTargeted: { targeted in
            // The same fade as a tab switch.
            withAnimation(.snappy(duration: 0.22)) { drop.isTargeted = targeted && canShare }
        }
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

extension Notification.Name {
    /// Debug aid: scrolls the Overview page, so that captures can show
    /// content under the header bar.
    static let debugScrollPage = Notification.Name("KDEConnectNativeDebugScrollPage")
    /// Debug aid: selects a page of the device view by its name.
    static let debugSelectPage = Notification.Name("KDEConnectNativeDebugSelectPage")
    /// Debug aid: shows the hover label of an action by its name, or hides it.
    static let debugHoverAction = Notification.Name("KDEConnectNativeDebugHoverAction")
    /// Debug aid: shows or hides the drop prompt, as a drag over the view would.
    static let debugDropTarget = Notification.Name("KDEConnectNativeDebugDropTarget")
    /// Debug aid: expands or collapses every notification stack.
    static let debugToggleStacks = Notification.Name("KDEConnectNativeDebugToggleStacks")
}

/// The selected tab of a device view.
@MainActor
@Observable
final class PageSelection {
    var page: DeviceDetail.Page = .overview
}

/// One device page. It stays built while hidden; only this small view
/// updates when the tab changes, not the page inside it.
struct PageSlot<Content: View>: View {
    let selection: PageSelection
    let page: DeviceDetail.Page
    @ViewBuilder let content: Content

    var body: some View {
        let visible = selection.page == page
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
    }
}

/// True while files are dragged over the device view.
@MainActor
@Observable
final class DropState {
    var isTargeted = false
}

/// The device pages, which fade out to a drop prompt while files are
/// dragged over the view. Only this view updates when the drag comes and
/// goes, not the pages inside it.
private struct DropZone<Content: View>: View {
    let drop: DropState
    let deviceName: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
                .opacity(drop.isTargeted ? 0 : 1)
                .allowsHitTesting(!drop.isTargeted)
            if drop.isTargeted {
                DropPrompt(deviceName: deviceName)
                    .transition(.opacity.combined(with: .scale(0.96)))
            }
        }
    }
}

private struct DropPrompt: View {
    let deviceName: String
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce.up, value: appeared)
                .frame(width: 76, height: 76)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .circle)
            VStack(spacing: 4) {
                Text("Drop to Send")
                    .font(.title2.weight(.semibold))
                Text("The files go to \(deviceName).")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(0.05))
                .strokeBorder(Color.accentColor.opacity(0.45),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: 744)
        .onAppear { appeared = true }
        .allowsHitTesting(false)
    }
}

/// The device tabs as one glass capsule, built like the sidebar pill: the
/// same height and padding, one edge, and a highlight that slides to the
/// selected tab. A system tab control draws its own track, which shows as a
/// second capsule inside the glass.
private struct PagePicker: View {
    @Bindable var selection: PageSelection
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DeviceDetail.Page.allCases) { page in
                let selected = selection.page == page
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection.page = page }
                } label: {
                    Text(page.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.1))
                                    .padding(.vertical, 3)
                                    .matchedGeometryEffect(id: "selected", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page")
    }
}
