import DBusKit
import Foundation

/// Settings of one plugin for one device, as KDE Connect stores them.
///
/// kdeconnectd keeps them in `~/Library/Preferences/kdeconnect/<device>/<plugin>/config`,
/// a Qt `QSettings` INI file with the values in `[General]`. After a write,
/// a `configChanged` signal on `/kdeconnect/<device>/<plugin>` tells the
/// daemon to read the file again.
public struct PluginConfig: Sendable {
    public let deviceId: String
    public let plugin: String
    private let baseDirectory: URL

    public static var defaultBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/kdeconnect")
    }

    public init(deviceId: String, plugin: String, baseDirectory: URL = PluginConfig.defaultBaseDirectory) {
        self.deviceId = deviceId
        self.plugin = plugin
        self.baseDirectory = baseDirectory
    }

    /// Plugins that have settings, in the same set as the stock app.
    public static let configurablePlugins: Set<String> = [
        "kdeconnect_clipboard", "kdeconnect_share", "kdeconnect_runcommand", "kdeconnect_presenter",
    ]

    public var fileURL: URL {
        baseDirectory
            .appendingPathComponent(deviceId)
            .appendingPathComponent(plugin)
            .appendingPathComponent("config")
    }

    // MARK: Reading

    /// The `[General]` values, decoded to strings.
    public func values() -> [String: String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        let ini = IniFile(text: text)
        return ini.section("General").reduce(into: [:]) { result, entry in
            result[entry.key] = IniFile.decode(entry.value)
        }
    }

    public func bool(_ key: String, default value: Bool) -> Bool {
        guard let raw = values()[key] else { return value }
        return raw == "true" || raw == "1"
    }

    public func int(_ key: String, default value: Int) -> Int {
        values()[key].flatMap { Int($0) } ?? value
    }

    public func string(_ key: String, default value: String) -> String {
        values()[key] ?? value
    }

    // MARK: Writing

    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
    }

    /// Writes `changes` into `[General]` and keeps every other key and section.
    public func write(_ changes: [String: Value]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var ini = IniFile(text: (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            ini.set(IniFile.encode(value), for: key, in: "General")
        }
        try ini.text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// The signal that makes the daemon (and any other client) reload this config.
    public var changedSignal: DBusMessage {
        var signal = DBusMessage(kind: .signal)
        signal.path = "/kdeconnect/\(deviceId)/\(plugin)"
        signal.interface = "org.kde.kdeconnect.config"
        signal.member = "configChanged"
        return signal
    }
}

// MARK: - Run commands

/// A command that other devices can run on this Mac.
public struct RunCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var command: String

    public init(id: String = "{\(UUID().uuidString.lowercased())}", name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    /// Parses the `commands` value: a JSON object of `{key: {name, command}}`.
    public static func decode(_ json: String) -> [RunCommand] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.compactMap { key, value in
            guard let entry = value as? [String: Any] else { return nil }
            return RunCommand(id: key, name: entry["name"] as? String ?? "", command: entry["command"] as? String ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func encode(_ commands: [RunCommand]) -> String {
        var object: [String: [String: String]] = [:]
        for command in commands { object[command.id] = ["name": command.name, "command": command.command] }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - INI codec

/// A minimal QSettings-compatible INI file. It keeps the order of sections
/// and keys, and the raw text of values that it does not change.
struct IniFile {
    struct Entry {
        var key: String
        var value: String  // raw, still escaped
    }

    private var sections: [(name: String, entries: [Entry])] = []

    init(text: String) {
        var current = ""
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                current = String(trimmed.dropFirst().dropLast())
                if !sections.contains(where: { $0.name == current }) { sections.append((current, [])) }
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !sections.contains(where: { $0.name == current }) { sections.append((current, [])) }
            let index = sections.firstIndex { $0.name == current }!
            sections[index].entries.append(Entry(key: key, value: value))
        }
    }

    func section(_ name: String) -> [Entry] {
        sections.first { $0.name == name }?.entries ?? []
    }

    mutating func set(_ rawValue: String, for key: String, in section: String) {
        if let s = sections.firstIndex(where: { $0.name == section }) {
            if let e = sections[s].entries.firstIndex(where: { $0.key == key }) {
                sections[s].entries[e].value = rawValue
            } else {
                sections[s].entries.append(Entry(key: key, value: rawValue))
            }
        } else {
            sections.append((section, [Entry(key: key, value: rawValue)]))
        }
    }

    var text: String {
        sections.map { section in
            let header = section.name.isEmpty ? [] : ["[\(section.name)]"]
            return (header + section.entries.map { "\($0.key)=\($0.value)" }).joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    // MARK: Values

    /// Encodes a value the way QSettings does (variantToString + iniEscapedString).
    static func encode(_ value: PluginConfig.Value) -> String {
        switch value {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .string(let s): return escape(s.hasPrefix("@") ? "@" + s : s)
        }
    }

    static func escape(_ s: String) -> String {
        var needsQuotes = s.hasPrefix(" ") || s.hasSuffix(" ")
        var result = ""
        var escapeNextIfHex = false
        for scalar in s.unicodeScalars {
            if scalar == ";" || scalar == "," || scalar == "=" { needsQuotes = true }
            if escapeNextIfHex, scalar.properties.isASCIIHexDigit {
                result += String(format: "\\x%x", scalar.value)
                continue
            }
            escapeNextIfHex = false
            switch scalar {
            case "\0": result += "\\0"
            case "\u{07}": result += "\\a"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{0B}": result += "\\v"
            case "\"", "\\": result += "\\" + String(scalar)
            default:
                if scalar.value <= 0x1F {
                    result += String(format: "\\x%x", scalar.value)
                    escapeNextIfHex = true
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return needsQuotes ? "\"\(result)\"" : result
    }

    /// Decodes a raw value: quotes, backslash escapes, `@ByteArray(...)` and `@@`.
    static func decode(_ raw: String) -> String {
        var result = ""
        var inQuotes = false
        var iterator = Array(raw.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            switch c {
            case "\"":
                inQuotes.toggle()
            case "\\":
                guard let e = next() else { break }
                switch e {
                case "n": result += "\n"
                case "r": result += "\r"
                case "t": result += "\t"
                case "a": result += "\u{07}"
                case "b": result += "\u{08}"
                case "f": result += "\u{0C}"
                case "v": result += "\u{0B}"
                case "0": result += "\0"
                case "x":
                    var hex = ""
                    while let h = next() {
                        if h.properties.isASCIIHexDigit { hex.unicodeScalars.append(h) } else { pending = h; break }
                    }
                    if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { result.unicodeScalars.append(s) }
                default: result.unicodeScalars.append(e)
                }
            default:
                result.unicodeScalars.append(c)
            }
        }
        if result.hasPrefix("@ByteArray("), result.hasSuffix(")") {
            // QSettings writes each byte of a byte array as one Latin-1
            // character, often as a \x escape. Turn each one back into its
            // byte, then read the bytes as UTF-8.
            var bytes: [UInt8] = []
            for scalar in result.unicodeScalars.dropFirst("@ByteArray(".count).dropLast() {
                if scalar.value < 256 { bytes.append(UInt8(scalar.value)) } else { bytes += Array(String(scalar).utf8) }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        if result.hasPrefix("@@") { return String(result.dropFirst()) }
        return result
    }
}
