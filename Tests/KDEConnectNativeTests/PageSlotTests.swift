import AppKit
import SwiftUI
import Testing
@testable import KDEConnectNative

@MainActor
struct PageSlotTests {
    private final class EnabledView: NSView {
        var environmentEnabled = true
    }

    private struct EnabledProbe: NSViewRepresentable {
        let view: EnabledView
        func makeNSView(context: Context) -> EnabledView { view }
        func updateNSView(_ view: EnabledView, context: Context) {
            view.environmentEnabled = context.environment.isEnabled
        }
    }

    @Test func onlySelectedPageIsEnabled() async throws {
        _ = NSApplication.shared
        let selection = PageSelection()
        let probe = EnabledView()
        let host = NSHostingView(rootView: PageSlot(selection: selection, page: .plugins) {
            EnabledProbe(view: probe)
        })
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!probe.environmentEnabled)
        selection.page = .plugins
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(probe.environmentEnabled)
        selection.page = .details
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(!probe.environmentEnabled)
    }
}
