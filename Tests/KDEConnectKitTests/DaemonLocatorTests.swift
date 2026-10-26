import Foundation
import Testing
@testable import KDEConnectKit

struct DaemonLocatorTests {
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
        for name in ["kdeconnectd", "dbus-daemon", "kdeconnect-sms"] {
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
        #expect(locator.smsAppURL == bin.appendingPathComponent("kdeconnect-sms"))
        #expect(locator.busConfigURL == resources.appendingPathComponent("session.conf"))
    }
}
