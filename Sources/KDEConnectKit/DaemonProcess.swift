import DBusKit
import Darwin
import Foundation

/// Starts, finds and stops the kdeconnectd process and its private dbus-daemon.
public struct DaemonProcess: Sendable {
    public let locator: DaemonLocator

    public init(locator: DaemonLocator = DaemonLocator()) {
        self.locator = locator
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KDEConnectNative/kdeconnectd.log")
    }

    /// PIDs of processes whose executable is `url`, owned by this user.
    static func pids(runningExecutable url: URL) -> [pid_t] {
        let target = url.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        let uid = getuid()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == uid else {
                return false
            }
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == target
        }
    }

    public var daemonPids: [pid_t] {
        guard let url = locator.daemonURL else { return [] }
        return Self.pids(runningExecutable: url)
    }

    /// Every dbus-daemon from the KDE Connect bundle, including stale ones
    /// left behind by earlier daemon runs.
    public var busPids: [pid_t] {
        guard let url = locator.bundleURL?.appendingPathComponent("Contents/MacOS/dbus-daemon") else { return [] }
        return Self.pids(runningExecutable: url)
    }

    public var isDaemonRunning: Bool { !daemonPids.isEmpty }

    /// Starts a private session bus with the bundled dbus-daemon, the same
    /// way the stock KDE Connect launcher does, and publishes its address in
    /// the address file so that the other KDE Connect tools find it.
    public func launchBus() async throws -> String {
        guard let busURL = locator.busURL, let configURL = locator.busConfigURL else { throw DaemonError.notInstalled }
        let pipe = Pipe()
        let log = try logHandle()
        let pid = try DetachedSpawn.spawn(
            busURL,
            arguments: ["--print-address", "--nofork", "--config-file", configURL.path, "--address", "unix:tmpdir=/tmp"],
            environment: ProcessInfo.processInfo.environment,
            stdout: pipe.fileHandleForWriting.fileDescriptor, stderr: log.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        try log.close()

        let reader = FirstLineReader(handle: pipe.fileHandleForReading)
        guard let address = await reader.line(timeout: .seconds(5)), address.hasPrefix("unix:") else {
            kill(pid, SIGTERM)
            throw DaemonError.busDidNotStart
        }
        try (address + "\n").write(toFile: DaemonLocator.addressFile, atomically: true, encoding: .utf8)
        return address
    }

    /// Starts kdeconnectd on the bus at `busAddress`. Both outlive this app,
    /// like they do with the stock launcher.
    public func launchDaemon(busAddress: String) throws {
        guard let url = locator.daemonURL else { throw DaemonError.notInstalled }
        let log = try logHandle()
        defer { try? log.close() }
        _ = try DetachedSpawn.spawn(url, arguments: [], environment: Self.environment(busAddress: busAddress),
                                    stdout: log.fileDescriptor, stderr: log.fileDescriptor)
    }

    /// The environment that points libdbus at the private bus.
    public static func environment(busAddress: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DBUS_SESSION_BUS_ADDRESS"] = busAddress
        if let path = try? DBusAddress.unixPath(busAddress) {
            env["DBUS_LAUNCHD_SESSION_BUS_SOCKET"] = path
        }
        return env
    }

    private func logHandle() throws -> FileHandle {
        let logURL = Self.logURL
        let fm = FileManager.default
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // kdeconnectd can log the same warning many times, so keep one old copy at most.
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5_000_000 {
            let old = logURL.appendingPathExtension("old")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logURL, to: old)
        }
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        return handle
    }

    /// Stops kdeconnectd and every bundled dbus-daemon, then waits up to
    /// `timeout` for them to exit.
    public func stopAll(timeout: Duration = .seconds(5)) async {
        let targets = daemonPids + busPids
        guard !targets.isEmpty else { return }
        for pid in targets { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if targets.allSatisfy({ kill($0, 0) != 0 }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

public enum DaemonError: Error, CustomStringConvertible {
    case notInstalled
    case busDidNotStart
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .notInstalled: "KDE Connect.app is not installed"
        case .busDidNotStart: "The private dbus-daemon did not report an address"
        case .spawnFailed(let detail): "Could not start \(detail)"
        }
    }
}

/// Collects the first line that a pipe receives.
private final class FirstLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<String?, Never>?
    private var result: String??

    init(handle: FileHandle) {
        self.handle = handle
    }

    func line(timeout: Duration) async -> String? {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            handle.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                if chunk.isEmpty { return self.finish(nil) }
                let line: String? = self.lock.withLock {
                    self.buffer.append(chunk)
                    guard let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
                    return String(decoding: self.buffer[..<newline], as: UTF8.self)
                }
                if let line { self.finish(line.trimmingCharacters(in: .whitespaces)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                [weak self] in self?.finish(nil)
            }
        }
    }

    private func finish(_ line: String?) {
        let continuation: CheckedContinuation<String?, Never>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        handle.readabilityHandler = nil
        try? handle.close()
        continuation.resume(returning: line)
    }
}
