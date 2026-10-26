import AppKit
import Darwin
import Foundation

/// A daemon-free, real-window workload. Measures main-thread scheduling and
/// process CPU time, not presented frames or GPU time. No screen capture is
/// performed in a timed section.
@MainActor
enum UIBenchmark {

    struct Measurement: Encodable {
        let scenario: String
        let notificationCount: Int
        let swipeViewCount: Int
        let eventMonitorCount: Int
        let deliveredScrollEvents: Int
        let scrollDistancePoints: Double
        let documentHeightPoints: Double
        let scrollViewAttached: Bool
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let inputIntervalP50Milliseconds: Double
        let inputIntervalP95Milliseconds: Double
        let inputIntervalMaxMilliseconds: Double
    }

    static func run(to path: String) async {
        guard CommandLine.arguments.contains("--demo") else {
            print("--ui-benchmark requires --demo; no live device data is used")
            NSApp.terminate(nil)
            return
        }
        WindowOpener.shared.showMainWindow()
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { WindowOpener.isMainWindow($0) && $0.isVisible }) else {
            print("UI benchmark: no main window")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 900, height: 640))
        try? await Task.sleep(for: .seconds(1))
        let scrollViews = descendants(of: window.contentView).compactMap { $0 as? NSScrollView }
        guard let scrollView = scrollViews.max(by: {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        }) else {
            print("UI benchmark: no scroll view")
            NSApp.terminate(nil)
            return
        }
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        var measurements: [Measurement] = []
        for scenario in ["collapsed-scroll", "expanded-scroll"] {
            if scenario == "expanded-scroll" {
                NotificationCenter.default.post(name: .debugToggleStacks, object: nil)
                try? await Task.sleep(for: .seconds(1))
            }
            let scrollViews = descendants(of: window.contentView).compactMap { $0 as? NSScrollView }
            let scrollView = scrollViews.max(by: {
                ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
            }) ?? scrollView
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try? await Task.sleep(for: .milliseconds(500))
            let views = descendants(of: window.contentView)
            let swipeViews = views.filter { $0 is HorizontalSwipeCatcher.CatcherView }.count
            let monitors = HorizontalSwipeCatcher.CatcherView.monitorCount
            var intervals: [Double] = []
            var previous = ContinuousClock.now
            let start = previous
            let startCPU = cpuMilliseconds()
            var previousY = scrollView.contentView.bounds.minY
            var distance: CGFloat = 0
            let eventCount = 240
            for index in 0..<eventCount {
                postScroll(in: scrollView, window: window, deltaY: index < eventCount / 2 ? -14 : 14,
                           phase: index == 0 ? 1 : 2)
                try? await Task.sleep(for: .milliseconds(8))
                let now = ContinuousClock.now
                intervals.append(milliseconds(previous.duration(to: now)))
                previous = now
                let y = scrollView.contentView.bounds.minY
                distance += abs(y - previousY)
                previousY = y
            }
            postScroll(in: scrollView, window: window, deltaY: 0, phase: 4)
            try? await Task.sleep(for: .milliseconds(50))
            let wall = milliseconds(start.duration(to: .now))
            let cpu = cpuMilliseconds() - startCPU
            intervals.sort()
            measurements.append(Measurement(
                scenario: scenario, notificationCount: WindowOpener.shared.store?.selectedDevice?.notifications.count ?? 0,
                swipeViewCount: swipeViews, eventMonitorCount: monitors,
                deliveredScrollEvents: eventCount + 1,
                scrollDistancePoints: Double(distance),
                documentHeightPoints: Double(scrollView.documentView?.bounds.height ?? 0),
                scrollViewAttached: scrollView.window === window,
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

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
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
