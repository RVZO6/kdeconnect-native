import AppKit
import Darwin
import Foundation

/// A daemon-free, real-window workload. Measures main-thread scheduling and
/// process CPU time, not presented frames or GPU time. No screen capture is
/// performed in a timed section.
@MainActor
enum UIBenchmark {
    private static let recordsUpdates = CommandLine.arguments.contains("--ui-benchmark")
    private static var updates: [String: Int] = [:]

    static func recordUpdate(_ name: String) {
        guard recordsUpdates else { return }
        updates[name, default: 0] += 1
    }

    struct Measurement: Encodable {
        let scenario: String
        let notificationCount: Int
        let replyableNotificationCount: Int
        let swipeViewCount: Int
        let eventMonitorCount: Int
        let deliveredScrollEvents: Int
        let postedHoverEvents: Int
        let scrollDistancePoints: Double
        let documentHeightPoints: Double
        let scrollViewAttached: Bool
        let scrollableRangePoints: Double
        let viewportWidthPoints: Double
        let viewportHeightPoints: Double
        let bodyUpdateCounts: [String: Int]
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let inputIntervalP50Milliseconds: Double
        let inputIntervalP95Milliseconds: Double
        let inputIntervalMaxMilliseconds: Double
    }

    static func run(to path: String) async {
        guard CommandLine.arguments.contains("--demo") else {
            print("--ui-benchmark requires --demo; no live device data is used")
            exit(EXIT_FAILURE)
        }
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) else {
            print("UI benchmark: no main window")
            exit(EXIT_FAILURE)
        }
        window.setContentSize(NSSize(width: 900, height: 640))
        window.acceptsMouseMovedEvents = true
        try? await Task.sleep(for: .seconds(1))
        guard let scrollView = notificationScrollView(in: window) else {
            print("UI benchmark: no notification scroll view")
            exit(EXIT_FAILURE)
        }
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        var measurements: [Measurement] = []
        for scenario in ["collapsed-scroll", "expanded-scroll", "reply-hover"] {
            if scenario == "expanded-scroll" {
                NotificationCenter.default.post(name: .debugToggleStacks, object: nil)
                try? await Task.sleep(for: .seconds(1))
            }
            let scrollView = notificationScrollView(in: window) ?? scrollView
            ScrollViewport.scrollToTop(scrollView)
            try? await Task.sleep(for: .milliseconds(500))
            let views = descendants(of: window.contentView)
            let swipeViews = views.filter { $0 is HorizontalSwipeCatcher.CatcherView }.count
            let monitors = HorizontalSwipeCatcher.CatcherView.monitorCount
            let visibleViewport = ScrollViewport.visibleRect(of: scrollView)
            func visiblePart(of view: HorizontalSwipeCatcher.CatcherView) -> CGRect {
                let viewportInView = view.convert(visibleViewport, from: scrollView.contentView)
                return view.bounds.intersection(view.visibleRect).intersection(viewportInView)
            }
            let hoverView = views.compactMap { $0 as? HorizontalSwipeCatcher.CatcherView }
                .filter { $0.active && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty && !visiblePart(of: $0).isEmpty }
                .max { left, right in
                    left.convert(visiblePart(of: left), to: nil).midY < right.convert(visiblePart(of: right), to: nil).midY
                }
            let hoverPoint = hoverView.map { view in
                let visible = visiblePart(of: view)
                return view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            }
            let outsidePoint = hoverView.map { view in
                view.convert(NSPoint(x: view.bounds.minX - 8, y: visiblePart(of: view).midY), to: nil)
            }
            let range = ScrollViewport.verticalRange(of: scrollView)
            let scrollableRange = range.upperBound - range.lowerBound
            updates = [:]
            var intervals: [Double] = []
            var previous = ContinuousClock.now
            let start = previous
            let startCPU = cpuMilliseconds()
            var previousY = scrollView.contentView.bounds.minY
            var distance: CGFloat = 0
            let hoverOnly = scenario == "reply-hover"
            let eventCount = hoverOnly ? 120 : 240
            var postedHoverEvents = 0
            // Native coordinates increase downward only in a flipped clip.
            var direction: CGFloat = scrollView.contentView.isFlipped ? 1 : -1
            for index in 0..<eventCount {
                // Reverse before an edge instead of spending most of a
                // short-list workload pressing against the scroll limit.
                let range = ScrollViewport.verticalRange(of: scrollView)
                let currentY = scrollView.contentView.bounds.minY
                if direction > 0, currentY >= range.upperBound - 14 { direction = -1 }
                else if direction < 0, currentY <= range.lowerBound + 14 { direction = 1 }
                if !hoverOnly {
                    let flipSign: CGFloat = scrollView.contentView.isFlipped ? 1 : -1
                    postScroll(in: scrollView, window: window, deltaY: Int32(-direction * flipSign * 14),
                               phase: index == 0 ? 1 : 2)
                }
                if let point = hoverOnly && !index.isMultiple(of: 2) ? outsidePoint : hoverPoint,
                   postHover(at: point, window: window) {
                    postedHoverEvents += 1
                }
                try? await Task.sleep(for: hoverOnly ? .milliseconds(16) : .milliseconds(8))
                let now = ContinuousClock.now
                intervals.append(milliseconds(previous.duration(to: now)))
                previous = now
                let y = scrollView.contentView.bounds.minY
                distance += abs(y - previousY)
                previousY = y
            }
            if !hoverOnly { postScroll(in: scrollView, window: window, deltaY: 0, phase: 4) }
            try? await Task.sleep(for: .milliseconds(50))
            let wall = milliseconds(start.duration(to: .now))
            let cpu = cpuMilliseconds() - startCPU
            intervals.sort()
            measurements.append(Measurement(
                scenario: scenario, notificationCount: WindowOpener.shared.store?.selectedDevice?.notifications.count ?? 0,
                replyableNotificationCount: WindowOpener.shared.store?.selectedDevice?.notifications
                    .filter { !$0.replyId.isEmpty }.count ?? 0,
                swipeViewCount: swipeViews, eventMonitorCount: monitors,
                deliveredScrollEvents: hoverOnly ? 0 : eventCount + 1,
                postedHoverEvents: postedHoverEvents,
                scrollDistancePoints: Double(distance),
                documentHeightPoints: Double(scrollView.documentView?.bounds.height ?? 0),
                scrollViewAttached: scrollView.window === window,
                scrollableRangePoints: Double(scrollableRange),
                viewportWidthPoints: Double(visibleViewport.width),
                viewportHeightPoints: Double(visibleViewport.height),
                bodyUpdateCounts: updates,
                wallMilliseconds: wall, cpuMilliseconds: cpu,
                inputIntervalP50Milliseconds: intervals[intervals.count / 2],
                inputIntervalP95Milliseconds: intervals[Int(Double(intervals.count - 1) * 0.95)],
                inputIntervalMaxMilliseconds: intervals.last ?? 0))
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(measurements).write(to: URL(fileURLWithPath: path))
            print("UI benchmark saved to \(path)")
        } catch {
            print("UI benchmark could not save results: \(error)")
            exit(EXIT_FAILURE)
        }
        NSApp.terminate(nil)
    }

    private static func postScroll(in view: NSView, window: NSWindow, deltaY: Int32, phase: Int64) {
        let point = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: deltaY, wheel2: 0, wheel3: 0) else { return }
        cg.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(deltaY))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        // Deliver to the selected scroll view directly. Windowless CGEvents
        // in an unsigned command-line build do not have a reliable hit target.
        // This keeps the scroll distance independent of focus and the pointer.
        if let event = NSEvent(cgEvent: cg), let scrollView = view as? NSScrollView {
            scrollView.scrollWheel(with: event)
        }
    }

    @discardableResult
    private static func postHover(at point: NSPoint, window: NSWindow) -> Bool {
        // Keep a synthetic pointer over the content without moving the
        // user's actual cursor. This exercises reply-on-hover while scrolling.
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(event, atStart: false)
            return true
        }
        return false
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func notificationScrollView(in window: NSWindow) -> NSScrollView? {
        // The sidebar can have a taller document than a short notification
        // list. Select the scroll view that actually contains the cards.
        descendants(of: window.contentView)
            .compactMap { $0 as? HorizontalSwipeCatcher.CatcherView }
            .compactMap(\.enclosingScrollView)
            .first
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
    }
}
