import KDEConnectKit
import SwiftUI

/// A white symbol on a coloured rounded square, as in System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    /// Grey instead of colour, for things that are off or not reachable.
    var muted = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill((muted ? Color.gray : color).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .opacity(muted ? 0.55 : 1)
            .accessibilityHidden(true)
    }
}

extension Device.Kind {
    var tint: Color {
        switch self {
        case .phone, .unknown: .blue
        case .tablet: .indigo
        case .laptop: .teal
        case .desktop: .cyan
        case .tv: .orange
        }
    }
}

extension Plugin {
    /// The symbol and colour of a plugin's tile, by plugin ID.
    static func tile(for id: String) -> (symbol: String, color: Color) {
        switch id {
        case "kdeconnect_battery": ("battery.75percent", .green)
        case "kdeconnect_clipboard": ("doc.on.clipboard", .blue)
        case "kdeconnect_connectivity_report": ("antenna.radiowaves.left.and.right", .teal)
        case "kdeconnect_contacts": ("person.crop.circle", .brown)
        case "kdeconnect_findmyphone": ("speaker.wave.3", .orange)
        case "kdeconnect_findthisdevice": ("location", .orange)
        case "kdeconnect_lockdevice": ("lock", .gray)
        case "kdeconnect_mousepad": ("cursorarrow", .indigo)
        case "kdeconnect_mpriscontrol", "kdeconnect_mprisremote": ("play", .pink)
        case "kdeconnect_notifications": ("bell.badge", .red)
        case "kdeconnect_sendnotifications": ("bell", .red)
        case "kdeconnect_pausemusic": ("pause", .pink)
        case "kdeconnect_ping": ("dot.radiowaves.left.and.right", .cyan)
        case "kdeconnect_presenter": ("rectangle.on.rectangle", .purple)
        case "kdeconnect_remotecommands", "kdeconnect_runcommand": ("terminal", .gray)
        case "kdeconnect_remotecontrol": ("hand.point.up.left", .indigo)
        case "kdeconnect_remotekeyboard": ("keyboard", .indigo)
        case "kdeconnect_screensaver_inhibit": ("moon.zzz", .purple)
        case "kdeconnect_sftp": ("folder", .blue)
        case "kdeconnect_share": ("square.and.arrow.up", .blue)
        case "kdeconnect_sms": ("message", .green)
        case "kdeconnect_systemvolume": ("speaker.wave.2", .pink)
        case "kdeconnect_telephony": ("phone", .green)
        case "kdeconnect_virtualmonitor": ("display", .teal)
        case "kdeconnect_bigscreen": ("tv", .orange)
        default: ("puzzlepiece.extension", .gray)
        }
    }
}
