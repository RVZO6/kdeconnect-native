import DBusKit
import Foundation
import Testing
@testable import KDEConnectKit

@Suite(.serialized)
struct ConcurrentReadTests {
    @Test func boundsConcurrencyAndKeepsOrder() async {
        let probe = ReadProbe(total: 10, limit: 3)
        let result = await concurrentRead(Array(0..<10), limit: 3) { await probe.read($0) }
        #expect(result == Array(0..<10))
        let peak = await probe.peak
        let waves = await probe.waves
        #expect(peak == 3)
        #expect(waves == 4)
    }

    @Test func keepsOptionalFailuresInTheirOriginalPositions() async {
        let result = await concurrentRead(Array(0..<10), limit: 4) { input -> Int? in
            await Task.yield()
            return input.isMultiple(of: 2) ? input : nil
        }
        #expect(result == [0, nil, 2, nil, 4, nil, 6, nil, 8, nil])
    }

    @Test func emptyInputDoesNoWork() async {
        let result = await concurrentRead([Int](), limit: 8) { input in
            Issue.record("No read is needed for empty input")
            return input
        }
        #expect(result.isEmpty)
    }

    @Test func limitOneAndLimitAboveCount() async {
        #expect(await concurrentRead([1, 2, 3], limit: 1) { $0 * 2 } == [2, 4, 6])
        #expect(await concurrentRead([1, 2, 3], limit: 8) { $0 * 2 } == [2, 4, 6])
    }

    /// An opt-in latency experiment, not a timing assertion in the test
    /// suite. This models 64 independent reads with a 2 ms reply delay.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDECONNECT_PERF"] == "1"))
    func readLatencyBenchmark() async throws {
        for limit in [1, 8] {
            var samples: [Double] = []
            for _ in 0..<7 {
                let start = ContinuousClock.now
                let result = await concurrentRead(Array(0..<64), limit: limit) { input in
                    try? await Task.sleep(for: .milliseconds(2))
                    return input
                }
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                #expect(result == Array(0..<64))
            }
            print("read-latency limit=\(limit) samples-ms=\(samples) median-ms=\(samples.sorted()[3])")
        }
    }

    /// Checks actual socket/authentication/serial dispatch with a separate
    /// bundled bus. Does not contact kdeconnectd or change its address file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDECONNECT_PERF"] == "1"))
    func privateBusLatencyBenchmark() async throws {
        let locator = DaemonLocator()
        let bus = try #require(locator.busURL)
        let config = try #require(locator.busConfigURL)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = bus
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
        for limit in [1, 8] {
            var samples: [Double] = []
            for _ in 0..<7 {
                let start = ContinuousClock.now
                let result = await concurrentRead(Array(0..<64), limit: limit) { _ in
                    (try? await connection.nameHasOwner("org.freedesktop.DBus")) == true
                }
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                #expect(result.count == 64)
                #expect(result.allSatisfy { $0 })
            }
            print("private-bus limit=\(limit) samples-ms=\(samples) median-ms=\(samples.sorted()[3])")
        }
    }
}

/// Releases each wave in reverse order without time-based coordination.
/// This makes the bound and the minimum number of waves deterministic.
private actor ReadProbe {
    let total: Int
    let limit: Int
    private var started = 0
    private var active = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var waveSize: Int
    private(set) var peak = 0
    private(set) var waves = 0

    init(total: Int, limit: Int) {
        self.total = total
        self.limit = limit
        waveSize = min(total, limit)
    }

    func read(_ input: Int) async -> Int {
        active += 1
        started += 1
        peak = max(peak, active)
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            if pending.count == waveSize {
                let wave = pending
                pending.removeAll()
                waveSize = min(limit, total - started)
                waves += 1
                for continuation in wave.reversed() { continuation.resume() }
            }
        }
        active -= 1
        return input
    }
}
