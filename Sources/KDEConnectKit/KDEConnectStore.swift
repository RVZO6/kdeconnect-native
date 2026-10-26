import AppKit
import DBusKit
import Foundation
import Observation
import os

private let log = Logger(subsystem: "app.kdeconnect-native", category: "supervisor")

/// App state: keeps a live connection to kdeconnectd and a device list.
///
/// A supervisor loop checks the connection every few seconds. It reconnects
/// when the daemon moves to a new private bus, and (optionally) starts or
/// restarts the daemon when it is missing or stuck on a dead bus.
@MainActor
@Observable
public final class KDEConnectStore {
    public enum Status: Equatable {
        case starting
        case connected
        case daemonStopped
        case notInstalled
    }

    public private(set) var status: Status = .starting
    public private(set) var devices: [Device] = []
    public private(set) var announcedName = ""
    public private(set) var lastError: String?
    public private(set) var linkProviders: [LinkProvider] = []
    public private(set) var customDevices: [String] = []
    /// Enabled state of each supported plugin, by device ID. The store loads
    /// it in the background, so that a device page has it from the first frame.
    public private(set) var pluginStates: [String: [String: Bool]] = [:]
    @ObservationIgnored private var stalePluginStates: Set<String> = []
    /// The device that the main window shows.
    public var selectedDeviceId: String?
    /// True while the main window shows the pairing sheet.
    public var isPairingSheetShown = false

    public var autoStartDaemon: Bool {
        didSet { UserDefaults.standard.set(autoStartDaemon, forKey: Self.autoStartKey) }
    }

    private static let autoStartKey = "autoStartDaemon"

    @ObservationIgnored private let locator = DaemonLocator()
    @ObservationIgnored private lazy var process = DaemonProcess(locator: locator)
    @ObservationIgnored private var client: KDEConnectClient?
    @ObservationIgnored private var connectedAddress: String?
    @ObservationIgnored private var superviseTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var lastLaunch: ContinuousClock.Instant?
    @ObservationIgnored private var launchBackoff: Duration = .seconds(10)
    @ObservationIgnored private var unreachableSince: ContinuousClock.Instant?
    /// The tail of the lifecycle queue. Supervisor steps, wake handling and
    /// restarts run one at a time, because each one suspends at many points
    /// and must not see the others' half-done work.
    @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
    @ObservationIgnored private var restartQueued = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    public init() {
        autoStartDaemon = UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool ?? true
    }

    // MARK: Derived state

    public var pairedDevices: [Device] { devices.filter(\.isPaired) }
    public var pairingRequests: [Device] { devices.filter { !$0.isPaired && $0.isPairRequestedByPeer } }
    public var availableDevices: [Device] {
        devices.filter { !$0.isPaired && !$0.isPairRequestedByPeer && $0.isReachable }
    }
    public var primaryDevice: Device? { pairedDevices.first(where: \.isReachable) }

    // MARK: Lifecycle

