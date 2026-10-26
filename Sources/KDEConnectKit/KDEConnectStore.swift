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
    @ObservationIgnored private var isRestarting = false
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
                await self.supervise()
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
        // After sleep the LAN links are often dead. Ask for a fresh
        // announcement so that devices reconnect without a manual refresh.
        try? await client?.forceOnNetworkChange()
        await supervise()
        scheduleRefresh()
    }

    /// One supervisor step.
    func supervise() async {
        guard !isRestarting else { return }
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
            if now - since >= grace {
                log.notice("kdeconnectd runs but is unreachable (bus alive: \(busAlive)); restarting it")
                await restartDaemon()
            }
            return
        }
        unreachableSince = nil
        if let lastLaunch, now - lastLaunch < launchBackoff { return }
        launchBackoff = lastLaunch == nil ? .seconds(10) : min(launchBackoff * 2, .seconds(300))
        lastLaunch = now
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
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        log.notice("Restarting kdeconnectd and its private buses")
        disconnect()
        status = .starting
        devices = []
        await process.stopAll()
        lastLaunch = .now
        unreachableSince = nil
        await launch(reusing: nil)
    }

    // MARK: Refresh

    private func handleSignal(_ message: DBusMessage) {
        guard message.sender != nil else { return }
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
            guard self.client?.connection === client.connection else { return }
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
            lastError = "\(action) failed: KDE Connect is not running"
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

    public func openSettingsApp() { runBundled(locator.settingsAppURL, name: "KDE Connect settings") }
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
