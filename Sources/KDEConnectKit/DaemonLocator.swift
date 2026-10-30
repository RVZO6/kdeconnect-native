import AppKit
import DBusKit
import Darwin
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

    private let applicationBundleURL: URL

    public init(applicationBundleURL: URL = Bundle.main.bundleURL) {
        self.applicationBundleURL = applicationBundleURL
    }

    /// Prefer the pinned helper in release builds. Source builds can use an
    /// installed KDE Connect app without downloading or compiling upstream.
    public var bundleURL: URL? {
        if let embedded = Self.embeddedBundle(in: applicationBundleURL) {
            return embedded
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/KDE Connect.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static func embeddedBundle(in applicationBundleURL: URL) -> URL? {
        let helper = applicationBundleURL.appendingPathComponent("Contents/Helpers/KDE Connect.app")
        let fm = FileManager.default
        guard ["kdeconnectd", "dbus-daemon"].allSatisfy({
            fm.isExecutableFile(atPath: helper.appendingPathComponent("Contents/MacOS/\($0)").path)
        }), fm.fileExists(atPath: helper.appendingPathComponent("Contents/Resources/dbus-1/session.conf").path)
        else { return nil }
        return helper
    }

    public var daemonURL: URL? { executable("kdeconnectd") }
    public var busURL: URL? { executable("dbus-daemon") }
    public var busConfigURL: URL? {
        guard let url = bundleURL?.appendingPathComponent("Contents/Resources/dbus-1/session.conf"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func executable(_ name: String) -> URL? {
        guard let url = bundleURL?.appendingPathComponent("Contents/MacOS/\(name)"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The address that the most recent daemon wrote, if its socket exists.
    public func currentBusAddress() -> String? {
        Self.currentBusAddress(at: Self.addressFile)
    }

    /// Open without following a symlink, then validate and read the same file.
    /// Nonblocking mode also prevents an untrusted FIFO from blocking startup.
    static func currentBusAddress(at addressFile: String, userID: uid_t = getuid()) -> String? {
        let fd = open(addressFile, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG, fileInfo.st_uid == userID,
              (fileInfo.st_mode & 0o022) == 0,
              let data = try? handle.read(upToCount: 4097), data.count <= 4096,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        guard let socketPath = try? DBusAddress.unixPath(address) else { return nil }
        var info = stat()
        guard lstat(socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == userID else { return nil }
        return address
    }
}
