import AppKit
import Testing
@testable import KDEConnectNative

@MainActor
@Suite(.serialized)
struct HorizontalSwipeTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                        styleMask: [], backing: .buffered, defer: false)
    }

    private func event(dx: Int32 = 0, dy: Int32 = 0, phase: Int64,
                       momentum: Int64 = 0, precise: Bool = true) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                     wheel1: dy, wheel2: dx, wheel3: 0))
        cg.location = CGPoint(x: 50, y: (NSScreen.screens.first?.frame.maxY ?? 0) - 50)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        return try #require(NSEvent(cgEvent: cg))
    }

    private func catcher(in window: NSWindow) -> HorizontalSwipeCatcher.CatcherView {
        let view = HorizontalSwipeCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(view)
        return view
    }

    @Test func sharesOneMonitorAndRemovesIt() {
        let window = window()
        let views = (0..<100).map { _ in catcher(in: window) }
        #expect(HorizontalSwipeCatcher.CatcherView.monitorCount == 1)
        for view in views { view.removeFromSuperview() }
        #expect(HorizontalSwipeCatcher.CatcherView.monitorCount == 0)
    }

    @Test func disabledViewsDoNotMonitor() {
        let window = window()
        let view = catcher(in: window)
        view.active = false
        #expect(HorizontalSwipeCatcher.CatcherView.monitorCount == 0)
        view.active = true
        #expect(HorizontalSwipeCatcher.CatcherView.monitorCount == 1)
        view.removeFromSuperview()
        #expect(HorizontalSwipeCatcher.CatcherView.monitorCount == 0)
    }

    @Test func verticalScrollingPassesThrough() throws {
        let window = window()
        let view = catcher(in: window)
        defer { view.removeFromSuperview() }
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        defer { HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = false }
        var changes = 0
        view.onChange = { _, _ in changes += 1 }
        let began = try event(dy: 10, phase: 1)
        #expect(view.accepts(began))
        #expect(HorizontalSwipeRouter.shared.route(began) === began)
        let changed = try event(dx: 30, dy: 10, phase: 2)
        #expect(HorizontalSwipeRouter.shared.route(changed) === changed)
        #expect(changes == 0)
    }

    @Test func horizontalSwipeAndMomentumAreConsumed() throws {
        let window = window()
        let view = catcher(in: window)
        defer { view.removeFromSuperview() }
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        defer { HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = false }
        var deltas: [CGFloat] = []
        var widths: [CGFloat] = []
        var ends = 0
        view.onChange = { delta, width in deltas.append(delta); widths.append(width) }
        view.onEnd = { ends += 1 }
        #expect(HorizontalSwipeRouter.shared.route(try event(dx: 8, phase: 1)) == nil)
        #expect(HorizontalSwipeRouter.shared.route(try event(dx: 12, phase: 2)) == nil)
        #expect(HorizontalSwipeRouter.shared.route(try event(phase: 4)) == nil)
        #expect(HorizontalSwipeRouter.shared.route(try event(dx: 4, phase: 0, momentum: 1)) == nil)
        #expect(HorizontalSwipeRouter.shared.route(try event(phase: 0, momentum: 3)) == nil)
        #expect(deltas == [8, 12])
        #expect(widths == [200, 200])
        #expect(ends == 1)
        let idle = try event(dy: 10, phase: 0)
        #expect(HorizontalSwipeRouter.shared.route(idle) === idle)
    }

    @Test func accumulatesSmallDeltasBeforeChoosingDirection() throws {
        let window = window()
        let view = catcher(in: window)
        defer { view.removeFromSuperview() }
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        defer { HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = false }
        var deltas: [CGFloat] = []
        view.onChange = { delta, _ in deltas.append(delta) }
        let began = try event(dx: 2, phase: 1)
        #expect(HorizontalSwipeRouter.shared.route(began) === began)
        let changed = try event(dx: 3, phase: 2)
        #expect(HorizontalSwipeRouter.shared.route(changed) === changed)
        #expect(HorizontalSwipeRouter.shared.route(try event(dx: 2, phase: 2)) == nil)
        #expect(deltas == [7])
    }

    @Test func hiddenClippedAndWindowlessViewsDoNotStartSwipes() throws {
        let window = window()
        let view = catcher(in: window)
        defer { view.removeFromSuperview() }
        let began = try event(dx: 8, phase: 1)
        #expect(!view.accepts(began))
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        defer { HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = false }
        #expect(view.accepts(began))
        view.isHidden = true
        #expect(!view.accepts(began))
        view.isHidden = false
        view.setFrameOrigin(NSPoint(x: 250, y: 250))
        window.contentView?.layoutSubtreeIfNeeded()
        let acceptedAfterMove = view.accepts(began)
        #expect(!acceptedAfterMove)
        view.removeFromSuperview()
        let clip = NSView(frame: NSRect(x: 0, y: 0, width: 25, height: 25))
        clip.clipsToBounds = true
        window.contentView?.addSubview(clip)
        view.setFrameOrigin(.zero)
        clip.addSubview(view)
        #expect(!view.accepts(began))
    }

    @Test func legacyWheelEventsPassThrough() throws {
        let window = window()
        let view = catcher(in: window)
        defer { view.removeFromSuperview() }
        let wheel = try event(dx: 10, phase: 1, precise: false)
        #expect(HorizontalSwipeRouter.shared.route(wheel) === wheel)
    }
}
