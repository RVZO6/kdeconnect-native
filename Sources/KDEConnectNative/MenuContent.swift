import KDEConnectKit
import SwiftUI

struct MenuContent: View {
    @Environment(KDEConnectStore.self) private var store
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = store.lastError {
                ErrorBanner(message: error) { store.clearError() }
            }
            switch store.status {
            case .connected:
                deviceSections
            case .starting:
                StatusMessage(symbol: "hourglass", title: "Starting KDE Connect…",
                              detail: "Waiting for kdeconnectd on its private bus.")
            case .daemonStopped:
                StatusMessage(symbol: "iphone.slash.circle", title: "KDE Connect is not running",
                              detail: store.autoStartDaemon ? "Starting it again…" : "Automatic start is off.")
            case .notInstalled:
                StatusMessage(symbol: "exclamationmark.triangle", title: "KDE Connect.app is missing",
                              detail: "Install it in /Applications. This app uses its daemon.")
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("KDE Connect").font(.headline)
                if !store.announcedName.isEmpty {
                    Text("This Mac: \(store.announcedName)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Circle()
                .fill(store.status == .connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .help(store.status == .connected ? "Connected to kdeconnectd" : "Not connected to kdeconnectd")
        }
    }

    @ViewBuilder
    private var deviceSections: some View {
        if !store.pairingRequests.isEmpty {
            SectionTitle("Pairing requests")
            ForEach(store.pairingRequests) { PairingRequestRow(device: $0) }
        }
        if store.pairedDevices.isEmpty {
            StatusMessage(symbol: "iphone.radiowaves.left.and.right", title: "No paired devices",
                          detail: "Open KDE Connect on your phone, then pair it below.")
        } else {
            // One scroll view whose height follows its content up to a limit.
            // A single hierarchy keeps the card state (expanded lists, reply
            // drafts) when the content grows past the limit.
            ScrollView {
                pairedList
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 1), 460))
        }
        if !store.availableDevices.isEmpty {
            SectionTitle("Available devices")
            ForEach(store.availableDevices) { AvailableDeviceRow(device: $0) }
        }
    }

    private var pairedList: some View {
        VStack(spacing: 8) {
            ForEach(store.pairedDevices) { DeviceCard(device: $0) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.status == .connected {
                MenuButton("Messages", symbol: "message") { store.openSMSApp() }
            }
            MenuButton("KDE Connect Settings", symbol: "slider.horizontal.3") { store.openSettingsApp() }
            MenuButton("Restart KDE Connect Service", symbol: "arrow.clockwise") {
                Task { await store.restartDaemon() }
            }
            SettingsLink {
                Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            MenuButton("Quit", symbol: "power") { NSApp.terminate(nil) }
        }
    }
}

// MARK: Small building blocks

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

struct StatusMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MenuButton: View {
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
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuButtonStyle())
    }
}

/// Mimics a menu item: full width, highlight on hover.
struct MenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct HoverHighlight<Content: View>: View {
    let pressed: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering || pressed ? Color.accentColor.opacity(pressed ? 0.35 : 0.18) : .clear)
            )
            .onHover { hovering = $0 }
    }
}
