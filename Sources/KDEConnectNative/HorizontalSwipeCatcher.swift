import AppKit
import SwiftUI

/// A hit-test-free view that reports horizontal trackpad swipes. All active
/// catchers share one monitor; vertical scrolling must not visit every card.
struct HorizontalSwipeCatcher: NSViewRepresentable {
    var active = true
    let onChange: (CGFloat, CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.active = active
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        HorizontalSwipeRouter.shared.remove(view)
    }

    final class CatcherView: NSView {
        static var monitorCount: Int { HorizontalSwipeRouter.shared.monitorCount }
        /// Synthetic events from the existing swipe test have no window.
        static var acceptsWindowlessEvents = false

        var active = true {
            didSet { if active != oldValue { updateRegistration() } }
        }
        var onChange: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onEnd: () -> Void = {}

        private enum Tracking { case idle, deciding, swiping, momentum, ignoring }
        private var tracking = Tracking.idle
        private var startX: CGFloat = 0
        private var startY: CGFloat = 0

        var wantsEvents: Bool {
            switch tracking {
            case .deciding, .swiping, .momentum: true
            case .idle, .ignoring: false
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRegistration()
        }

        override func removeFromSuperview() {
            HorizontalSwipeRouter.shared.remove(self)
            super.removeFromSuperview()
        }

        private func updateRegistration() {
            if active, window != nil {
                HorizontalSwipeRouter.shared.add(self)
            } else {
                HorizontalSwipeRouter.shared.remove(self)
            }
        }

        func accepts(_ event: NSEvent) -> Bool {
            guard active, let window, !isHiddenOrHasHiddenAncestor,
                  event.window === window || (event.window == nil && Self.acceptsWindowlessEvents) else { return false }
            // bounds alone also includes the part clipped behind the header
            // or outside the scroll view.
            let location = event.window == nil
                ? window.convertPoint(fromScreen: event.locationInWindow)
                : event.locationInWindow
            let point = convert(location, from: nil)
            return bounds.contains(point) && visibleRect.contains(point)
        }

        func resetTracking() { tracking = .idle }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.hasPreciseScrollingDeltas else { return event }
            if event.phase == .began {
                tracking = accepts(event) ? .deciding : .idle
                startX = 0
                startY = 0
            }
            switch tracking {
            case .idle, .ignoring:
                if event.phase == .ended || event.phase == .cancelled { tracking = .idle }
                return event
            case .deciding:
                startX += event.scrollingDeltaX
                startY += event.scrollingDeltaY
                if abs(startX) > 6, abs(startX) > abs(startY) * 1.5 {
                    tracking = .swiping
                    onChange(startX, bounds.width)
                    return nil
                }
                if abs(startY) > 6 || event.phase == .ended || event.phase == .cancelled { tracking = .ignoring }
                return event
            case .swiping:
                if event.phase == .ended || event.phase == .cancelled {
                    tracking = .momentum
                    onEnd()
                } else {
                    onChange(event.scrollingDeltaX, bounds.width)
                }
                return nil
            case .momentum:
                if event.momentumPhase.isEmpty && event.phase.isEmpty { tracking = .idle; return event }
                if event.momentumPhase == .ended { tracking = .idle }
                return nil
            }
        }
    }
}

@MainActor
final class HorizontalSwipeRouter {
    static let shared = HorizontalSwipeRouter()
    private let views = NSHashTable<HorizontalSwipeCatcher.CatcherView>.weakObjects()
    private weak var target: HorizontalSwipeCatcher.CatcherView?
    private var monitor: Any?

    private init() {}

    var monitorCount: Int { monitor == nil ? 0 : 1 }

    func add(_ view: HorizontalSwipeCatcher.CatcherView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var outgoing: NSEvent? = event
            MainActor.assumeIsolated {
                // A nil result consumes the event. Do not use ?? incoming:
                // that would also restore events deliberately consumed here.
                if let self { outgoing = self.route(incoming) }
            }
            return outgoing
        }
    }

    func remove(_ view: HorizontalSwipeCatcher.CatcherView) {
        views.remove(view)
        if target === view { target = nil; view.resetTracking() }
        if views.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func route(_ event: NSEvent) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas else { return event }
        if event.phase == .began {
            // Hit-test once per gesture, not once per card on every scroll
            // event. Only the chosen view sees subsequent swipe events.
            target?.resetTracking()
            target = views.allObjects.first { $0.accepts(event) }
        }
        guard let target else { return event }
        let result = target.handle(event)
        if !target.wantsEvents { self.target = nil }
        return result
    }
}
