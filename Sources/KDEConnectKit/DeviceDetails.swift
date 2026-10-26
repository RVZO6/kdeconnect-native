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
    let hasBattery = plugins.contains(Plugin.battery.rawValue)
    let hasCellular = plugins.contains(Plugin.connectivity.rawValue)
    let hasNotifications = plugins.contains(Plugin.notifications.rawValue)
    let enabledCount = (hasBattery ? 1 : 0) + (hasCellular ? 1 : 0) + (hasNotifications ? 1 : 0)

    // Most disconnected or minimally configured devices need at most one
    // optional read. Avoid creating child tasks for those cases.
    if enabledCount == 0 { return DeviceDetails() }
    if enabledCount == 1 {
        if hasBattery { return DeviceDetails(battery: await readBattery(id: id, properties: properties)) }
        if hasCellular { return DeviceDetails(cellular: await readCellular(id: id, properties: properties)) }
        return DeviceDetails(notifications: (try? await notifications(id)) ?? [])
    }

    // These plugins are independent. Their failures are optional, so read
    // them at once and retain each successful result separately.
    async let battery = readBattery(id: id, enabled: hasBattery, properties: properties)
    async let cellular = readCellular(id: id, enabled: hasCellular, properties: properties)
    async let phoneNotifications = readNotifications(id: id, enabled: hasNotifications, notifications: notifications)
    return await DeviceDetails(battery: battery, cellular: cellular, notifications: phoneNotifications)
}

private func readBattery(id: String, enabled: Bool = true,
                         properties: DevicePropertyReader) async -> Device.Battery? {
    guard enabled,
          let p = try? await properties(KDEConnectClient.pluginPath(id, "battery"), "org.kde.kdeconnect.device.battery"),
          p["hasBattery"]?.boolValue != false, let charge = p["charge"]?.intValue, charge >= 0 else { return nil }
    return .init(charge: charge, isCharging: p["isCharging"]?.boolValue ?? false)
}

private func readCellular(id: String, enabled: Bool = true,
                          properties: DevicePropertyReader) async -> Device.Cellular? {
    guard enabled,
          let p = try? await properties(KDEConnectClient.pluginPath(id, "connectivity_report"),
                                        "org.kde.kdeconnect.device.connectivity_report"),
          let type = p["cellularNetworkType"]?.stringValue, !type.isEmpty else { return nil }
    return .init(networkType: type, strength: p["cellularNetworkStrength"]?.intValue ?? -1)
}

private func readNotifications(id: String, enabled: Bool,
                               notifications: DeviceNotificationReader) async -> [PhoneNotification] {
    guard enabled else { return [] }
    return (try? await notifications(id)) ?? []
}
