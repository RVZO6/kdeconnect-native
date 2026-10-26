import Foundation

/// A minimal D-Bus client connection over a Unix domain socket.
///
/// A background thread reads messages. Replies resume the matching
/// `call` continuation; signals go to `signalHandler`.
public final class DBusConnection: @unchecked Sendable {
    public let address: String
    public private(set) var uniqueName: String?

    private let fd: Int32
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextSerial: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<DBusMessage, Error>] = [:]
    private var closed = false
    private var signalHandler: (@Sendable (DBusMessage) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?

    /// Connects and authenticates, then sends `Hello`.
    public static func connect(address: String) async throws -> DBusConnection {
        let path = try DBusAddress.unixPath(address)
        let connection = try DBusConnection(address: address, socketPath: path)
        connection.startReader()
        do {
            let reply = try await connection.call(
                destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus", member: "Hello", timeout: .seconds(5))
            connection.lock.withLock { connection.uniqueName = reply.first?.stringValue }
            return connection
        } catch {
            // The reader thread holds the connection until the socket closes.
            connection.close()
            throw error
        }
    }

    // The initializer is complete once `fd` is set, so deinit also runs
    // when a later step of init throws. It is the only place that closes fd.
    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    private init(address: String, socketPath: String) throws {
        self.address = address
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DBusError.connectionFailed(String(cString: strerror(errno))) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DBusError.invalidAddress(address)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            throw DBusError.connectionFailed("\(socketPath): \(message)")
        }
        // Calls block in the socket only during authentication; the reader
        // thread uses blocking reads after that.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try authenticate()
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A bus that stops reading must not block writers for ever. A write
        // that times out fails, and the caller then closes the connection.
        timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Authentication

    private func authenticate() throws {
        let uidHex = String(getuid()).utf8.map { String(format: "%02x", $0) }.joined()
        try writeAll([0] + Array("AUTH EXTERNAL \(uidHex)\r\n".utf8))
        let line = try readLine()
        guard line.hasPrefix("OK ") else { throw DBusError.authenticationFailed(line) }
        try writeAll(Array("BEGIN\r\n".utf8))
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 4096 {
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else { throw DBusError.authenticationFailed("no reply") }
            if byte == UInt8(ascii: "\n") { break }
            if byte != UInt8(ascii: "\r") { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: I/O

    private func writeAll(_ bytes: [UInt8]) throws {
        try writeLock.withLock {
            var written = 0
            while written < bytes.count {
                let n = bytes.withUnsafeBytes { buffer in
                    Darwin.write(fd, buffer.baseAddress! + written, bytes.count - written)
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DBusError.disconnected
                }
                written += n
            }
        }
    }

    private func readExactly(_ count: Int, into buffer: inout [UInt8]) -> Bool {
        let start = buffer.count
        buffer.reserveCapacity(start + count)
        var chunk = [UInt8](repeating: 0, count: min(count, 65536))
        while buffer.count - start < count {
            let want = min(chunk.count, count - (buffer.count - start))
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, want) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return true
    }

    private func startReader() {
        // The thread keeps the connection alive until the socket closes. The
        // descriptor itself closes only in deinit, so that no other thread
        // can use a descriptor number that the system has given out again.
        let thread = Thread {
            while self.readOne() {}
            self.close()
        }
        thread.name = "DBusConnection reader"
        thread.start()
    }

    /// Reads and dispatches one message. Returns false when the stream ends.
    private func readOne() -> Bool {
        var buffer: [UInt8] = []
        guard readExactly(16, into: &buffer) else { return false }
        guard let total = try? DBusMessage.totalLength(ofHeader: buffer), total >= 16 else { return false }
        guard readExactly(total - 16, into: &buffer) else { return false }
        guard let message = try? DBusMessage.parse(buffer) else {
            // Skip messages we cannot parse, but stay connected.
            return true
        }
        dispatch(message)
        return true
    }

    private func dispatch(_ message: DBusMessage) {
        switch message.kind {
        case .methodReturn, .error:
            guard let replySerial = message.replySerial else { return }
            let continuation = lock.withLock { pending.removeValue(forKey: replySerial) }
            continuation?.resume(returning: message)
        case .signal:
            let handler = lock.withLock { signalHandler }
            handler?(message)
        case .methodCall:
            respondToIncomingCall(message)
        }
    }

    private func respondToIncomingCall(_ call: DBusMessage) {
        guard !call.flags.contains(.noReplyExpected) else { return }
        var reply: DBusMessage
        if call.interface == "org.freedesktop.DBus.Peer" && call.member == "Ping" {
            reply = DBusMessage(kind: .methodReturn)
        } else {
            reply = DBusMessage(kind: .error)
            reply.errorName = "org.freedesktop.DBus.Error.UnknownMethod"
            reply.body = [.string("This client does not export objects")]
        }
        reply.replySerial = call.serial
        reply.destination = call.sender
        _ = try? send(reply)
    }

    // MARK: Public API

    public func setSignalHandler(_ handler: (@Sendable (DBusMessage) -> Void)?) {
        lock.withLock { signalHandler = handler }
    }

    /// The handler runs once, on the reader thread, when the connection closes.
    public func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        let alreadyClosed = lock.withLock {
            closeHandler = handler
            return closed
        }
        if alreadyClosed { handler?() }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    @discardableResult
    public func send(_ message: DBusMessage) throws -> UInt32 {
        var message = message
        let serial = try lock.withLock {
            guard !closed else { throw DBusError.disconnected }
            defer { nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1 }
            return nextSerial
        }
        message.serial = serial
        let bytes = try message.serialize()
        do {
            try writeAll(bytes)
        } catch {
            close()
            throw error
        }
        return serial
    }

    /// Sends a method call and waits for the reply body.
    public func call(_ message: DBusMessage, timeout: Duration = .seconds(25)) async throws -> [DBusValue] {
        var message = message
        message.kind = .methodCall
        let serialBox = SerialBox()
        let reply: DBusMessage = try await withCheckedThrowingContinuation { continuation in
            do {
                // Register the continuation before the write, so that a fast
                // reply cannot arrive first.
                let serial = try lock.withLock {
                    guard !closed else { throw DBusError.disconnected }
                    let serial = nextSerial
                    nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1
                    pending[serial] = continuation
                    return serial
                }
                serialBox.value = serial
                message.serial = serial
                let bytes = try message.serialize()
                do {
                    try writeAll(bytes)
                } catch {
                    // A failed or partial write leaves the stream in an
                    // unknown state. close() also fails this call.
                    close()
                    return
                }
            } catch {
                // Registration or serialization failed; nothing was written.
                // Resume only if close() has not already done it.
                let owned = serialBox.value.map { serial in
                    lock.withLock { pending.removeValue(forKey: serial) != nil }
                } ?? true
                if owned { continuation.resume(throwing: error) }
                return
            }
            let serial = serialBox.value!
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
                guard let self else { return }
                let expired = self.lock.withLock { self.pending.removeValue(forKey: serial) }
                expired?.resume(throwing: DBusError.timeout)
            }
        }
        if reply.kind == .error {
            throw DBusError.remote(name: reply.errorName ?? "org.freedesktop.DBus.Error.Failed", message: reply.errorMessage)
        }
        return reply.body
    }

    public func call(destination: String?, path: String, interface: String?, member: String,
                     _ args: [DBusValue] = [], timeout: Duration = .seconds(25)) async throws -> [DBusValue] {
        try await call(.methodCall(destination: destination, path: path, interface: interface, member: member, body: args),
                       timeout: timeout)
    }

    /// Adds a match rule to the bus so that matching signals reach this connection.
    public func addMatch(_ rule: String) async throws {
        _ = try await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                           interface: "org.freedesktop.DBus", member: "AddMatch", [.string(rule)])
    }

    public func nameHasOwner(_ name: String) async throws -> Bool {
        let reply = try await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                   interface: "org.freedesktop.DBus", member: "NameHasOwner", [.string(name)])
        return reply.first?.boolValue ?? false
    }

    /// Closes the connection. Pending calls fail with `disconnected`, and the
    /// close handler runs once.
    public func close() {
        let (continuations, handler): ([CheckedContinuation<DBusMessage, Error>], (@Sendable () -> Void)?) = lock.withLock {
            guard !closed else { return ([], nil) }
            closed = true
            let c = Array(pending.values)
            pending.removeAll()
            let h = closeHandler
            closeHandler = nil
            return (c, h)
        }
        // Shutdown wakes the reader thread and makes later writes fail.
        shutdown(fd, SHUT_RDWR)
        for c in continuations { c.resume(throwing: DBusError.disconnected) }
        handler?()
    }
}

private final class SerialBox: @unchecked Sendable {
    var value: UInt32?
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

public enum DBusAddress {
    /// The socket path of the first `unix:path=` entry in a D-Bus address.
    public static func unixPath(_ address: String) throws -> String {
        // An address list may hold several entries separated by ";".
        for entry in address.split(separator: ";") {
            guard entry.hasPrefix("unix:") else { continue }
            for pair in entry.dropFirst(5).split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == "path" {
                    return String(parts[1]).removingPercentEncoding ?? String(parts[1])
                }
            }
        }
        throw DBusError.invalidAddress(address)
    }
}
