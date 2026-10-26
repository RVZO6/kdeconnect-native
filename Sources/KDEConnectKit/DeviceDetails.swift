import DBusKit

/// Optional plugin data for a paired, reachable device. A failed plugin
/// read must not hide the device or data from another plugin.
struct DeviceDetails: Sendable {
    var battery: Device.Battery?
    var cellular: Device.Cellular?
    var notifications: [PhoneNotification] = []
}

typealias DevicePropertyReader = @Sendable (String, String) async throws -> [String: DBusValue]
typealias DeviceNotificationReader = @Sendable (String) async throws -> [PhoneNotification]

func readDeviceDetails(id: String, plugins: Set<String>,
                       properties: @escaping DevicePropertyReader,
                       notifications: @escaping DeviceNotificationReader) async -> DeviceDetails {
    var details = DeviceDetails()
    if plugins.contains(Plugin.battery.rawValue),
       let p = try? await properties(KDEConnectClient.pluginPath(id, "battery"), "org.kde.kdeconnect.device.battery"),
       p["hasBattery"]?.boolValue != false, let charge = p["charge"]?.intValue, charge >= 0 {
        details.battery = .init(charge: charge, isCharging: p["isCharging"]?.boolValue ?? false)
    }
    if plugins.contains(Plugin.connectivity.rawValue),
       let p = try? await properties(KDEConnectClient.pluginPath(id, "connectivity_report"),
                                     "org.kde.kdeconnect.device.connectivity_report"),
       let type = p["cellularNetworkType"]?.stringValue, !type.isEmpty {
        details.cellular = .init(networkType: type, strength: p["cellularNetworkStrength"]?.intValue ?? -1)
    }
    if plugins.contains(Plugin.notifications.rawValue) {
        details.notifications = (try? await notifications(id)) ?? []
    }
    return details
}
