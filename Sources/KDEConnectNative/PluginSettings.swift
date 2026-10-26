import KDEConnectKit
import SwiftUI

/// The settings sheet for one plugin of one device.
struct PluginSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let device: Device
    let plugin: String

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch plugin {
                case "kdeconnect_clipboard": ClipboardSettings(config: config)
                case "kdeconnect_share": ShareSettings(config: config)
                case "kdeconnect_runcommand": RunCommandSettings(config: config)
                case "kdeconnect_presenter": PresenterSettings(config: config)
                default: Text("This plugin has no settings.").padding()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480)
        .navigationTitle("\(Plugin.displayName(for: plugin)) — \(device.name)")
    }

    private var config: PluginConfig { PluginConfig(deviceId: device.id, plugin: plugin) }
}

private struct ClipboardSettings: View {
    @Environment(KDEConnectStore.self) private var store
    let config: PluginConfig
    @State private var autoShare = true
    @State private var sendPassword = true
    @State private var maxFileSize = 50

    var body: some View {
        Form {
            Section {
                Toggle("Automatically share the clipboard from this Mac",
                       isOn: $autoShare.saving { store.savePluginConfig(config, ["autoShare": .bool($0)]) })
                Toggle("Include passwords (as marked by password managers)",
                       isOn: $sendPassword.saving { store.savePluginConfig(config, ["sendPassword": .bool($0)]) })
                    .disabled(!autoShare)
                LabeledContent("Largest file to share") {
                    HStack {
                        TextField("", value: $maxFileSize.saving { _ in saveSize() }, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $maxFileSize.saving { _ in saveSize() }, in: 0...1_000_000).labelsHidden()
                        Text("MB")
                    }
                }
            } header: {
                Text("Clipboard")
            }
        }
        .onAppear {
            // "sendUnknown" is the older name of the same setting.
            autoShare = config.bool("autoShare", default: config.bool("sendUnknown", default: true))
            sendPassword = config.bool("sendPassword", default: true)
            maxFileSize = config.int("maxClipboardFileSizeMB", default: 50)
        }
    }

    private func saveSize() {
        maxFileSize = max(0, maxFileSize)
        store.savePluginConfig(config, ["maxClipboardFileSizeMB": .int(maxFileSize)])
    }
}

private struct ShareSettings: View {
    @Environment(KDEConnectStore.self) private var store
    let config: PluginConfig
    @State private var path = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Save received files in") {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: choose)
                    }
                }
            } header: {
                Text("Received files")
            }
        }
        .onAppear {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
            path = config.string("incoming_path", default: downloads)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        store.savePluginConfig(config, ["incoming_path": .string(url.path)])
    }
}

private struct RunCommandSettings: View {
    @Environment(KDEConnectStore.self) private var store
    let config: PluginConfig
    @State private var commands: [RunCommand] = []
    @State private var selection: RunCommand.ID?
    @State private var editing: RunCommand?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(commands) { command in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.name.isEmpty ? "Untitled" : command.name)
                            Text(command.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(command.id)
                        .contextMenu {
                            Button("Edit…") { editing = command }
                            Button("Delete", role: .destructive) { delete(command.id) }
                        }
                    }
                }
                .frame(minHeight: 140)
                .overlay {
                    if commands.isEmpty {
                        ContentUnavailableView("No Commands", systemImage: "terminal",
                                               description: Text("Add commands that your devices can run on this Mac."))
                    }
                }
                HStack {
                    Button("Add…") { editing = RunCommand(name: "", command: "") }
                    Button("Edit…") { editing = commands.first { $0.id == selection } }.disabled(selection == nil)
                    Button("Delete") { selection.map(delete) }.disabled(selection == nil)
                }
            } header: {
                Text("Commands")
            } footer: {
                Text("Commands run with /bin/sh as your user.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { commands = RunCommand.decode(config.string("commands", default: "{}")) }
        .sheet(item: $editing) { command in
            CommandEditor(command: command) { save($0) }
        }
    }

    private func save(_ command: RunCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
        persist()
    }

    private func delete(_ id: RunCommand.ID) {
        commands.removeAll { $0.id == id }
        if selection == id { selection = nil }
        persist()
    }

    private func persist() {
        store.savePluginConfig(config, ["commands": .string(RunCommand.encode(commands))])
    }
}

private struct CommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var command: RunCommand
    let onSave: (RunCommand) -> Void

    private static let samples: [(String, String)] = [
        // Display sleep locks the Mac only when "Require password" is set to
        // "Immediately" in Lock Screen settings.
        ("Turn Off Display", "pmset displaysleepnow"),
        ("Sleep", "pmset sleepnow"),
        ("Mute", "osascript -e 'set volume with output muted'"),
        ("Unmute", "osascript -e 'set volume without output muted'"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $command.name)
                TextField("Command", text: $command.command)
                    .font(.body.monospaced())
                Picker("Sample", selection: Binding<String?>(get: { nil }, set: { pick($0) })) {
                    Text("None").tag(String?.none)
                    ForEach(Self.samples, id: \.0) { Text($0.0).tag(Optional($0.0)) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 420)
    }

    private func pick(_ name: String?) {
        guard let sample = Self.samples.first(where: { $0.0 == name }) else { return }
        command.name = sample.0
        command.command = sample.1
    }
}

private struct PresenterSettings: View {
    @Environment(KDEConnectStore.self) private var store
    let config: PluginConfig
    @State private var style = "PresenterRedDot.qml"

    var body: some View {
        Form {
            Picker("Pointer", selection: $style.saving { store.savePluginConfig(config, ["current": .string($0)]) }) {
                Text("Red Dot").tag("PresenterRedDot.qml")
                Text("Electric").tag("PresenterElectric.qml")
            }
        }
        .onAppear {
            let current = config.string("current", default: "PresenterRedDot.qml")
            style = current.isEmpty ? "PresenterRedDot.qml" : current
        }
    }
}

extension Binding where Value: Equatable & Sendable {
    /// A binding that runs `save` after each change by the user. Loading a
    /// value into the underlying state does not call it.
    @MainActor
    func saving(_ save: @escaping @MainActor (Value) -> Void) -> Binding<Value> {
        let base = self
        return Binding {
            base.wrappedValue
        } set: { newValue in
            guard newValue != base.wrappedValue else { return }
            base.wrappedValue = newValue
            MainActor.assumeIsolated { save(newValue) }
        }
    }
}
