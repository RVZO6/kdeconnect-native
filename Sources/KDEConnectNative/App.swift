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
                Button("Pair Device…") {
                    WindowOpener.shared.showMainWindow()
                    store.isPairingSheetShown = true
                }
                .keyboardShortcut("n")
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
            .onChange(of: store.pairingRequests.map(\.id)) { old, new in
                // Ask at once when a device wants to pair, also without the window.
                for id in new where !old.contains(id) {
                    guard let device = store.pairingRequests.first(where: { $0.id == id }) else { continue }
                    // A modal alert must not run inside a view update.
                    Task { PairingPrompt.show(device: device, store: store) }
                }
            }
            .onChange(of: store.lastError) { _, error in
                // The main window shows errors itself. Without it, actions
                // from the menu or Settings must not fail silently.
                guard let error, !WindowOpener.shared.isMainWindowVisible else { return }
                Task {
                    let alert = NSAlert()
                    alert.messageText = "KDE Connect"
                    alert.informativeText = error
                    NSApp.activate()
                    alert.runModal()
                    store.clearError()
                }
            }
    }
}

/// Lets AppKit code open the SwiftUI main window.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    var isMainWindowVisible: Bool { NSApp.windows.contains { Self.isMainWindow($0) && $0.isVisible } }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(MainWindow.id) == true
    }

    func showMainWindow() {
        // An accessory app must become a regular app to own a key window
        // and a Dock icon. It goes back to the menu bar when the window closes.
        // Change the policy only here and on close: a change while the window
        // is on screen makes AppKit lay the window out again.
        NSApp.setActivationPolicy(.regular)
        open?()
        NSApp.activate()
        closeObserver = closeObserver ?? NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            // The observer runs on the main queue, so the window is safe to use there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let window = object as? NSWindow, Self.isMainWindow(window) else { return }
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
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
        if let index = args.firstIndex(of: "--sidebar-test"), index + 1 < args.count {
            await SidebarTest.run(outputDirectory: args[index + 1])
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

/// Debug aid: `--sidebar-test <dir>` opens the main window, toggles the
/// sidebar quickly, and saves frames of the whole window (title bar included).
@MainActor
enum SidebarTest {
    static func run(outputDirectory: String) async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }),
              let frame = window.contentView?.superview else { NSApp.terminate(nil); return }
        var index = 0
        func capture(_ label: String) {
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let name = String(format: "%02d-%@.png", index, label)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
            index += 1
        }
        capture("start")
        for i in 0..<7 {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: window)
            try? await Task.sleep(for: .milliseconds(90))
            capture("toggle\(i)")
        }
        try? await Task.sleep(for: .seconds(1.5))
        capture("settled")
        NSApp.terminate(nil)
    }
}
