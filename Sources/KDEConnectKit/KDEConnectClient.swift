import DBusKit
import Foundation

/// Typed wrapper around the kdeconnectd D-Bus API.
public struct KDEConnectClient: Sendable {
    public static let service = "org.kde.kdeconnect"
    static let root = "/modules/kdeconnect"

    public let connection: DBusConnection

    public init(connection: DBusConnection) {
        self.connection = connection
    }

    // MARK: Low level

    private func call(_ path: String, _ interface: String, _ member: String, _ args: [DBusValue] = [],
                      timeout: Duration = .seconds(10)) async throws -> [DBusValue] {
        try await connection.call(destination: Self.service, path: path, interface: interface, member: member, args,
                                  timeout: timeout)
    }

    private func properties(_ path: String, _ interface: String) async throws -> [String: DBusValue] {
        let reply = try await call(path, "org.freedesktop.DBus.Properties", "GetAll", [.string(interface)])
        return reply.first?.dictValue ?? [:]
    }

    static func devicePath(_ id: String) -> String { "\(root)/devices/\(id)" }
    static func pluginPath(_ id: String, _ plugin: String) -> String { "\(devicePath(id))/\(plugin)" }

    // MARK: Daemon

    public func isDaemonRegistered() async throws -> Bool {
        try await connection.nameHasOwner(Self.service)
    }

    public func deviceIds(onlyReachable: Bool = false, onlyPaired: Bool = false) async throws -> [String] {
        let reply = try await call(Self.root, "org.kde.kdeconnect.daemon", "devices",
                                   [.bool(onlyReachable), .bool(onlyPaired)])
        return reply.first?.stringArrayValue ?? []
    }

    public func announcedName() async throws -> String {
        try await call(Self.root, "org.kde.kdeconnect.daemon", "announcedName").first?.stringValue ?? ""
    }

    /// Asks the daemon to send identity packets again, for example after wake.
    public func forceOnNetworkChange() async throws {
        _ = try await call(Self.root, "org.kde.kdeconnect.daemon", "forceOnNetworkChange")
    }

    public func setAnnouncedName(_ name: String) async throws {
        _ = try await call(Self.root, "org.kde.kdeconnect.daemon", "setAnnouncedName", [.string(name)])
    }

    public func linkProviders() async throws -> [LinkProvider] {
        let reply = try await call(Self.root, "org.kde.kdeconnect.daemon", "linkProviders")
        return (reply.first?.stringArrayValue ?? []).compactMap(LinkProvider.init)
    }

    public func setLinkProvider(_ id: String, enabled: Bool) async throws {
        _ = try await call(Self.root, "org.kde.kdeconnect.daemon", "setLinkProviderState", [.string(id), .bool(enabled)])
    }

    /// Addresses that the daemon contacts directly, for networks without
    /// broadcast discovery (for example, a VPN such as Tailscale).
    public func customDevices() async throws -> [String] {
        let reply = try await call(Self.root, "org.freedesktop.DBus.Properties", "Get",
                                   [.string("org.kde.kdeconnect.daemon"), .string("customDevices")])
        return reply.first?.stringArrayValue ?? []
    }

    public func setCustomDevices(_ addresses: [String]) async throws {
        _ = try await call(Self.root, "org.freedesktop.DBus.Properties", "Set",
                           [.string("org.kde.kdeconnect.daemon"), .string("customDevices"),
                            .variant(.stringArray(addresses))])
    }

    /// Subscribes this connection to every signal that kdeconnectd emits.
    public func subscribeToSignals() async throws {
        try await connection.addMatch("type='signal',sender='\(Self.service)'")
    }

    // MARK: Device

    /// Reads one device and the plugin state that the UI shows.
    public func device(_ id: String) async throws -> Device {
        let path = Self.devicePath(id)
        var device = Device(id: id, properties: try await properties(path, "org.kde.kdeconnect.device"))
        guard device.isPaired, device.isReachable else { return device }

        let plugins = try await call(path, "org.kde.kdeconnect.device", "loadedPlugins").first?.stringArrayValue ?? []
        device.loadedPlugins = Set(plugins)

        let details = await readDeviceDetails(id: id, plugins: device.loadedPlugins,
                                              properties: { try await properties($0, $1) },
                                              notifications: { try await notifications(deviceId: $0) })
        device.battery = details.battery
        device.cellular = details.cellular
        device.notifications = details.notifications
        return device
    }

