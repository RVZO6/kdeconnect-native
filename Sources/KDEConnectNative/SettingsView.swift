import KDEConnectKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Connections", systemImage: "network") { ConnectionSettings() }
            Tab("Service", systemImage: "server.rack") { ServiceSettings() }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(KDEConnectStore.self) private var store
    @State private var name = ""
    @State private var launchAtLogin = LoginItem.isRegistered
    @AppStorage("keepWindowOnTop") private var keepWindowOnTop = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: $name)
                    .onSubmit { store.setAnnouncedName(name) }
                    .disabled(store.status != .connected)
            } footer: {
                Text("Other devices show this Mac with this name. Press Return to save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LoginItem.isRegistered else { return }
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isRegistered
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                if launchAtLogin && LoginItem.requiresApproval {
                    Text("Allow the app in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep window on top", isOn: $keepWindowOnTop)
            } footer: {
                Text("At login the app starts in the menu bar only. On top, the window stays above other apps' windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { name = store.announcedName }
        .onChange(of: store.announcedName) { _, newName in name = newName }
    }
}

private struct ConnectionSettings: View {
    @Environment(KDEConnectStore.self) private var store
    @State private var newAddress = ""
    @State private var selectedAddress: String?

    var body: some View {
        Form {
            Section("Connection types") {
                if store.linkProviders.isEmpty {
                    Text("Not connected to the KDE Connect service.").foregroundStyle(.secondary)
                }
                ForEach(store.linkProviders) { provider in
                    Toggle(provider.displayName, isOn: Binding(
                        get: { provider.isEnabled },
                        set: { store.setLinkProvider(provider.id, enabled: $0) }))
                }
            }
            Section {
                List(selection: $selectedAddress) {
                    ForEach(store.customDevices, id: \.self) { Text($0).tag($0) }
                }
                .frame(minHeight: 90)
                .overlay {
                    if store.customDevices.isEmpty {
                        Text("No addresses").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("IP address or host name", text: $newAddress)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") {
                        if let selectedAddress { store.removeCustomDevice(selectedAddress) }
                        selectedAddress = nil
                    }
                    .disabled(selectedAddress == nil)
                }
            } header: {
                Text("Device addresses")
            } footer: {
                Text("This Mac connects to these addresses directly. Use this when automatic discovery "
                     + "does not work, for example over a VPN such as Tailscale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(store.status != .connected)
        }
        .formStyle(.grouped)
    }

    private func add() {
        let trimmed = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addCustomDevice(trimmed)
        newAddress = ""
    }
}

private struct ServiceSettings: View {
    @Environment(KDEConnectStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Start and supervise the KDE Connect service", isOn: $store.autoStartDaemon)
            } footer: {
                Text("When kdeconnectd stops, or stays on a D-Bus session that is gone, this app starts it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status", value: statusText)
                HStack {
                    Button("Restart Service") { Task { await store.restartDaemon() } }
                    Button("Show Service Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.daemonLogURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch store.status {
        case .connected: "Running"
        case .starting: "Starting"
        case .daemonStopped: "Stopped"
        case .notInstalled: "KDE Connect.app is missing"
        }
    }
}
