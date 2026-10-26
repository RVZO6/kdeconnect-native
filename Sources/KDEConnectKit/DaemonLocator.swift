import AppKit
import DBusKit
import Foundation

/// Finds the KDE Connect bundle and its private session bus.
///
/// On macOS, KDE Connect does not use a system session bus. Its launcher
/// starts a private dbus-daemon, writes the address to
/// `/tmp/private_dbus_address`, and starts kdeconnectd on that bus. Each
/// restart creates a new bus, so clients must read the file again.
public struct DaemonLocator: Sendable {
    public static let addressFile = "/tmp/private_dbus_address"
    public static let bundleIdentifier = "org.kde.kdeconnect"

    public init() {}

    /// The KDE Connect app bundle, found by bundle identifier or default path.
    public var bundleURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/KDE Connect.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    public var daemonURL: URL? { executable("kdeconnectd") }
    public var busURL: URL? { executable("dbus-daemon") }
    public var busConfigURL: URL? {
        guard let url = bundleURL?.appendingPathComponent("Contents/Resources/dbus-1/session.conf"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    public var smsAppURL: URL? { executable("kdeconnect-sms") }

    private func executable(_ name: String) -> URL? {
        guard let url = bundleURL?.appendingPathComponent("Contents/MacOS/\(name)"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The address that the most recent daemon wrote, if its socket exists.
    public func currentBusAddress() -> String? {
        guard let text = try? String(contentsOfFile: Self.addressFile, encoding: .utf8) else { return nil }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        guard let socketPath = try? DBusAddress.unixPath(address) else { return nil }
        var info = stat()
        guard stat(socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return address
    }
}
