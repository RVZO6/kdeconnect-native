import AppKit
import KDEConnectKit
import SwiftUI

/// Phone notifications as separate cards. Swipe a card off to either side
/// with two fingers to dismiss it, as with notification banners.
struct NotificationCards: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device
    /// Cards that flew off. They stay hidden until the phone confirms.
    @State private var dismissed: Set<String> = []

    var body: some View {
        let visible = device.notifications.filter { !dismissed.contains($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.headline)
                .padding(.horizontal, 11)
            if visible.isEmpty {
                Text(device.isReachable ? "No notifications." : "Notifications show when the device is connected.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
            }
            ForEach(visible) { notification in
                NotificationCard(deviceId: device.id, notification: notification) {
                    withAnimation(.snappy(duration: 0.25)) { _ = dismissed.insert(notification.id) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .onChange(of: device.notifications.map(\.id)) { _, ids in
            dismissed.formIntersection(ids)
        }
    }
}

private struct NotificationCard: View {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String
    let notification: PhoneNotification
    let onDismissed: () -> Void
    @State private var replying = false
    @State private var reply = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.appName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if !notification.title.isEmpty {
                        Text(notification.title).fontWeight(.medium)
                    }
                    if !notification.text.isEmpty {
                        Text(notification.text).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                Spacer(minLength: 8)
                if canReply {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { replying.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .opacity(hovering || replying ? 1 : 0)
                        .help("Reply")
                }
            }
            if replying {
                HStack {
                    TextField("Reply", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendReply)
                    Button("Send", action: sendReply).disabled(reply.isEmpty)
                    Button("Cancel") { replying = false; reply = "" }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .swipeToDismiss(enabled: notification.dismissable, onDismiss: dismiss)
        .contextMenu {
            if canReply {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { replying = true }
            }
            if notification.dismissable {
                Button("Dismiss on Device", systemImage: "xmark") { dismiss() }
            }
        }
    }

    private var canReply: Bool { !notification.replyId.isEmpty }

    private func dismiss() {
        onDismissed()
        let (d, n) = (deviceId, notification.id)
        store.perform("Dismiss") { try await $0.dismissNotification(deviceId: d, notificationId: n) }
    }

    private func sendReply() {
        guard !reply.isEmpty else { return }
        let (d, r, m) = (deviceId, notification.replyId, reply)
        store.perform("Reply") { try await $0.replyToNotification(deviceId: d, replyId: r, message: m) }
        reply = ""
        replying = false
    }
}

// MARK: - Swipe to dismiss

extension View {
    /// Lets a two-finger horizontal swipe move the view. Past a threshold,
    /// releasing flies it off in that direction and calls `onDismiss`.
    func swipeToDismiss(enabled: Bool, onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeToDismiss(enabled: enabled, onDismiss: onDismiss))
    }
}

private struct SwipeToDismiss: ViewModifier {
    let enabled: Bool
    let onDismiss: () -> Void
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 400
    @State private var armed = false

    private var threshold: CGFloat { min(140, width * 0.35) }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background { indicators }
            .background {
                HorizontalSwipeCatcher(onChange: change, onEnd: end)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The dismiss marker shows on the side that the card uncovers.
    private var indicators: some View {
        let progress = min(abs(offset) / threshold, 1)
        return HStack {
            if offset > 0 { marker(progress) }
            Spacer()
            if offset < 0 { marker(progress) }
        }
        .padding(.horizontal, 14)
        .opacity(enabled ? 1 : 0)
    }

    private func marker(_ progress: CGFloat) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(armed ? Color.red : Color.secondary.opacity(0.5)))
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(Double(progress))
            .animation(.snappy(duration: 0.15), value: armed)
            .accessibilityHidden(true)
    }

    private func change(_ delta: CGFloat) {
        // Without a dismiss action the card only gives a little, then stops.
        offset += enabled ? delta : delta * 0.15
        if !enabled { offset = max(-24, min(24, offset)) }
        let nowArmed = enabled && abs(offset) > threshold
        if nowArmed != armed {
            armed = nowArmed
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func end() {
        if armed {
            let direction: CGFloat = offset < 0 ? -1 : 1
            withAnimation(.easeIn(duration: 0.18)) { offset = direction * (width + 80) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss() }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
        }
        armed = false
    }
}

/// Reports horizontal two-finger swipes over its area.
///
/// SwiftUI drag gestures need a click; a trackpad swipe arrives as scroll
/// events with phases. A local event monitor watches them. A gesture that
/// starts mostly horizontal over this view belongs to the swipe and is not
/// passed on; anything else goes to the scroll view as usual. The view
/// itself takes no clicks.
struct HorizontalSwipeCatcher: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class CatcherView: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        private var monitor: Any?

        /// Set by the swipe test: events that it posts itself have no window.
        static var acceptsWindowlessEvents = false

        private enum Tracking { case idle, deciding, swiping, momentum, ignoring }
        private var tracking = Tracking.idle
        private var startX: CGFloat = 0
        private var startY: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // Local monitors run on the main thread.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let incoming = event
                nonisolated(unsafe) var outgoing: NSEvent? = event
                MainActor.assumeIsolated { outgoing = self?.handle(incoming) ?? incoming }
                return outgoing
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let ownWindow = event.window === window || (event.window == nil && Self.acceptsWindowlessEvents)
            guard ownWindow, event.hasPreciseScrollingDeltas else { return event }

            if event.phase == .began {
                let point = convert(event.locationInWindow, from: nil)
                tracking = bounds.contains(point) ? .deciding : .idle
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
                    onChange(startX)
                    return nil
                }
                if abs(startY) > 6 || event.phase == .ended || event.phase == .cancelled { tracking = .ignoring }
                return event
            case .swiping:
                if event.phase == .ended || event.phase == .cancelled {
                    tracking = .momentum
                    onEnd()
                } else {
                    onChange(event.scrollingDeltaX)
                }
                return nil
            case .momentum:
                // Swallow the momentum after the fingers lift.
                if event.momentumPhase.isEmpty && event.phase.isEmpty { tracking = .idle; return event }
                if event.momentumPhase == .ended { tracking = .idle }
                return nil
            }
        }
    }
}
