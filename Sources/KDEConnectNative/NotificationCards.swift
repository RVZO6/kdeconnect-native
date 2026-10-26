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
    /// Apps whose group is open. A group of more than one starts as a stack.
    @State private var expanded: Set<String> = []

    /// Notifications grouped by app. The app with the newest notification
    /// comes first; inside a group, the newest is on top.
    private var groups: [(app: String, items: [PhoneNotification])] {
        let visible = device.notifications.filter { !dismissed.contains($0.id) }
        var order: [String] = []
        var byApp: [String: [PhoneNotification]] = [:]
        // device.notifications is already newest first.
        for item in visible {
            let app = item.appName.isEmpty ? "Other" : item.appName
            if byApp[app] == nil { order.append(app) }
            byApp[app, default: []].append(item)
        }
        return order.map { ($0, byApp[$0]!) }
    }

    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: 18) {
            if groups.isEmpty {
                Text(device.isReachable ? "No notifications." : "Notifications show when the device is connected.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
            }
            ForEach(groups, id: \.app) { group in
                let isOpen = group.items.count == 1 || expanded.contains(group.app)
                VStack(alignment: .leading, spacing: 8) {
                    header(group, isOpen: isOpen)
                    if isOpen {
                        ForEach(group.items) { notification in
                            NotificationCard(deviceId: device.id, notification: notification,
                                             showsAppName: false) {
                                withAnimation(.snappy(duration: 0.25)) { _ = dismissed.insert(notification.id) }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    } else {
                        stack(group)
                    }
                }
            }
        }
        .onChange(of: device.notifications.map(\.id)) { _, ids in
            dismissed.formIntersection(ids)
        }
    }

    private func header(_ group: (app: String, items: [PhoneNotification]), isOpen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if group.items.count > 1 {
                Button {
                    toggle(group.app)
                } label: {
                    // The chevron follows the count, so that every app name
                    // starts at the same edge.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(group.app).font(.headline)
                        Text("\(group.items.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Collapse" : "Expand")
            } else {
                Text(group.app).font(.headline)
            }
            Spacer()
            if group.items.contains(where: \.dismissable) {
                Button("Clear") { clear(group.items) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Dismiss all \(group.app) notifications on the device")
            }
        }
        .padding(.horizontal, 11)
    }

    /// A collapsed group: the newest card in front, the edges of two more
    /// behind it. Click to open; swipe it off to clear the whole group.
    private func stack(_ group: (app: String, items: [PhoneNotification])) -> some View {
        let first = group.items[0]
        return Button {
            toggle(group.app)
        } label: {
            NotificationSummary(notification: first, more: group.items.count - 1)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        .padding(.bottom, group.items.count > 2 ? 12 : 6)
        .background(alignment: .bottom) {
            // The edges of the cards behind, each a little darker and narrower.
            ZStack(alignment: .bottom) {
                if group.items.count > 2 {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.05))
                        .padding(.horizontal, 24)
                        .frame(height: 40)
                }
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.primary.opacity(0.08))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .padding(.bottom, group.items.count > 2 ? 6 : 0)
            }
        }
        .swipeToDismiss(enabled: group.items.contains(where: \.dismissable)) { clear(group.items) }
        .help("Show all \(group.items.count) notifications")
    }

    private func toggle(_ app: String) {
        withAnimation(.snappy(duration: 0.25)) {
            if expanded.contains(app) { expanded.remove(app) } else { expanded.insert(app) }
        }
    }

    private func clear(_ items: [PhoneNotification]) {
        let targets = items.filter(\.dismissable)
        withAnimation(.snappy(duration: 0.25)) { dismissed.formUnion(targets.map(\.id)) }
        let deviceId = device.id
        let ids = targets.map(\.id)
        store.perform("Clear notifications") { client in
            for id in ids { try await client.dismissNotification(deviceId: deviceId, notificationId: id) }
        }
    }
}

/// The front card of a collapsed stack.
private struct NotificationSummary: View {
    let notification: PhoneNotification
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !notification.title.isEmpty {
                Text(notification.title).fontWeight(.medium)
            }
            if !notification.text.isEmpty {
                Text(notification.text).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("\(more) more").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct NotificationCard: View {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String
    let notification: PhoneNotification
    /// False inside an app group, whose header already names the app.
    var showsAppName = true
    let onDismissed: () -> Void
    @State private var replying = false
    @State private var reply = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if showsAppName {
                        Text(notification.appName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
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