    public func start() {
        guard superviseTask == nil else { return }
        superviseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.serialized { await $0.superviseStep() }
                let interval: Duration = self.status == .connected ? .seconds(5) : .seconds(2)
                try? await Task.sleep(for: interval)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleWake() }
        }
    }

    private func handleWake() async {
        await serialized { store in
            // After sleep the LAN links are often dead. Ask for a fresh
            // announcement so that devices reconnect without a manual refresh.
            try? await store.client?.forceOnNetworkChange()
            await store.superviseStep()
            store.scheduleRefresh()
        }
    }

    /// Runs `body` after every lifecycle operation queued before it.
    private func serialized(_ body: @escaping @MainActor (KDEConnectStore) async -> Void) async {
        let previous = lifecycleTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await body(self)
        }
        lifecycleTail = task
        await task.value
    }

    /// Starts, or restarts, are allowed at most once per backoff interval.
    /// The interval doubles on each attempt and resets after a good connection.
    private func takeLaunchSlot() -> Bool {
        let now = ContinuousClock.now
        if let lastLaunch, now - lastLaunch < launchBackoff { return false }
        launchBackoff = lastLaunch == nil ? .seconds(10) : min(launchBackoff * 2, .seconds(300))
        lastLaunch = now
        return true
    }

    /// One supervisor step. Call it only through `serialized`.
    private func superviseStep() async {
        guard locator.bundleURL != nil else {
            disconnect()
            status = .notInstalled
            return
        }
        let currentAddress = locator.currentBusAddress()
        if let client, !client.connection.isClosed, connectedAddress == currentAddress,
           (try? await client.isDaemonRegistered()) == true {
            unreachableSince = nil
            return
        }
        disconnect()

        var busAlive = false
        if let address = currentAddress {
            switch await connect(address: address) {
            case .connected: return
            case .busOnly: busAlive = true
            case .unreachable: break
            }
        }
        status = .daemonStopped
        devices = []
        guard autoStartDaemon else { return }

        let now = ContinuousClock.now
        if process.isDaemonRunning {
            // If the bus answers, the daemon may still be starting, so give it
            // time. If the bus is gone, the daemon is orphaned for certain.
            let grace: Duration = busAlive ? .seconds(20) : .seconds(4)
            let since = unreachableSince ?? now
            unreachableSince = since
            if now - since >= grace, takeLaunchSlot() {
                log.notice("kdeconnectd runs but is unreachable (bus alive: \(busAlive)); restarting it")
                await restartStep()
            }
            return
        }
        unreachableSince = nil
        guard takeLaunchSlot() else { return }
        log.notice("kdeconnectd is not running; starting it")
        await launch(reusing: busAlive ? currentAddress : nil)
    }

    /// Starts kdeconnectd, on the given bus or on a new private bus.
    private func launch(reusing busAddress: String?) async {
        status = .starting
        do {
            let address: String
            if let busAddress {
                address = busAddress
            } else {
                address = try await process.launchBus()
            }
            try process.launchDaemon(busAddress: address)
        } catch {
            lastError = "Could not start kdeconnectd: \(error)"
            log.error("Could not start kdeconnectd: \(String(describing: error), privacy: .public)")
        }
    }

    private enum ConnectResult {
        case connected
        /// The bus answers, but kdeconnectd has not registered on it.
        case busOnly
        case unreachable
    }

    private func connect(address: String) async -> ConnectResult {
        let connection: DBusConnection
        do {
            connection = try await DBusConnection.connect(address: address)
        } catch {
            log.info("Connect to \(address, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .unreachable
        }
        do {
            let client = KDEConnectClient(connection: connection)
            guard try await client.isDaemonRegistered() else {
                connection.close()
                return .busOnly
            }
            connection.setSignalHandler { [weak self] message in
                Task { @MainActor in self?.handleSignal(message) }
            }
            try await client.subscribeToSignals()
            self.client = client
            connectedAddress = address
            log.notice("Connected to kdeconnectd at \(address, privacy: .public)")
            status = .connected
            lastError = nil
            unreachableSince = nil
            lastLaunch = nil
            launchBackoff = .seconds(10)
            announcedName = (try? await client.announcedName()) ?? ""
            scheduleRefresh()
            return .connected
        } catch {
            connection.close()
            return .unreachable
        }
    }

    private func disconnect() {
        if let connectedAddress { log.notice("Disconnecting from \(connectedAddress, privacy: .public)") }
        client?.connection.setSignalHandler(nil)
        client?.connection.close()
        client = nil
        connectedAddress = nil
    }

    /// Stops kdeconnectd and all bundled dbus-daemons (including stale
    /// ones), then starts a fresh daemon.
    public func restartDaemon() async {
        // Pressing the button many times must not queue many restarts.
        guard !restartQueued else { return }
        restartQueued = true
        // The flag stays set while the restart waits and while it runs.
        await serialized { store in
            await store.restartStep()
            store.restartQueued = false
        }
    }

    /// Call it only through `serialized`.
    private func restartStep() async {
        log.notice("Restarting kdeconnectd and its private buses")
        disconnect()
        status = .starting
        devices = []
        await process.stopAll()
        unreachableSince = nil
        await launch(reusing: nil)
    }

    // MARK: Refresh

    private func handleSignal(_ message: DBusMessage) {
        guard message.sender != nil else { return }
        // The daemon emits pluginsChanged on /modules/kdeconnect/devices/<id>.
        if message.member == "pluginsChanged", let id = message.path?.split(separator: "/").last {
            stalePluginStates.insert(String(id))
        }
        scheduleRefresh()
    }

    /// Coalesces bursts of signals into one refresh.
    public func scheduleRefresh() {
        if refreshTask != nil {
            refreshAgain = true
            return
        }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                await self.refresh()
            } while self.refreshAgain
            self.refreshTask = nil
        }
    }

    private func refresh() async {
        guard let client else { return }
        do {
            let ids = try await client.deviceIds()
            var result: [Device] = []
            for id in ids {
                if let device = try? await client.device(id) { result.append(device) }
            }
            // Plugin states change rarely, so read them only for new devices,
            // after a pluginsChanged signal, or when the plugin list changes.
            var states = pluginStates
            for device in result where device.isPaired {
                let cached = states[device.id]
                guard cached == nil || stalePluginStates.contains(device.id)
                        || Set(cached!.keys) != Set(device.supportedPlugins) else { continue }
                if let loaded = try? await client.pluginStates(device.id, plugins: device.supportedPlugins) {
                    states[device.id] = loaded
                    stalePluginStates.remove(device.id)
                }
            }
            let providers = (try? await client.linkProviders()) ?? linkProviders
            let custom = (try? await client.customDevices()) ?? customDevices
            let name = (try? await client.announcedName()) ?? announcedName
            guard self.client?.connection === client.connection else { return }
            linkProviders = providers
            customDevices = custom
            announcedName = name
            pluginStates = states
            devices = result.sorted { a, b in
                if a.isReachable != b.isReachable { return a.isReachable }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            // A failed refresh usually means the bus went away; the
            // supervisor handles that on its next step.
        }
    }

    // MARK: Actions

    /// Runs a daemon call and shows its error to the user.
    public func perform(_ action: String, _ body: @escaping @Sendable (KDEConnectClient) async throws -> Void) {
        guard let client else {
            if !isDemo { lastError = "\(action) failed: KDE Connect is not running" }
            return
        }
        Task {
            do {
                try await body(client)
                lastError = nil
            } catch {
                lastError = "\(action) failed: \(error)"
            }
            scheduleRefresh()
        }
    }

    public func clearError() { lastError = nil }

    /// True in demo mode, where daemon calls do nothing.
    @ObservationIgnored private var isDemo = false

    /// Debug aid: fills the store with a sample connected phone, without a
    /// daemon, so that the UI can be checked. Do not call `start()` as well.
    public func showDemo(notificationCount: Int? = nil, appCount: Int = 20) {
        isDemo = true
        status = .connected
        announcedName = "This Mac"
        var phone = Device(id: "demo_phone", properties: [
            "name": .string("Sample Phone"), "type": .string("phone"), "isReachable": .bool(true),
            "isPaired": .bool(true), "verificationKey": .string("A1B2C3D4"),
            "activeProviderNames": .stringArray(["LAN"]), "reachableAddresses": .stringArray(["192.168.1.20"]),
            "supportedPlugins": .stringArray([Plugin.battery.rawValue, Plugin.clipboard.rawValue,
                                              Plugin.findMyPhone.rawValue, Plugin.ping.rawValue,
                                              Plugin.share.rawValue, Plugin.notifications.rawValue]),
        ])
        phone.loadedPlugins = Set(phone.supportedPlugins)
        phone.battery = .init(charge: 64, isCharging: false)
        phone.cellular = .init(networkType: "5G", strength: 3)
        phone.notifications = [
            PhoneNotification(id: "2", properties: ["appName": .string("Messages"), "title": .string("Alex"),
                                                    "text": .string("Are we still on for 6?"), "dismissable": .bool(true),
                                                    "replyId": .string("r2")]),
            PhoneNotification(id: "1", properties: ["appName": .string("Calendar"), "title": .string("Stand-up"),
                                                    "text": .string("In 10 minutes"), "dismissable": .bool(true)]),
        ] + (3...9).map { n in
            PhoneNotification(id: String(n), properties: [
                "appName": .string("Mail"), "title": .string("Message \(n)"),
                "text": .string("A sample notification, so that the page can scroll."), "dismissable": .bool(true),
            ])
        }
        if let notificationCount {
            phone.notifications = (0..<max(0, notificationCount)).map { index in
                PhoneNotification(id: String(notificationCount - index), properties: [
                    "appName": .string("Sample App \(index % max(1, appCount) + 1)"),
                    "title": .string("Message \(notificationCount - index)"),
                    "text": .string("A sample notification for scrolling and stack tests. Some text wraps onto another line."),
                    "dismissable": .bool(true), "replyId": .string("reply-\(index)"),
                ])
            }
        }
        let laptop = Device(id: "demo_laptop", properties: [
            "name": .string("Sample Laptop"), "type": .string("laptop"), "isPaired": .bool(true),
        ])
        devices = [phone, laptop]
        pluginStates[phone.id] = Dictionary(uniqueKeysWithValues: phone.supportedPlugins.map { ($0, true) })
        selectedDeviceId = phone.id
    }
    public func reportError(_ message: String) { lastError = message }

    public var selectedDevice: Device? { devices.first { $0.id == selectedDeviceId } }

    /// True while a network search runs, for the spinning refresh arrow.
    public private(set) var isRefreshing = false

    /// Asks the daemon to announce itself again on every network. Devices
    /// answer over the next moments, so the search counts as running for a
    /// short time after the call returns.
    public func refreshNetwork() {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                try await client.forceOnNetworkChange()
            } catch {
                lastError = "Refresh failed: \(error)"
            }
            try? await Task.sleep(for: .seconds(1.5))
            scheduleRefresh()
            isRefreshing = false
        }
    }

    public func setAnnouncedName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != announcedName else { return }
        perform("Rename this device") { try await $0.setAnnouncedName(trimmed) }
    }

    public func setLinkProvider(_ id: String, enabled: Bool) {
        perform("Change connection type") { try await $0.setLinkProvider(id, enabled: enabled) }
    }

    public func addCustomDevice(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !customDevices.contains(trimmed) else { return }
        let list = customDevices + [trimmed]
        customDevices = list
        perform("Add device address") { try await $0.setCustomDevices(list) }
    }

    public func removeCustomDevice(_ address: String) {
        let list = customDevices.filter { $0 != address }
        customDevices = list
        perform("Remove device address") { try await $0.setCustomDevices(list) }
    }

    /// Reads which plugins are enabled for a device. Nil when not connected.
    /// Writes plugin settings, then tells the daemon to read them again.
    public func savePluginConfig(_ config: PluginConfig, _ changes: [String: PluginConfig.Value]) {
        do {
            try config.write(changes)
        } catch {
            lastError = "Could not save the plugin settings: \(error.localizedDescription)"
            return
        }
        guard let client else {
            lastError = "The settings are saved. KDE Connect uses them after its next start."
            return
        }
        do {
            try client.connection.send(config.changedSignal)
        } catch {
            lastError = "The settings are saved, but KDE Connect did not get the change: \(error)"
        }
    }

    public func setPluginEnabled(deviceId: String, plugin: String, enabled: Bool) {
        // Show the change at once; the pluginsChanged signal confirms it.
        pluginStates[deviceId, default: [:]][plugin] = enabled
        stalePluginStates.insert(deviceId)
        perform("Change plugin") { try await $0.setPluginEnabled(deviceId, plugin: plugin, enabled: enabled) }
    }

    public func openSMSApp() { runBundled(locator.smsAppURL, name: "KDE Connect SMS") }

    /// Runs a helper app from the KDE Connect bundle. They are plain
    /// executables, so NSWorkspace cannot open them as apps.
    private func runBundled(_ url: URL?, name: String) {
        guard let url else {
            lastError = "\(name) is not installed"
            return
        }
        let process = Process()
        process.executableURL = url
        if let address = connectedAddress {
            process.environment = DaemonProcess.environment(busAddress: address)
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { lastError = "Could not open \(name): \(error)" }
    }

    public var daemonLogURL: URL { DaemonProcess.logURL }
}
