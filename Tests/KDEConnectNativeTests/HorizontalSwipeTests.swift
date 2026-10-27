import AppKit
import Observation
import SwiftUI
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
                       momentum: Int64 = 0, precise: Bool = true,
                       screenPoint: NSPoint = NSPoint(x: 50, y: 50)) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                     wheel1: dy, wheel2: dx, wheel3: 0))
        cg.location = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
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

    @Observable final class SwipeVisibility {
        var active = true
        var dismissals = 0
    }

    private final class PositionView: NSView {}

    private struct PositionProbe: NSViewRepresentable {
        func makeNSView(context: Context) -> PositionView { PositionView() }
        func updateNSView(_ view: PositionView, context: Context) {}
    }

    private struct SurvivingSwipe: View {
        let state: SwipeVisibility
        var body: some View {
            PositionProbe()
                .frame(width: 300, height: 100)
                .swipeToDismiss(enabled: true, active: state.active) {
                    state.dismissals += 1
                    state.active = false
                }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @Test func survivingStackReturnsAfterDismissal() async throws {
        let window = window()
        let state = SwipeVisibility()
        let host = NSHostingView(rootView: SurvivingSwipe(state: state))
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let catcher = try #require(descendants(of: host).compactMap {
            $0 as? HorizontalSwipeCatcher.CatcherView
        }.first)
        let probe = try #require(descendants(of: host).compactMap { $0 as? PositionView }.first)
        let initialX = probe.convert(probe.bounds, to: host).minX
        catcher.onChange(200, 300)
        catcher.onEnd()
        // Let both the dismissal and the restoration spring finish.
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        #expect(state.dismissals == 1)
        #expect(!state.active)
        #expect(probe.isDescendant(of: host))
        #expect(abs(probe.convert(probe.bounds, to: host).minX - initialX) < 1)
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

    @Test func swipeStartsOnlyInsideTheInsetScrollViewport() throws {
        let window = window()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 40, left: 20, bottom: 0, right: 0)
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let view = HorizontalSwipeCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        document.addSubview(view)
        defer { view.removeFromSuperview(); scroll.removeFromSuperview() }
        scroll.contentView.scroll(to: .zero)
        HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = true
        defer { HorizontalSwipeCatcher.CatcherView.acceptsWindowlessEvents = false }

        func eventAt(x: CGFloat, y: CGFloat) throws -> NSEvent {
            let pointInWindow = scroll.contentView.convert(NSPoint(x: x, y: y), to: nil)
            let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
            return try event(dx: 8, phase: 1, screenPoint: pointOnScreen)
        }
        let header = try eventAt(x: 50, y: 20)
        let sidebar = try eventAt(x: 10, y: 60)
        let content = try eventAt(x: 50, y: 60)
        #expect(!view.accepts(header))
        #expect(!view.accepts(sidebar))
        #expect(view.accepts(content))
        #expect(HorizontalSwipeRouter.shared.route(header) === header)
        #expect(HorizontalSwipeRouter.shared.route(sidebar) === sidebar)
        #expect(HorizontalSwipeRouter.shared.route(content) == nil)
    }
}

@MainActor
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
