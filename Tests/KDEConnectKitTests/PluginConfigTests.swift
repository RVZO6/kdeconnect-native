import Darwin
import Foundation
import Synchronization
import Testing
@testable import KDEConnectKit

@Suite struct PluginConfigTests {
    @Test func escapesLikeQSettings() {
        #expect(IniFile.escape("/Users/me/Downloads") == "/Users/me/Downloads")
        #expect(IniFile.escape("a,b") == "\"a,b\"")
        #expect(IniFile.escape(" lead") == "\" lead\"")
        #expect(IniFile.escape("say \"hi\"\\") == "say \\\"hi\\\"\\\\")
        #expect(IniFile.escape("line\nbreak") == "line\\nbreak")
        // A control character followed by a hex digit escapes the digit too.
        #expect(IniFile.escape("\u{01}a") == "\\x1\\x61")
    }

    @Test func decodeReversesEncode() {
        for s in ["plain", "a,b;c=d", " spaced ", "quote \" and \\ slash", "tab\tnew\nline", "\u{01}a", "ünïcödé", "@at"] {
            #expect(IniFile.decode(IniFile.encode(.string(s))) == s)
        }
        #expect(IniFile.decode("@ByteArray({\\\"k\\\":1})") == "{\"k\":1}")
        // Byte arrays hold UTF-8 bytes, written one escape per byte.
        #expect(IniFile.decode("@ByteArray(Caf\\xc3\\xa9)") == "Café")
    }

    @Test func keepsOtherKeysAndSections() {
        var ini = IniFile(text: "[General]\nkeep=1\nautoShare=false\n\n[Other]\nx=y\n")
        ini.set("true", for: "autoShare", in: "General")
        ini.set("50", for: "maxClipboardFileSizeMB", in: "General")
        #expect(ini.text == "[General]\nkeep=1\nautoShare=true\nmaxClipboardFileSizeMB=50\n\n[Other]\nx=y\n")
    }

    @Test func writesAndReadsAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = PluginConfig(deviceId: "dev", plugin: "kdeconnect_share", baseDirectory: dir)
        try config.write(["autoShare": .bool(false), "incoming_path": .string("/tmp/a, b"), "max": .int(7)])
        let text = try String(contentsOf: config.fileURL, encoding: .utf8)
        #expect(text.contains("incoming_path=\"/tmp/a, b\""))
        let values = config.values()
        #expect(values["autoShare"] == "false")
        #expect(values["incoming_path"] == "/tmp/a, b")
        #expect(values["max"] == "7")
    }

    @Test func failedReadDoesNotReplaceExistingConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = PluginConfig(deviceId: "dev", plugin: "kdeconnect_share", baseDirectory: dir)
        try FileManager.default.createDirectory(at: config.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let original = Data([0xff, 0xfe, 0x00, 0x80]) // Not UTF-8, but still an existing file.
        try original.write(to: config.fileURL)
        #expect(throws: (any Error).self) { try config.write(["autoShare": .bool(true)]) }
        #expect(try Data(contentsOf: config.fileURL) == original)
    }

    @Test func concurrentUpdatesKeepEveryKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let config = PluginConfig(deviceId: "dev", plugin: "kdeconnect_share", baseDirectory: dir)
            do {
                try config.write(["key\(index)": .int(index)])
            } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }
        #expect(failures.withLock { $0.isEmpty })
        let values = PluginConfig(deviceId: "dev", plugin: "kdeconnect_share", baseDirectory: dir).values()
        for index in 0..<40 { #expect(values["key\(index)"] == String(index)) }
    }

    @Test func transientNativeLockIsRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = PluginConfig(deviceId: "dev", plugin: "kdeconnect_share", baseDirectory: dir)
        try config.write(["keep": .int(1)])
        let fd = open(config.fileURL.path + ".native.lock", O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let released = DispatchGroup()
        defer { released.wait(); close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        released.enter()
        // A dedicated thread, because parallel tests can fill the GCD pool for
        // longer than the 500 ms retry window.
        Thread.detachNewThread {
            usleep(20_000)
            flock(fd, LOCK_UN)
            released.leave()
        }
        try config.write(["added": .int(2)])
        #expect(config.values() == ["keep": "1", "added": "2"])
    }

    @Test func busyNativeLockDoesNotOverwriteConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = PluginConfig(deviceId: "dev", plugin: "kdeconnect_share", baseDirectory: dir)
        try config.write(["keep": .int(1)])
        let fd = open(config.fileURL.path + ".native.lock", O_RDWR | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN) }
        #expect(throws: (any Error).self) { try config.write(["keep": .int(2)]) }
        #expect(config.values()["keep"] == "1")
    }

    @Test func runCommandsRoundTrip() {
        let commands = [RunCommand(id: "{1}", name: "Lock", command: "pmset displaysleepnow"),
                        RunCommand(id: "{2}", name: "Say \"hi\", loud", command: "say hi")]
        let json = RunCommand.encode(commands)
        #expect(RunCommand.decode(IniFile.decode(IniFile.encode(.string(json)))) == commands)
    }

    @Test func signalPath() {
        let signal = PluginConfig(deviceId: "abc_123", plugin: "kdeconnect_share").changedSignal
        #expect(signal.path == "/kdeconnect/abc_123/kdeconnect_share")
        #expect(signal.interface == "org.kde.kdeconnect.config")
        #expect(signal.member == "configChanged")
    }
}
