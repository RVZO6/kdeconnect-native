import Foundation
import Testing
@testable import KDEConnectKit

struct PluginNameTests {
    static let names: [(String, String)] = [
        ("kdeconnect_battery", "Battery monitor"),
        ("kdeconnect_bigscreen", "Bigscreen"),
        ("kdeconnect_clipboard", "Clipboard sync"),
        ("kdeconnect_connectivity_report", "Connectivity monitor"),
        ("kdeconnect_contacts", "Contacts"),
        ("kdeconnect_findmyphone", "Ring my phone"),
        ("kdeconnect_findthisdevice", "Find this device"),
        ("kdeconnect_lockdevice", "Lock device"),
        ("kdeconnect_mousepad", "Remote input"),
        ("kdeconnect_mpriscontrol", "Media control receiver"),
        ("kdeconnect_mprisremote", "Media controls"),
        ("kdeconnect_notifications", "Receive notifications"),
        ("kdeconnect_pausemusic", "Pause media during calls"),
        ("kdeconnect_ping", "Ping"),
        ("kdeconnect_presenter", "Presentation remote"),
        ("kdeconnect_remotecommands", "Host remote commands"),
        ("kdeconnect_remotecontrol", "Remote control"),
        ("kdeconnect_remotekeyboard", "Remote keyboard"),
        ("kdeconnect_runcommand", "Run commands"),
        ("kdeconnect_screensaver_inhibit", "Inhibit screensaver"),
        ("kdeconnect_sendnotifications", "Send notifications"),
        ("kdeconnect_sftp", "Remote filesystem browser"),
        ("kdeconnect_share", "Share and receive"),
        ("kdeconnect_sms", "SMS"),
        ("kdeconnect_systemvolume", "System volume"),
        ("kdeconnect_telephony", "Telephony integration"),
        ("kdeconnect_virtualmonitor", "Virtual monitor"),
    ]

    @Test func supportedPluginNamesAreUnchanged() {
        for (id, name) in Self.names { #expect(Plugin.displayName(for: id) == name) }
    }

    @Test func unknownNamesKeepTheirFallback() {
        #expect(Plugin.displayName(for: "kdeconnect_custom_plugin") == "Custom Plugin")
        #expect(Plugin.displayName(for: "external_plugin") == "External Plugin")
        #expect(Plugin.displayName(for: "kdeconnect_") == "")
        #expect(Plugin.displayName(for: "") == "")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDECONNECT_PERF"] == "1"))
    func nameLookupBenchmark() {
        let ids = Self.names.map(\.0)
        for workload in ["lookup", "sort-and-label"] {
            var samples: [Double] = []
            var checksum = 0
            let iterations = workload == "lookup" ? 10_000 : 500
            for sample in 0..<8 {
                let start = ContinuousClock.now
                for index in 0..<iterations {
                    if workload == "lookup" {
                        checksum &+= Plugin.displayName(for: ids[index % ids.count]).utf8.count
                    } else {
                        let sorted = ids.sorted {
                            Plugin.displayName(for: $0).localizedCaseInsensitiveCompare(Plugin.displayName(for: $1)) == .orderedAscending
                        }
                        // The UI also reads labels after sorting.
                        for id in sorted { checksum &+= Plugin.displayName(for: id).utf8.count }
                    }
                }
                let elapsed = start.duration(to: .now).components
                let ns = Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9
                if sample > 0 { samples.append(ns / Double(iterations)) }
            }
            print("plugin-names workload=\(workload) samples-ns=\(samples) median-ns=\(samples.sorted()[3]) checksum=\(checksum)")
        }
    }
}
