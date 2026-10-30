import Darwin
import Foundation
import Testing
@testable import KDEConnectKit

struct DaemonLocatorTests {
    private func withAddressFile(_ body: (String, String) throws -> Void) throws {
        // Unix-domain socket paths must fit in sockaddr_un.sun_path.
        let root = URL(fileURLWithPath: "/tmp/kcn-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("bus").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = root.appendingPathComponent("address").path
        try ("unix:path=" + socketPath + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        try body(file, socketPath)
    }

    @Test func acceptsOwnedAddressAndSocket() throws {
        try withAddressFile { file, socket in
            #expect(DaemonLocator.currentBusAddress(at: file) == "unix:path=" + socket)
        }
    }

    @Test func rejectsWrongOwnerAndWritableAddress() throws {
        try withAddressFile { file, _ in
            #expect(DaemonLocator.currentBusAddress(at: file, userID: getuid() &+ 1) == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file)
            #expect(DaemonLocator.currentBusAddress(at: file) == nil)
        }
    }

    @Test func rejectsAddressSymlinkAndFIFO() throws {
        try withAddressFile { file, _ in
            let link = file + ".link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
            #expect(DaemonLocator.currentBusAddress(at: link) == nil)
            let fifo = file + ".fifo"
            #expect(mkfifo(fifo, 0o600) == 0)
            #expect(DaemonLocator.currentBusAddress(at: fifo) == nil)
        }
    }

    @Test func rejectsSocketSymlinkAndRegularFile() throws {
        try withAddressFile { file, socket in
            let link = socket + ".link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: socket)
            try ("unix:path=" + link).write(toFile: file, atomically: true, encoding: .utf8)
            #expect(DaemonLocator.currentBusAddress(at: file) == nil)
            try ("unix:path=" + file).write(toFile: file, atomically: true, encoding: .utf8)
            #expect(DaemonLocator.currentBusAddress(at: file) == nil)
        }
    }

    @Test func rejectsMissingMalformedAndOversizedAddress() throws {
        try withAddressFile { file, _ in
            #expect(DaemonLocator.currentBusAddress(at: file + ".missing") == nil)
            for text in ["", "not a bus address", String(repeating: "x", count: 4097)] {
                try text.write(toFile: file, atomically: true, encoding: .utf8)
                #expect(DaemonLocator.currentBusAddress(at: file) == nil)
            }
        }
    }

    @Test func missingEmbeddedBundleIsNotSelected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(DaemonLocator.embeddedBundle(in: root) == nil)
    }

    @Test func completeEmbeddedBundleTakesPriorityOverInstalledApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let helper = root.appendingPathComponent("Contents/Helpers/KDE Connect.app")
        let bin = helper.appendingPathComponent("Contents/MacOS")
        let resources = helper.appendingPathComponent("Contents/Resources/dbus-1")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in ["kdeconnectd", "dbus-daemon"] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // An incomplete helper must not override the installed app.
        #expect(DaemonLocator.embeddedBundle(in: root) == nil)
        try Data().write(to: resources.appendingPathComponent("session.conf"))
        let locator = DaemonLocator(applicationBundleURL: root)
        #expect(locator.bundleURL?.path == helper.path)
        #expect(locator.daemonURL == bin.appendingPathComponent("kdeconnectd"))
        #expect(locator.busURL == bin.appendingPathComponent("dbus-daemon"))
        #expect(locator.busConfigURL == resources.appendingPathComponent("session.conf"))
    }
}
