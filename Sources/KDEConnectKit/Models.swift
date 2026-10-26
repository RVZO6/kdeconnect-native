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
    public var supportedPlugins: [String]
    public var verificationKey: String
    public var reachableAddresses: [String]
    public var activeProviders: [String]
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
        supportedPlugins = p["supportedPlugins"]?.stringArrayValue ?? []
        verificationKey = p["verificationKey"]?.stringValue ?? ""
        reachableAddresses = p["reachableAddresses"]?.stringArrayValue ?? []
        activeProviders = p["activeProviderNames"]?.stringArrayValue ?? []
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

/// A network backend of the daemon, such as LAN or Bluetooth.
public struct LinkProvider: Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var isEnabled: Bool

    /// Parses the daemon's "Display name|id|enabled" format.
    init?(_ raw: String) {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        displayName = parts[0]
        id = parts[1]
        isEnabled = parts[2] == "enabled"
    }
}

extension Plugin {
    /// Build this immutable table once, not for every label or sort comparison.
    private static let displayNames: [String: String] = [
            "kdeconnect_battery": "Battery monitor",
            "kdeconnect_bigscreen": "Bigscreen",
            "kdeconnect_clipboard": "Clipboard sync",
            "kdeconnect_connectivity_report": "Connectivity monitor",
            "kdeconnect_contacts": "Contacts",
            "kdeconnect_findmyphone": "Ring my phone",
            "kdeconnect_findthisdevice": "Find this device",
            "kdeconnect_lockdevice": "Lock device",
            "kdeconnect_mousepad": "Remote input",
            "kdeconnect_mpriscontrol": "Media control receiver",
            "kdeconnect_mprisremote": "Media controls",
            "kdeconnect_notifications": "Receive notifications",
            "kdeconnect_pausemusic": "Pause media during calls",
            "kdeconnect_ping": "Ping",
            "kdeconnect_presenter": "Presentation remote",
            "kdeconnect_remotecommands": "Host remote commands",
            "kdeconnect_remotecontrol": "Remote control",
            "kdeconnect_remotekeyboard": "Remote keyboard",
            "kdeconnect_runcommand": "Run commands",
            "kdeconnect_screensaver_inhibit": "Inhibit screensaver",
            "kdeconnect_sendnotifications": "Send notifications",
            "kdeconnect_sftp": "Remote filesystem browser",
            "kdeconnect_share": "Share and receive",
            "kdeconnect_sms": "SMS",
            "kdeconnect_systemvolume": "System volume",
            "kdeconnect_telephony": "Telephony integration",
            "kdeconnect_virtualmonitor": "Virtual monitor",
    ]

    /// Readable names for plugin IDs, as the stock settings show them.
    public static func displayName(for id: String) -> String {
        if let name = displayNames[id] { return name }
        let bare = id.hasPrefix("kdeconnect_") ? String(id.dropFirst("kdeconnect_".count)) : id
        return bare.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
