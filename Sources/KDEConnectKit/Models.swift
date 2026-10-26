import DBusKit
import Foundation

public struct Device: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case phone, tablet, desktop, laptop, tv, unknown
    }

    public let id: String
    public var name: String
    public var kind: Kind
    public var isReachable: Bool
    public var isPaired: Bool
    public var isPairRequested: Bool
    public var isPairRequestedByPeer: Bool
    public var loadedPlugins: Set<String> = []
    public var battery: Battery?
    public var cellular: Cellular?
    public var notifications: [PhoneNotification] = []

    public struct Battery: Equatable, Sendable {
        public var charge: Int
        public var isCharging: Bool
    }

    public struct Cellular: Equatable, Sendable {
        public var networkType: String
        /// 0 to 4, or -1 when there is no signal.
        public var strength: Int
    }

    public func has(_ plugin: Plugin) -> Bool { loadedPlugins.contains(plugin.rawValue) }

    init(id: String, properties p: [String: DBusValue]) {
        self.id = id
        name = p["name"]?.stringValue ?? id
        kind = Kind(rawValue: p["type"]?.stringValue ?? "") ?? .unknown
        isReachable = p["isReachable"]?.boolValue ?? false
        isPaired = p["isPaired"]?.boolValue ?? false
        isPairRequested = p["isPairRequested"]?.boolValue ?? false
        isPairRequestedByPeer = p["isPairRequestedByPeer"]?.boolValue ?? false
    }
}

public struct PhoneNotification: Identifiable, Equatable, Sendable {
    public let id: String
    public var appName: String
    public var title: String
    public var text: String
    public var dismissable: Bool
    public var replyId: String

    init(id: String, properties p: [String: DBusValue]) {
        self.id = id
        appName = p["appName"]?.stringValue ?? ""
        title = p["title"]?.stringValue ?? ""
        text = p["text"]?.stringValue ?? ""
        dismissable = p["dismissable"]?.boolValue ?? false
        replyId = p["replyId"]?.stringValue ?? ""
    }
}

/// Plugin names as kdeconnectd reports them in `loadedPlugins`.
public enum Plugin: String, Sendable {
    case battery = "kdeconnect_battery"
    case clipboard = "kdeconnect_clipboard"
    case connectivity = "kdeconnect_connectivity_report"
    case findMyPhone = "kdeconnect_findmyphone"
    case notifications = "kdeconnect_notifications"
    case ping = "kdeconnect_ping"
    case share = "kdeconnect_share"
    case sms = "kdeconnect_sms"
}
