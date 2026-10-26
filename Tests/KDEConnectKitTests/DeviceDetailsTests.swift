import DBusKit
import Foundation
import Testing
@testable import KDEConnectKit

@Suite(.serialized)
struct DeviceDetailsTests {
    private let allPlugins: Set<String> = [Plugin.battery.rawValue, Plugin.connectivity.rawValue, Plugin.notifications.rawValue]

    private func read(_ plugins: Set<String>, using probe: DeviceReadProbe) async -> DeviceDetails {
        await readDeviceDetails(id: "phone", plugins: plugins,
                                properties: { try await probe.properties($0, $1) },
                                notifications: { try await probe.notifications($0) })
    }

    @Test func readsAllEnabledPlugins() async {
        let probe = DeviceReadProbe()
        let details = await read(allPlugins, using: probe)
        #expect(details.battery?.charge == 82)
        #expect(details.battery?.isCharging == true)
        #expect(details.cellular?.networkType == "5G")
        #expect(details.cellular?.strength == 3)
        #expect(details.notifications.map(\.id) == ["2"])
        #expect(Set(await probe.requests) == Set(["battery", "connectivity", "notifications"]))
        #expect(await probe.pathsAreCorrect)
    }

    @Test func disabledPluginsAreNotRead() async {
        let probe = DeviceReadProbe()
        let details = await read([Plugin.battery.rawValue], using: probe)
        #expect(details.battery?.charge == 82)
        #expect(details.cellular == nil)
        #expect(details.notifications.isEmpty)
        #expect(await probe.requests == ["battery"])
        let empty = DeviceReadProbe()
        let noDetails = await read([], using: empty)
        #expect(noDetails.battery == nil && noDetails.cellular == nil && noDetails.notifications.isEmpty)
        #expect(await empty.requests.isEmpty)
    }

    @Test func failedPluginsDoNotHideOtherData() async {
        let probe = DeviceReadProbe(failures: ["battery", "notifications"])
        let details = await read(allPlugins, using: probe)
        #expect(details.battery == nil)
        #expect(details.cellular?.networkType == "5G")
        #expect(details.notifications.isEmpty)
        #expect(Set(await probe.requests) == Set(["battery", "connectivity", "notifications"]))
    }

    @Test func invalidAndMissingPropertiesKeepExistingFallbacks() async {
        let noBattery = DeviceReadProbe(batteryProperties: ["hasBattery": .bool(false), "charge": .int32(82)],
                                        connectivityProperties: ["cellularNetworkType": .string("")])
        let details = await read(allPlugins, using: noBattery)
        #expect(details.battery == nil)
        #expect(details.cellular == nil)
        let defaults = DeviceReadProbe(batteryProperties: ["charge": .int32(7)],
                                       connectivityProperties: ["cellularNetworkType": .string("LTE")])
        let defaultDetails = await read(allPlugins, using: defaults)
        #expect(defaultDetails.battery?.charge == 7 && defaultDetails.battery?.isCharging == false)
        #expect(defaultDetails.cellular?.networkType == "LTE" && defaultDetails.cellular?.strength == -1)
        let negative = DeviceReadProbe(batteryProperties: ["charge": .int32(-1)])
        #expect(await read(allPlugins, using: negative).battery == nil)
    }

