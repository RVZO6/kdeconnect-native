import KDEConnectKit
import SwiftUI

struct SettingsView: View {
    @Environment(KDEConnectStore.self) private var store
    @AppStorage("showBatteryInMenuBar") private var showBattery = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show phone battery in the menu bar", isOn: $showBattery)
            }
            Section {
                Toggle("Start and supervise the KDE Connect service", isOn: $store.autoStartDaemon)
                Text("When kdeconnectd stops, or stays on a dead D-Bus session, this app starts it again.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Restart Service") { Task { await store.restartDaemon() } }
                    Button("Show Service Log") { NSWorkspace.shared.activateFileViewerSelecting([store.daemonLogURL]) }
                    Button("KDE Connect Settings") { store.openSettingsApp() }
                }
            } header: {
                Text("Service")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
