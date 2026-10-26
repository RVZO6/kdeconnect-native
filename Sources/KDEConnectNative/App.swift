import KDEConnectKit
import ServiceManagement
import SwiftUI

@main
struct KDEConnectNativeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = KDEConnectStore()
    @AppStorage("keepWindowOnTop") private var keepWindowOnTop = true

    var body: some Scene {
        Window("KDE Connect", id: MainWindow.id) {
            MainWindow()
                .environment(store)
        }
        .defaultSize(width: 900, height: 620)
        // The window follows the content's size range (see MainWindow), so
        // it cannot grow past a size where the layout still works.
        .windowResizability(.contentSize)
        // A companion window: it stays above other apps' windows.
        .windowLevel(keepWindowOnTop ? .floating : .normal)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            // The View menu's sidebar command uses the same animated path
            // as the sidebar button.
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebarRequest, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
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
        // At the main window's level; at the normal level, the floating main
        // window would cover it.
        .windowLevel(keepWindowOnTop ? .floating : .normal)
    }
}

struct StatusIcon: View {
    let store: KDEConnectStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: store.primaryDevice != nil ? "iphone" : "iphone.slash")
            .onAppear {
                WindowOpener.shared.open = { openWindow(id: MainWindow.id) }
                WindowOpener.shared.openSettings = { openSettings() }
            }
            .onChange(of: store.pairingRequests) { _, requests in PairingPrompt.requestsChanged(requests) }
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
    var openSettings: (() -> Void)?
    /// Set at launch; used by the debug capture to select a device.
    var store: KDEConnectStore?
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
        WindowOpener.shared.store = store
        let args = CommandLine.arguments
        if args.contains("--ui-benchmark"), !args.contains("--demo") {
            print("--ui-benchmark requires --demo; no live device data is used")
            NSApp.terminate(nil)
            return
        }
        if args.contains("--demo") {
            func count(after flag: String) -> Int? {
                guard let index = args.firstIndex(of: flag), index + 1 < args.count,
                      let value = Int(args[index + 1]) else { return nil }
                return max(0, min(value, 5_000))
            }
            store.showDemo(notificationCount: count(after: "--demo-notifications"),
                           appCount: count(after: "--demo-apps") ?? 20,
                           replyEvery: count(after: "--demo-reply-every") ?? 1)
        } else {
            store.start()
        }
        if let index = args.firstIndex(of: "--ui-benchmark"), index + 1 < args.count {
            await UIBenchmark.run(to: args[index + 1])
            return
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            await Snapshot.write(store: store, to: args[index + 1])
            return
        }
        if let index = args.firstIndex(of: "--window-snapshot"), index + 1 < args.count {
            await SidebarTest.captureWindow(to: args[index + 1])
            return
        }
        if let index = args.firstIndex(of: "--plugin-snapshot"), index + 2 < args.count {
            await Snapshot.writePluginSheet(store: store, plugin: args[index + 1], to: args[index + 2])
            return
        }
        if let index = args.firstIndex(of: "--stack-test"), index + 1 < args.count {
            await SidebarTest.stackTest(outputDirectory: args[index + 1])
            return
        }
        if let index = args.firstIndex(of: "--swipe-test"), index + 1 < args.count {
            await SidebarTest.swipeTest(outputDirectory: args[index + 1])
            return
        }
        if let index = args.firstIndex(of: "--enter-test"), index + 1 < args.count {
            await SidebarTest.enterTest(outputDirectory: args[index + 1])
            return
        }
        if args.contains("--tab-test") {
            await SidebarTest.tabTest()
            return
        }
        if args.contains("--resize-test") {
            await SidebarTest.resizeTest()
            return
        }
        if args.contains("--sidebar-test") {
            await SidebarTest.run()
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

extension Snapshot {
    /// Debug aid: `--plugin-snapshot kdeconnect_clipboard out.png` renders a
    /// plugin settings sheet for the first paired device.
    static func writePluginSheet(store: KDEConnectStore, plugin: String, to path: String) async {
        try? await Task.sleep(for: .seconds(3))
        guard let device = store.pairedDevices.first else { NSApp.terminate(nil); return }
        let host = NSHostingView(rootView: PluginSettingsSheet(device: device, plugin: plugin).environment(store))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.frame.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
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

/// Debug aid: `--sidebar-test` opens the main window, toggles the sidebar,
/// and prints the sidebar width over time: first for one toggle, then for a
/// burst of fast toggles.
@MainActor
enum SidebarTest {
    static func run() async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) else {
            print("no window")
            NSApp.terminate(nil)
            return
        }
        // Smaller than the maximum, where the user saw the window jump.
        window.setFrame(NSRect(x: 200, y: 200, width: 820, height: 600), display: true)
        try? await Task.sleep(for: .milliseconds(400))
        func toggle() { NotificationCenter.default.post(name: .toggleSidebarRequest, object: nil) }
        print("toolbar items:", window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])
        // Logs every toolbar item that is added or removed while the test runs.
        nonisolated(unsafe) var changes: [String] = []
        let start = ContinuousClock.now
        for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window.toolbar, queue: nil) { n in
                nonisolated(unsafe) let note = n
                MainActor.assumeIsolated {
                    let id = (note.userInfo?["item"] as? NSToolbarItem)?.itemIdentifier.rawValue ?? "?"
                    let sign = note.name == NSToolbar.willAddItemNotification ? "+" : "-"
                    changes.append("\(sign)\(id.suffix(14)) @\(Int((ContinuousClock.now - start) / .milliseconds(1)))ms")
                }
            }
        }
        func shoot(_ name: String) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), NSTemporaryDirectory() + name]
            try? task.run()
            task.waitUntilExit()
        }
        shoot("sidebar-open.png")
        toggle()
        try? await Task.sleep(for: .milliseconds(600))
        shoot("sidebar-closed.png")
        toggle()
        try? await Task.sleep(for: .milliseconds(600))
        print("captures in", NSTemporaryDirectory())
        // Fast frames of the whole window during one close and one open.
        if let frameView = window.contentView?.superview {
            let dir = NSTemporaryDirectory() + "kdcn-toggle-frames"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var shot = 0
            for _ in 0..<2 {
                toggle()
                for _ in 0..<14 {
                    if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: String(format: "%@/f%02d.png", dir, shot)))
                    }
                    shot += 1
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            print("toggle frames in", dir)
        }
        print("toolbar changes during the test:", changes.isEmpty ? ["none"] : changes)
        NSApp.terminate(nil)
    }

    /// Debug aid: `--demo --swipe-test <dir>` posts a synthetic two-finger
    /// swipe over the first notification card and saves window images in
    /// the middle of the swipe and after it.
    static func swipeTest(outputDirectory: String) async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2.5))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }),
              let store = WindowOpener.shared.store else { NSApp.terminate(nil); return }
        func shoot(_ name: String) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), outputDirectory + "/" + name]
            try? task.run()
            task.waitUntilExit()
        }
        // Use the actual hit region. A fixed offset can land just below
        // the first card when the window size or text layout changes.
        func catchers(in view: NSView) -> [HorizontalSwipeCatcher.CatcherView] {
            let own = (view as? HorizontalSwipeCatcher.CatcherView).map { [$0] } ?? []
            return own + view.subviews.flatMap { catchers(in: $0) }
        }
        func targets() -> [HorizontalSwipeCatcher.CatcherView] {
            guard let content = window.contentView else { return [] }
            return catchers(in: content).filter {
                $0.active && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.intersection($0.bounds).isEmpty
            }
        }
        guard let first = targets().max(by: {
            $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY
        }) else { print("no swipe target"); NSApp.terminate(nil); return }
        let location = window.convertPoint(toScreen: first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil))
        let point = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
        let targetsBefore = targets().count
        func post(dx: CGFloat, phase: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { return }
            cg.location = point
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cg) { NSApp.postEvent(event, atStart: false) }
        }
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        let before = store.selectedDevice?.notifications.count ?? 0
        post(dx: -8, phase: 1)  // began
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(16))
            post(dx: -12, phase: 2)  // changed
        }
        try? await Task.sleep(for: .milliseconds(150))
        shoot("swipe-mid.png")
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(16))
            post(dx: -14, phase: 2)
        }
        post(dx: 0, phase: 4)  // ended
        try? await Task.sleep(for: .milliseconds(700))
        shoot("swipe-after.png")
        // The other way, on the card that is now first.
        post(dx: 8, phase: 1)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(16))
            post(dx: 14, phase: 2)
        }
        try? await Task.sleep(for: .milliseconds(150))
        shoot("swipe-right-mid.png")
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(16))
            post(dx: 14, phase: 2)
        }
        post(dx: 0, phase: 4)
        try? await Task.sleep(for: .milliseconds(700))
        shoot("swipe-right-after.png")
        print("cards after: \(store.selectedDevice?.notifications.count ?? 0) (demo keeps the data; the view hides dismissed cards)")
        print("cards before: \(before)")
        print("visible swipe targets: \(targetsBefore) -> \(targets().count)")
        NSApp.terminate(nil)
    }

    /// Debug aid: `--demo --stack-test <dir>` expands, then collapses the
    /// notification stacks and saves window frames during each animation.
    static func stackTest(outputDirectory: String) async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2.5))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) else {
            NSApp.terminate(nil); return
        }
        func shoot(_ name: String) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), outputDirectory + "/" + name]
            try? task.run()
            task.waitUntilExit()
        }
        shoot("stack-0-collapsed.png")
        for phase in ["open", "close"] {
            NotificationCenter.default.post(name: .debugToggleStacks, object: nil)
            for ms in [60, 140, 240] {
                try? await Task.sleep(for: .milliseconds(ms == 60 ? 60 : ms == 140 ? 80 : 100))
                shoot("stack-\(phase)-\(ms)ms.png")
            }
            try? await Task.sleep(for: .milliseconds(600))
            shoot("stack-\(phase)-end.png")
        }
        NSApp.terminate(nil)
    }

    /// Debug aid: `--demo --enter-test <dir>` adds a notification to an
    /// existing app group, then one for a new app, and saves fast frames of
    /// the page during each entry.
    static func enterTest(outputDirectory: String) async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2.5))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }),
              let frameView = window.contentView?.superview, let store = WindowOpener.shared.store else {
            NSApp.terminate(nil); return
        }
        var shot = 0
        for (app, title) in [("Messages", "Sam"), ("Weather", "Rain at 5 pm")] {
            store.addDemoNotification(app: app, title: title, text: "A new notification for the enter animation.")
            for _ in 0..<12 {
                if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: String(format: "%@/e%02d.png", outputDirectory, shot)))
                }
                shot += 1
                try? await Task.sleep(for: .milliseconds(35))
            }
        }
        NSApp.terminate(nil)
    }

    /// Debug aid: `--demo --tab-test` switches the device page between its
    /// tabs and prints how long the main thread takes to lay out and draw
    /// the window after each switch.
    static func tabTest() async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2.5))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) else {
            NSApp.terminate(nil); return
        }
        var results: [String] = []
        for name in ["Plugins", "Details", "Overview", "Plugins", "Details", "Overview", "Plugins", "Details", "Overview"] {
            func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d / .microseconds(1)) / 1000) }
            let t0 = ContinuousClock.now
            NotificationCenter.default.post(name: .debugSelectPage, object: name)
            let t1 = ContinuousClock.now
            window.contentView?.layoutSubtreeIfNeeded()
            let t2 = ContinuousClock.now
            window.displayIfNeeded()
            let t3 = ContinuousClock.now
            // Let SwiftUI finish the update it scheduled, then draw again.
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            let t4 = ContinuousClock.now
            window.displayIfNeeded()
            let t5 = ContinuousClock.now
            results.append("\(name) \(ms(t5 - t0)) [state \(ms(t1 - t0)) layout \(ms(t2 - t1)) draw \(ms(t3 - t2)) layout2 \(ms(t4 - t3)) draw2 \(ms(t5 - t4))]")
            try? await Task.sleep(for: .milliseconds(400))
        }
        print("tab switches:\n " + results.joined(separator: "\n "))
        NSApp.terminate(nil)
    }

    /// Debug aid: `--demo --resize-test` drags the sidebar's edge 60 pt to
    /// the right with posted mouse events and prints the stored width.
    static func resizeTest() async {
        UserDefaults.standard.set(250.0, forKey: "sidebarWidth")
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) else {
            NSApp.terminate(nil); return
        }
        let before = UserDefaults.standard.double(forKey: "sidebarWidth")
        // A click in an inactive window only activates it, so start active.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        func post(_ type: NSEvent.EventType, x: CGFloat) {
            let point = NSPoint(x: x, y: window.contentLayoutRect.midY)
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        post(.leftMouseDown, x: 251)
        for step in 1...12 {
            try? await Task.sleep(for: .milliseconds(16))
            post(.leftMouseDragged, x: 251 + CGFloat(step * 5))
        }
        post(.leftMouseUp, x: 311)
        try? await Task.sleep(for: .milliseconds(400))
        print("sidebar width before \(before), after \(UserDefaults.standard.double(forKey: "sidebarWidth"))")
        UserDefaults.standard.set(before, forKey: "sidebarWidth")
        // Then open Settings and print each window's level: Settings must
        // not sit below the floating main window.
        WindowOpener.shared.openSettings?()
        try? await Task.sleep(for: .seconds(1))
        for w in NSApp.windows where w.isVisible {
            print("window \(w.title.isEmpty ? w.identifier?.rawValue ?? "?" : w.title): level \(w.level.rawValue)")
        }
        NSApp.terminate(nil)
    }

    /// Opens the main window and saves an image of it, title bar included.
    static func captureWindow(to path: String) async {
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2))
        if let store = WindowOpener.shared.store, store.selectedDeviceId == nil {
            store.selectedDeviceId = store.primaryDevice?.id ?? store.pairedDevices.first?.id
        }
        try? await Task.sleep(for: .seconds(1.5))
        if let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) {
            print("window level \(window.level.rawValue) (floating is \(NSWindow.Level.floating.rawValue)),",
                  "content min \(window.contentMinSize), max \(window.contentMaxSize), frame \(window.frame.size)")
            // A real screen capture shows Liquid Glass; cacheDisplay does not.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.replacingOccurrences(of: ".png", with: "-screen.png")]
            try? task.run()
            task.waitUntilExit()
            // Then scroll the page, so that content is under the header bar.
            NotificationCenter.default.post(name: .debugScrollPage, object: nil)
            try? await Task.sleep(for: .milliseconds(600))
            let again = Process()
            again.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            again.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                               path.replacingOccurrences(of: ".png", with: "-scrolled.png")]
            try? again.run()
            again.waitUntilExit()
        }
        if let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }),
           let frame = window.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