    @Test func independentReadsStartTogether() async {
        let gate = ThreeReadGate()
        let details = await readDeviceDetails(id: "phone", plugins: allPlugins,
            properties: { _, interface in
                await gate.arrive()
                if interface.hasSuffix(".battery") { return ["charge": .int32(82)] }
                return ["cellularNetworkType": .string("5G")]
            }, notifications: { _ in
                await gate.arrive()
                return [PhoneNotification(id: "2", properties: [:])]
            })
        #expect(await gate.allStartedBeforeRelease)
        #expect(details.battery?.charge == 82)
        #expect(details.cellular?.networkType == "5G")
        #expect(details.notifications.map(\.id) == ["2"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDECONNECT_PERF"] == "1"))
    func detailsLatencyBenchmark() async {
        let workloads: [(String, Set<String>, Duration, Int)] = [
            ("none-immediate", [], .zero, 1_000),
            ("one-immediate", [Plugin.battery.rawValue], .zero, 1_000),
            ("three-immediate", allPlugins, .zero, 1_000),
            ("three-delayed", allPlugins, .milliseconds(2), 15),
        ]
        for (name, plugins, delay, iterations) in workloads {
            var samples: [Double] = []
            var checksum = 0
            for sample in 0..<8 {
                let probe = DeviceReadProbe(delay: delay)
                let start = ContinuousClock.now
                for _ in 0..<iterations {
                    let details = await read(plugins, using: probe)
                    checksum &+= (details.battery?.charge ?? 0) + details.notifications.count
                }
                let elapsed = start.duration(to: .now).components
                let nanoseconds = Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9
                if sample > 0 { samples.append(nanoseconds / Double(iterations)) }
            }
            print("device-details workload=\(name) samples-ns=\(samples) median-ns=\(samples.sorted()[3]) checksum=\(checksum)")
        }
    }

    /// Three independent local D-Bus calls model the usual battery,
    /// connectivity and notification reads without contacting the user's
    /// daemon or using any personal device data.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDECONNECT_PERF"] == "1"))
    func detailsPrivateBusBenchmark() async throws {
        let locator = DaemonLocator()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = try #require(locator.busURL)
        let config = try #require(locator.busConfigURL)
        process.arguments = ["--print-address", "--nofork", "--config-file", config.path, "--address", "unix:tmpdir=/tmp"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.close()
        let address = try #require(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = try await DBusConnection.connect(address: address)
        defer { connection.close() }
        let properties: DevicePropertyReader = { _, interface in
            guard try await connection.nameHasOwner("org.freedesktop.DBus") else { throw DeviceReadProbe.Failure.rejected }
            if interface.hasSuffix(".battery") { return ["charge": .int32(82), "isCharging": .bool(true)] }
            return ["cellularNetworkType": .string("5G"), "cellularNetworkStrength": .int32(3)]
        }
        let notifications: DeviceNotificationReader = { _ in
            guard try await connection.nameHasOwner("org.freedesktop.DBus") else { throw DeviceReadProbe.Failure.rejected }
            return [PhoneNotification(id: "2", properties: ["text": .string("Sample")])]
        }
        var samples: [Double] = []
        var checksum = 0
        for sample in 0..<8 {
            let start = ContinuousClock.now
            for _ in 0..<64 {
                let details = await readDeviceDetails(id: "phone", plugins: allPlugins,
                                                      properties: properties, notifications: notifications)
                checksum &+= (details.battery?.charge ?? 0) + details.notifications.count
            }
            let elapsed = start.duration(to: .now).components
            let nanoseconds = Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9
            if sample > 0 { samples.append(nanoseconds / 64) }
        }
        #expect(checksum == 64 * 8 * 83)
        print("device-details workload=private-bus samples-ns=\(samples) median-ns=\(samples.sorted()[3]) checksum=\(checksum)")
    }
}

/// The timer is only a deadlock guard. The assertion checks whether all
/// three operations reached the gate before any one of them was released.
private actor ThreeReadGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var allStartedBeforeRelease = false
    private var released = false

    func arrive() async {
        if released { return }
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            if pending.count == 1 {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    self.release()
                }
            }
            if pending.count == 3 {
                allStartedBeforeRelease = true
                release()
            }
        }
    }

    private func release() {
        guard !released else { return }
        released = true
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private actor DeviceReadProbe {
    enum Failure: Error { case rejected }
    let failures: Set<String>
    let delay: Duration
    let batteryProperties: [String: DBusValue]
    let connectivityProperties: [String: DBusValue]
    private(set) var requests: [String] = []
    private(set) var pathsAreCorrect = true

    init(failures: Set<String> = [], delay: Duration = .zero,
         batteryProperties: [String: DBusValue] = ["hasBattery": .bool(true), "charge": .int32(82), "isCharging": .bool(true)],
         connectivityProperties: [String: DBusValue] = ["cellularNetworkType": .string("5G"), "cellularNetworkStrength": .int32(3)]) {
        self.failures = failures
        self.delay = delay
        self.batteryProperties = batteryProperties
        self.connectivityProperties = connectivityProperties
    }

    func properties(_ path: String, _ interface: String) async throws -> [String: DBusValue] {
        let battery = interface == "org.kde.kdeconnect.device.battery"
        let kind = battery ? "battery" : "connectivity"
        pathsAreCorrect = pathsAreCorrect && path == "/modules/kdeconnect/devices/phone/\(battery ? "battery" : "connectivity_report")"
        pathsAreCorrect = pathsAreCorrect && (battery || interface == "org.kde.kdeconnect.device.connectivity_report")
        requests.append(kind)
        if delay > .zero { try await Task.sleep(for: delay) }
        if failures.contains(kind) { throw Failure.rejected }
        return battery ? batteryProperties : connectivityProperties
    }

    func notifications(_ id: String) async throws -> [PhoneNotification] {
        pathsAreCorrect = pathsAreCorrect && id == "phone"
        requests.append("notifications")
        if delay > .zero { try await Task.sleep(for: delay) }
        if failures.contains("notifications") { throw Failure.rejected }
        return [PhoneNotification(id: "2", properties: ["appName": .string("Messages"), "text": .string("Sample")])]
    }
}
