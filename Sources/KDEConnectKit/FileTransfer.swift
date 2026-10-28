import Darwin
import Foundation
import Observation

/// Files that the user sends to one device, and how far the daemon is.
///
/// kdeconnectd does not report upload progress on D-Bus on macOS, so the
/// progress comes from the daemon process itself: the offset of each file
/// that it has open, and its upload listening socket. The daemon writes 4 KB
/// at a time and waits for each write to go out, so the offset follows the
/// network closely.
@MainActor
@Observable
public final class FileTransfer {
    public enum Phase: Equatable, Sendable {
        case sending
        case finished
        case failed(String)
    }

    public struct Item: Sendable {
        public let name: String
        public let size: Int64
        let id: FileID?
    }

    public let deviceId: String
    public private(set) var items: [Item] = []
    public private(set) var phase: Phase = .sending
    public private(set) var sentBytes: Int64 = 0
    /// The file that is going out now, as an index in `items`.
    public private(set) var currentIndex = 0
    @ObservationIgnored var tracker = TransferTracker(files: [], start: .now)
    @ObservationIgnored var watcher: Task<Void, Never>?

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    /// From 0 to 1. A transfer with no bytes is complete when it finishes.
    public var fraction: Double {
        if phase == .finished { return 1 }
        let total = totalBytes
        return total > 0 ? min(1, Double(sentBytes) / Double(total)) : 0
    }

    func append(_ urls: [URL]) {
        let new = urls.map { Self.item(for: $0) }
        items += new
        tracker.append(new.map { TransferTracker.File(id: $0.id, size: $0.size) }, now: .now)
    }

    func apply(_ outcome: TransferTracker.Outcome) {
        let sent = tracker.sentBytes
        if sent != sentBytes { sentBytes = sent }
        let index = tracker.currentIndex
        if index != currentIndex { currentIndex = index }
        switch outcome {
        case .running: break
        case .finished: phase = .finished
        case .failed(let reason): phase = .failed(reason)
        }
    }

    func fail(_ reason: String) { phase = .failed(reason) }

    /// Demo mode only: moves the progress without a daemon.
    func advanceDemo(by bytes: Int64) {
        sentBytes = min(totalBytes, sentBytes + bytes)
        var end: Int64 = 0
        currentIndex = items.firstIndex { end += $0.size; return end > sentBytes } ?? max(0, items.count - 1)
        if sentBytes >= totalBytes { phase = .finished }
    }

    private static func item(for url: URL) -> Item {
        guard url.isFileURL else { return Item(name: url.absoluteString, size: 0, id: nil) }
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return Item(name: url.lastPathComponent, size: 0, id: nil)
        }
        return Item(name: url.lastPathComponent, size: Int64(info.st_size),
                    id: FileID(device: info.st_dev, inode: info.st_ino))
    }
}

/// A file by device and inode, so that a path through a symlink or a
/// firmlink still matches the file that the daemon has open.
struct FileID: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// Works out the progress of one transfer from snapshots of the daemon.
///
/// The daemon sends files one at a time and closes each when it is done. A
/// small file can open and close between two snapshots, so a file also counts
/// as done when a later file opens, or when the upload job has ended.
struct TransferTracker: Sendable {
    struct File: Sendable {
        let id: FileID?
        let size: Int64
        var seen = false
        var done = false
        var sent: Int64 = 0
    }

    enum Outcome: Equatable {
        case running
        case finished
        case failed(String)
    }

    /// The daemon's upload ports, for its upload listening socket.
    static let uploadPorts: ClosedRange<UInt16> = 1739...1764
    /// How long nothing must happen before the transfer counts as ended.
    static let settleTime: Duration = .milliseconds(1500)
    /// How long to wait for a first sign of the upload job.
    static let startTime: Duration = .seconds(4)
    /// A file at least this large cannot go out between two snapshots.
    static let unseenLimit: Int64 = 16 << 20
    /// The daemon stops waiting for the device to connect after 30 s.
    static let connectTimeout: Duration = .seconds(25)

    var files: [File]
    let start: ContinuousClock.Instant
    private var lastActivity: ContinuousClock.Instant
    private var listenSince: ContinuousClock.Instant?
    private var listenSeen = false

    init(files: [File], start: ContinuousClock.Instant) {
        self.files = files
        self.start = start
        lastActivity = start
    }

    /// More files for the same upload job. They count as new activity, so
    /// that the job does not seem to have ended before they start.
    mutating func append(_ more: [File], now: ContinuousClock.Instant) {
        files += more
        lastActivity = now
    }

    var sentBytes: Int64 { files.reduce(0) { $0 + ($1.done ? $1.size : $1.sent) } }
    var currentIndex: Int { files.firstIndex { !$0.done } ?? max(0, files.count - 1) }

    mutating func update(offsets: [FileID: Int64], listening: Bool, now: ContinuousClock.Instant) -> Outcome {
        for index in files.indices {
            if let id = files[index].id, let offset = offsets[id] {
                files[index].seen = true
                files[index].sent = min(offset, files[index].size)
                lastActivity = now
                for earlier in 0..<index where !files[earlier].done { files[earlier].done = true }
            } else if files[index].seen, !files[index].done {
                files[index].done = true
                lastActivity = now
            }
            // Empty files and URLs have nothing to read.
            if files[index].id == nil || files[index].size == 0, index == 0 || files[index - 1].done {
                files[index].done = true
            }
        }
        if listening {
            listenSeen = true
            listenSince = listenSince ?? now
            lastActivity = now
        }
        if files.allSatisfy(\.done) { return .finished }
        let anyOpen = files.contains { $0.seen && !$0.done }
        guard !anyOpen, !listening else { return .running }

        let anySeen = files.contains(where: \.seen)
        if listenSeen || anySeen {
            guard now - lastActivity >= Self.settleTime else { return .running }
            if !anySeen, let listenSince, lastActivity - listenSince >= Self.connectTimeout {
                return .failed("The device did not connect.")
            }
        } else if now - start < Self.startTime {
            return .running
        }
        return result()
    }

    /// The job has ended. Files that never showed up went out between two
    /// snapshots, unless they were too large for that.
    private mutating func result() -> Outcome {
        let missed = files.contains { !$0.done && !$0.seen && $0.size >= Self.unseenLimit }
        if missed { return .failed("The transfer did not finish.") }
        for index in files.indices { files[index].done = true }
        return .finished
    }
}

/// Reads the open files and sockets of another process of this user.
enum ProcessFiles {
    struct Snapshot {
        var offsets: [FileID: Int64] = [:]
        var isListeningForUpload = false
    }

    static func snapshot(pid: pid_t) -> Snapshot? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return nil }

        var snapshot = Snapshot()
        for fd in fds.prefix(Int(filled) / stride) {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var info = vnode_fdinfo()
                let size = Int32(MemoryLayout<vnode_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, size) == size else { continue }
                let stat = info.pvi.vi_stat
                let id = FileID(device: Int32(bitPattern: stat.vst_dev), inode: stat.vst_ino)
                snapshot.offsets[id] = max(snapshot.offsets[id] ?? 0, info.pfi.fi_offset)
            case PROX_FDTYPE_SOCKET:
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let tcp = info.psi.soi_proto.pri_tcp
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                if tcp.tcpsi_state == TSI_S_LISTEN, TransferTracker.uploadPorts.contains(port) {
                    snapshot.isListeningForUpload = true
                }
            default:
                continue
            }
        }
        return snapshot
    }
}