    public func notifications(deviceId id: String) async throws -> [PhoneNotification] {
        let base = Self.pluginPath(id, "notifications")
        let ids = try await call(base, "org.kde.kdeconnect.device.notifications", "activeNotifications")
            .first?.stringArrayValue ?? []
        // These property reads are independent. Keep a small number in
        // flight instead of paying one full round trip per notification.
        let result = await concurrentRead(ids, limit: 8) { nid -> PhoneNotification? in
            guard let p = try? await properties("\(base)/\(nid)", "org.kde.kdeconnect.device.notifications.notification")
            else { return nil }
            return notificationForDisplay(id: nid, properties: p)
        }
        // Higher public IDs are newer.
        return result.compactMap { $0 }.sorted { (Int($0.id) ?? 0) > (Int($1.id) ?? 0) }
    }

    /// Enabled state of each plugin that the device supports.
    public func pluginStates(_ id: String, plugins: [String]) async throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        for plugin in plugins {
            let reply = try await call(Self.devicePath(id), "org.kde.kdeconnect.device", "isPluginEnabled",
                                       [.string(plugin)])
            result[plugin] = reply.first?.boolValue ?? false
        }
        return result
    }

    public func setPluginEnabled(_ id: String, plugin: String, enabled: Bool) async throws {
        _ = try await call(Self.devicePath(id), "org.kde.kdeconnect.device", "setPluginEnabled",
                           [.string(plugin), .bool(enabled)])
    }

    // MARK: Actions

    public func requestPairing(_ id: String) async throws {
        _ = try await call(Self.devicePath(id), "org.kde.kdeconnect.device", "requestPairing")
    }

    public func acceptPairing(_ id: String) async throws {
        _ = try await call(Self.devicePath(id), "org.kde.kdeconnect.device", "acceptPairing")
    }

    /// Rejects an incoming request, or cancels an outgoing one.
    public func cancelPairing(_ id: String) async throws {
        _ = try await call(Self.devicePath(id), "org.kde.kdeconnect.device", "cancelPairing")
    }

    public func unpair(_ id: String) async throws {
        _ = try await call(Self.devicePath(id), "org.kde.kdeconnect.device", "unpair")
    }

    public func ping(_ id: String) async throws {
        _ = try await call(Self.pluginPath(id, "ping"), "org.kde.kdeconnect.device.ping", "sendPing")
    }

    public func ring(_ id: String) async throws {
        _ = try await call(Self.pluginPath(id, "findmyphone"), "org.kde.kdeconnect.device.findmyphone", "ring")
    }

    public func sendClipboard(_ id: String) async throws {
        _ = try await call(Self.pluginPath(id, "clipboard"), "org.kde.kdeconnect.device.clipboard", "sendClipboard")
    }

    public func share(_ id: String, urls: [URL]) async throws {
        _ = try await call(Self.pluginPath(id, "share"), "org.kde.kdeconnect.device.share", "shareUrls",
                           [.stringArray(urls.map(\.absoluteString))])
    }

    public func shareText(_ id: String, text: String) async throws {
        _ = try await call(Self.pluginPath(id, "share"), "org.kde.kdeconnect.device.share", "shareText",
                           [.string(text)])
    }

    public func dismissNotification(deviceId: String, notificationId: String) async throws {
        _ = try await call("\(Self.pluginPath(deviceId, "notifications"))/\(notificationId)",
                           "org.kde.kdeconnect.device.notifications.notification", "dismiss")
    }

    public func replyToNotification(deviceId: String, replyId: String, message: String) async throws {
        _ = try await call(Self.pluginPath(deviceId, "notifications"), "org.kde.kdeconnect.device.notifications",
                           "sendReply", [.string(replyId), .string(message)])
    }
}

/// Exclude non-dismissible items, such as ongoing playback controls.
/// Keep items with missing or invalid dismissibility data rather than hide them.
func notificationForDisplay(id: String, properties: [String: DBusValue]) -> PhoneNotification? {
    guard properties["dismissable"]?.boolValue != false else { return nil }
    return PhoneNotification(id: id, properties: properties)
}
