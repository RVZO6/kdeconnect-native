import AppKit
import KDEConnectKit
import SwiftUI
import UniformTypeIdentifiers

struct DeviceCard: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device
    @State private var showNotifications = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: device.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(device.isReachable ? .primary : .tertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let battery = device.battery {
                    BatteryView(battery: battery)
                }
            }
            if device.isReachable {
                actions
                if !device.notifications.isEmpty {
                    notificationsSection
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTargeted ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
        )
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard device.isReachable, device.has(.share) else { return false }
            send(urls)
            return true
        } isTargeted: { dropTargeted = $0 && device.isReachable && device.has(.share) }
        .contextMenu {
            Button("Unpair \(device.name)", role: .destructive) {
                let id = device.id
                store.perform("Unpair") { try await $0.unpair(id) }
            }
        }
    }

    private var subtitle: String {
        guard device.isReachable else { return "Not reachable" }
        var parts = ["Connected"]
        if let cellular = device.cellular {
            parts.append(cellular.networkType)
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 6) {
            let id = device.id
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
                ActionButton("Clipboard", symbol: "doc.on.clipboard") {
                    store.perform("Send clipboard") { try await $0.sendClipboard(id) }
                }
            }
            if device.has(.share) {
                ActionButton("Send Files", symbol: "paperplane") { chooseFiles() }
            }
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showNotifications.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showNotifications ? 90 : 0))
                        .font(.caption2.weight(.bold))
                    Image(systemName: "bell.badge")
                    Text("\(device.notifications.count) notification\(device.notifications.count == 1 ? "" : "s")")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showNotifications {
                ForEach(device.notifications) { NotificationRow(deviceId: device.id, notification: $0) }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(device.name)"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        send(panel.urls)
    }

    private func send(_ urls: [URL]) {
        let id = device.id
        store.perform("Send files") { try await $0.share(id, urls: urls) }
    }
}

struct ActionButton: View {
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
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(MenuButtonStyle())
        .help(title)
    }
}

struct BatteryView: View {
    let battery: Device.Battery

    var body: some View {
        HStack(spacing: 3) {
            Text("\(battery.charge)%").font(.caption.monospacedDigit())
            Image(systemName: symbol)
                .foregroundStyle(battery.charge <= 15 && !battery.isCharging ? .red : .secondary)
        }
        .help(battery.isCharging ? "Charging" : "On battery")
    }

    private var symbol: String {
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

struct NotificationRow: View {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String
    let notification: PhoneNotification
    @State private var replying = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(notification.appName).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if !notification.title.isEmpty {
                        Text(notification.title).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    if !notification.text.isEmpty {
                        Text(notification.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !notification.replyId.isEmpty {
                    Button { replying.toggle() } label: { Image(systemName: "arrowshape.turn.up.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Reply")
                }
                if notification.dismissable {
                    Button {
                        let (d, n) = (deviceId, notification.id)
                        store.perform("Dismiss") { try await $0.dismissNotification(deviceId: d, notificationId: n) }
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss on phone")
                }
            }
            if replying {
                HStack {
                    TextField("Reply", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit(sendReply)
                    Button("Send", action: sendReply).controlSize(.small).disabled(reply.isEmpty)
                }
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sendReply() {
        guard !reply.isEmpty else { return }
        let (d, r, m) = (deviceId, notification.replyId, reply)
        store.perform("Reply") { try await $0.replyToNotification(deviceId: d, replyId: r, message: m) }
        reply = ""
        replying = false
    }
}

struct PairingRequestRow: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device

    var body: some View {
        HStack {
            Image(systemName: device.kind.symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout.weight(.medium))
                Text("Wants to pair").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let id = device.id
            Button("Reject") { store.perform("Reject pairing") { try await $0.cancelPairing(id) } }
                .controlSize(.small)
            Button("Accept") { store.perform("Accept pairing") { try await $0.acceptPairing(id) } }
                .controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AvailableDeviceRow: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device

    var body: some View {
        HStack {
            Image(systemName: device.kind.symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(device.name).font(.callout).lineLimit(1)
            Spacer()
            let id = device.id
            if device.isPairRequested {
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { store.perform("Cancel pairing") { try await $0.cancelPairing(id) } }
                    .controlSize(.small)
            } else {
                Button("Pair") { store.perform("Pair") { try await $0.requestPairing(id) } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }
}
