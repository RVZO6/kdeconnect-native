import KDEConnectKit
import ServiceManagement
import SwiftUI

@main
struct KDEConnectNativeApp: App {
    @State private var store = KDEConnectStore()
    @AppStorage("showBatteryInMenuBar") private var showBattery = true

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(store)
        } label: {
            // The label exists from launch, so it starts the supervisor.
            MenuBarLabel(store: store, showBattery: showBattery)
                .task {
                    store.start()
                    await Snapshot.writeIfRequested(store: store)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct MenuBarLabel: View {
    let store: KDEConnectStore
    let showBattery: Bool

    var body: some View {
        if let device = store.primaryDevice {
            if showBattery, let battery = device.battery {
                Label("\(battery.charge)%", systemImage: device.kind.symbol).labelStyle(.titleAndIcon)
            } else {
                Image(systemName: device.kind.symbol)
            }
        } else {
            Image(systemName: store.status == .connected ? "iphone.slash" : "iphone.slash.circle")
                .help("KDE Connect")
        }
    }
}

extension Device.Kind {
    var symbol: String {
        switch self {
        case .phone, .unknown: "iphone"
        case .tablet: "ipad"
        case .desktop: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .tv: "tv"
        }
    }
}

/// Wraps the main-app login item so that the toggle reflects the real state.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Debug aid: `KDEConnectNative --snapshot out.png` renders the menu panel
/// to a PNG after the first refresh, then quits.
@MainActor
enum Snapshot {
    static func writeIfRequested(store: KDEConnectStore) async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        try? await Task.sleep(for: .seconds(4))
        // An off-screen window renders AppKit-backed views, which ImageRenderer cannot.
        let host = NSHostingView(rootView: MenuContent().environment(store).background(.background))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(300))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[index + 1]))
        }
        NSApp.terminate(nil)
    }
}
