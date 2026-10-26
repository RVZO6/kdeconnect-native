import AppKit
import ObjectiveC

/// Plays every sidebar toggle as a full animation, one after the other.
///
/// By default, a toggle while the sidebar still moves makes it snap to the
/// end state. The queue holds each toggle until the previous animation has
/// finished. It sits in front of `NSSplitViewController.toggleSidebar(_:)`,
/// so the toolbar button, the View menu and ⌃⌘S all use it.
@MainActor
enum SidebarToggleQueue {
    /// A little longer than the split view's collapse animation.
    static let animationDuration: TimeInterval = 0.3
    /// More toggles than this are dropped, so that a long burst ends soon.
    static let maxPending = 6

    private static var pending: [() -> Void] = []
    private static var isRunning = false

    static func install() {
        let cls: AnyClass = NSSplitViewController.self
        guard let original = class_getInstanceMethod(cls, #selector(NSSplitViewController.toggleSidebar(_:))),
              let queued = class_getInstanceMethod(cls, #selector(NSSplitViewController.kdcn_queuedToggleSidebar(_:)))
        else { return }
        method_exchangeImplementations(original, queued)
    }

    static func enqueue(_ toggle: @escaping () -> Void) {
        guard pending.count < maxPending else { return }
        pending.append(toggle)
        if !isRunning { runNext() }
    }

    private static func runNext() {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true
        pending.removeFirst()()
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
            MainActor.assumeIsolated { runNext() }
        }
    }
}

extension NSSplitViewController {
    /// After `install()`, this body runs for `toggleSidebar(_:)`, and a call
    /// to `kdcn_queuedToggleSidebar(_:)` runs the original implementation.
    @objc func kdcn_queuedToggleSidebar(_ sender: Any?) {
        MainActor.assumeIsolated {
            SidebarToggleQueue.enqueue { [weak self] in self?.kdcn_queuedToggleSidebar(sender) }
        }
    }
}
