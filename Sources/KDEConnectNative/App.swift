import KDEConnectKit
import ServiceManagement
import SwiftUI

@main
struct KDEConnectNativeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = KDEConnectStore()

    var body: some Scene {
        Window("KDE Connect", id: MainWindow.id) {
            MainWindow()
                .environment(store)
        }
        .defaultSize(width: 900, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Devices") { store.refreshNetwork() }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            StatusMenu()
                .environment(store)
        } label: {
            // The label exists from launch, so it starts the supervisor and
            // gives the app delegate a way to open the main window.
            StatusIcon(store: store)
                .task { await appDelegate.didLaunch(store: store) }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct StatusIcon: View {
    let store: KDEConnectStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.primaryDevice != nil ? "iphone" : "iphone.slash")
            .onAppear { WindowOpener.shared.open = { openWindow(id: MainWindow.id) } }
    }
}

/// Lets AppKit code open the SwiftUI main window.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?

    func showMainWindow() {
        // An accessory app must become a regular app to own a key window
        // and a Dock icon. MainWindow switches back when it closes.
        NSApp.setActivationPolicy(.regular)
        open?()
        NSApp.activate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Starts the supervisor. A launch by the user opens the window; a
    /// launch at login stays in the menu bar.
    func didLaunch(store: KDEConnectStore) async {
        store.start()
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            await Snapshot.write(store: store, to: args[index + 1])
            return
        }
        if !launchedAsLoginItem {
            WindowOpener.shared.showMainWindow()
        }
    }

    /// Opening the app again (Finder, Spotlight, Dock) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowOpener.shared.showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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

/// Debug aid: `KDEConnectNative --snapshot out.png` renders the main window,
/// with the first reachable device selected, to a PNG, then quits.
@MainActor
enum Snapshot {
    static func write(store: KDEConnectStore, to path: String) async {
        try? await Task.sleep(for: .seconds(4))
        store.selectedDeviceId = store.primaryDevice?.id ?? store.pairedDevices.first?.id
        let host = NSHostingView(rootView: MainWindow().environment(store))
        host.frame.size = CGSize(width: 900, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.frame.size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1.5))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
