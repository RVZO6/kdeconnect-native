import KDEConnectKit
import SwiftUI

/// The page for one device: status, actions, notifications, plugins and
/// connection details.
struct DeviceDetail: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device
    @State private var pluginStates: [String: Bool] = [:]
    @State private var confirmUnpair = false
    @State private var dropTargeted = false

    var body: some View {
        Form {
            Section { header }
            if !device.isPaired {
                pairingSection
            } else {
                if device.isReachable { actionsSection }
                if !device.notifications.isEmpty { notificationsSection }
            }
            detailsSection
            if device.isPaired {
                pluginsSection
                Section {
                    Button("Unpair \(device.name)…", role: .destructive) { confirmUnpair = true }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
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
        .task(id: PluginKey(device: device)) {
            pluginStates = await store.pluginStates(for: device) ?? [:]
        }
    }

    private var canShare: Bool { device.isReachable && device.has(.share) }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(device.isReachable ? Color.accentColor : .secondary)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.title2.weight(.semibold))
                Text(statusLine).foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = device.battery {
                Label("\(battery.charge)%", systemImage: batterySymbol(battery))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(battery.charge <= 15 && !battery.isCharging ? .red : .primary)
                    .help(battery.isCharging ? "Charging" : "On battery")
            }
        }
        .padding(.vertical, 4)
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
                        Button("Accept") { store.perform("Accept pairing") { try await $0.acceptPairing(id) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                verificationKeyRow
            } else if device.isPairRequested {
                LabeledContent("Waiting for \(device.name) to accept…") {
                    Button("Cancel") { store.perform("Cancel pairing") { try await $0.cancelPairing(id) } }
                }
                verificationKeyRow
            } else {
                LabeledContent("This device is not paired.") {
                    Button("Request Pairing") { store.perform("Pair") { try await $0.requestPairing(id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!device.isReachable)
                }
            }
        } header: {
            Text("Pairing")
        }
    }

    private var actionsSection: some View {
        Section {
            let id = device.id
            HStack(spacing: 10) {
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
                }
                if device.has(.sms) {
                    ActionButton("Messages", symbol: "message") { store.openSMSApp() }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Actions")
        } footer: {
            if canShare {
                Text("You can also drop files on this window to send them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            ForEach(device.notifications) { NotificationRow(deviceId: device.id, notification: $0) }
        }
    }

    private var pluginsSection: some View {
        Section("Plugins") {
            if pluginStates.isEmpty {
                Text(device.supportedPlugins.isEmpty ? "No plugins reported." : "Loading…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedPlugins, id: \.self) { plugin in
                    Toggle(Plugin.displayName(for: plugin), isOn: pluginBinding(plugin))
                }
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

    private func pluginBinding(_ plugin: String) -> Binding<Bool> {
        Binding {
            pluginStates[plugin] ?? false
        } set: { enabled in
            pluginStates[plugin] = enabled
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

/// Reloads plugin states when the device or its plugin list changes.
private struct PluginKey: Equatable {
    let id: String
    let plugins: [String]
    let loaded: Set<String>

    init(device: Device) {
        id = device.id
        plugins = device.supportedPlugins
        loaded = device.loadedPlugins
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
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

private struct NotificationRow: View {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String
    let notification: PhoneNotification
    @State private var replying = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.appName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if !notification.title.isEmpty {
                        Text(notification.title).fontWeight(.medium)
                    }
                    if !notification.text.isEmpty {
                        Text(notification.text).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                Spacer()
                if !notification.replyId.isEmpty {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { replying.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reply")
                }
                if notification.dismissable {
                    Button("Dismiss", systemImage: "xmark.circle.fill") {
                        let (d, n) = (deviceId, notification.id)
                        store.perform("Dismiss") { try await $0.dismissNotification(deviceId: d, notificationId: n) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss on the device")
                }
            }
            if replying {
                HStack {
                    TextField("Reply", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendReply)
                    Button("Send", action: sendReply).disabled(reply.isEmpty)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sendReply() {
        guard !reply.isEmpty else { return }
        let (d, r, m) = (deviceId, notification.replyId, reply)
        store.perform("Reply") { try await $0.replyToNotification(deviceId: d, replyId: r, message: m) }
        reply = ""
        replying = false
    }
}
