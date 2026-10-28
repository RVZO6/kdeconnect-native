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

    /// A process, identified by PID and start time, so that a reused PID
    /// never matches a process that has exited.
    struct ProcessRecord: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        /// Reads the record for `pid` if it belongs to this user and runs `path`.
        init?(pid: pid_t, executablePath path: String) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(),
                  ProcessRecord.executablePath(of: pid) == path else { return nil }
            self.pid = pid
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }

        /// True while the original process is still running.
        func isAlive(executablePath path: String) -> Bool {
            ProcessRecord(pid: pid, executablePath: path) == self
        }

        static func executablePath(of pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Processes of this user whose executable is `url`.
    static func processes(runningExecutable url: URL) -> [ProcessRecord] {
        let target = url.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).compactMap { ProcessRecord(pid: $0, executablePath: target) }
    }

    private var daemonProcesses: [(ProcessRecord, String)] {
        guard let url = locator.daemonURL else { return [] }
        return Self.processes(runningExecutable: url).map { ($0, url.resolvingSymlinksInPath().path) }
    }

    /// Every dbus-daemon from the KDE Connect bundle that this user runs,
    /// including stale ones left behind by earlier runs. They all exist only
    /// for KDE Connect, so a restart removes all of them.
    private var busProcesses: [(ProcessRecord, String)] {
        guard let url = locator.busURL else { return [] }
        return Self.processes(runningExecutable: url).map { ($0, url.resolvingSymlinksInPath().path) }
    }

    public var isDaemonRunning: Bool { !daemonProcesses.isEmpty }

    /// A running kdeconnectd, with the path that `isAlive` checks.
    struct RunningDaemon: Sendable {
        let record: ProcessRecord
        let path: String
    }

    /// The daemon's open files and sockets. Looks the daemon up again when
    /// `known` has exited, so that a reused PID never gives the files of
    /// another process. Lists processes, so call it off the main actor.
    func fileSnapshot(_ known: RunningDaemon?) -> (RunningDaemon, ProcessFiles.Snapshot)? {
        let alive = known.flatMap { $0.record.isAlive(executablePath: $0.path) ? $0 : nil }
        guard let daemon = alive ?? daemonProcesses.first.map({ RunningDaemon(record: $0.0, path: $0.1) }),
              let snapshot = ProcessFiles.snapshot(pid: daemon.record.pid),
              daemon.record.isAlive(executablePath: daemon.path) else { return nil }
        return (daemon, snapshot)
    }

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

        let record = ProcessRecord(pid: pid, executablePath: busURL.resolvingSymlinksInPath().path)
        // Until the address is published, a failure must not leave the bus running.
        do {
            let fd = dup(pipe.fileHandleForReading.fileDescriptor)
            try pipe.fileHandleForReading.close()
            guard fd >= 0, let address = await readFirstLine(fd: fd, timeout: .seconds(5)),
                  address.hasPrefix("unix:") else {
                throw DaemonError.busDidNotStart
            }
            try (address + "\n").write(toFile: DaemonLocator.addressFile, atomically: true, encoding: .utf8)
            return address
        } catch {
            if let record, record.isAlive(executablePath: busURL.resolvingSymlinksInPath().path) {
                kill(record.pid, SIGTERM)
            }
            throw error
        }
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
    /// `timeout` for them to exit. Signals go only to the original processes,
    /// never to a later process that reuses one of their PIDs.
    public func stopAll(timeout: Duration = .seconds(5)) async {
        let targets = daemonProcesses + busProcesses
        guard !targets.isEmpty else { return }
        for (record, _) in targets { kill(record.pid, SIGTERM) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !targets.contains(where: { $0.0.isAlive(executablePath: $0.1) }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for (record, path) in targets where record.isAlive(executablePath: path) {
            kill(record.pid, SIGKILL)
        }
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

/// Reads the first line from `fd` on a dedicated thread, then closes `fd`.
/// One thread owns the descriptor, so the read and the close cannot race.
private func readFirstLine(fd: Int32, timeout: Duration) async -> String? {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            defer { close(fd) }
            let deadline = ContinuousClock.now + timeout
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 512)
            while bytes.count < 4096 {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(remaining / .milliseconds(1)) + 1)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { break }
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                bytes += chunk[0..<n]
                if let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: bytes[..<newline], as: UTF8.self)
                    continuation.resume(returning: line.trimmingCharacters(in: .whitespaces))
                    return
                }
            }
            continuation.resume(returning: nil)
        }
    }
}
