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
                NotificationGroup(
                    app: group.app, items: group.items, deviceId: device.id,
                    isExpanded: Binding(
                        get: { group.items.count == 1 || expanded.contains(group.app) },
                        set: { open in
                            if open { expanded.insert(group.app) } else { expanded.remove(group.app) }
                        }),
                    onDismissed: { id in
                        withAnimation(.snappy(duration: 0.25)) { _ = dismissed.insert(id) }
                    },
                    onClear: { clear(group.items) })
            }
        }
        .onChange(of: device.notifications.map(\.id)) { _, ids in
            dismissed.formIntersection(ids)
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

/// One app's notifications. With more than one, they collapse into a
/// stack of real cards: the newest in front, the next two peeking out
/// below it, slightly smaller. Expanding springs each card out of the
/// stack into its own place in the list; collapsing springs them back.
private struct NotificationGroup: View {
    let app: String
    let items: [PhoneNotification]
    let deviceId: String
    @Binding var isExpanded: Bool
    let onDismissed: (String) -> Void
    let onClear: () -> Void
    /// The front card's height; the cards behind take it while stacked.
    @State private var frontHeight: CGFloat = 60

    private var isStacked: Bool { !isExpanded && items.count > 1 }
    private static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .onReceive(NotificationCenter.default.publisher(for: .debugToggleStacks)) { _ in
                    guard items.count > 1 else { return }
                    withAnimation(Self.spring) { isExpanded.toggle() }
                }
            StackLayout(stacked: isStacked) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, notification in
                    card(notification, index: index)
                }
            }
            .modifier(StackSwipe(enabled: isStacked && items.contains(where: \.dismissable), onSwipe: onClear))
        }
    }

    private func card(_ notification: PhoneNotification, index: Int) -> some View {
        let depth = isStacked ? min(index, 2) : 0
        let behind = isStacked && index > 0
        return NotificationCard(
            deviceId: deviceId, notification: notification, showsAppName: false,
            contentHidden: behind, fixedHeight: behind ? frontHeight : nil,
            swipeEnabled: !isStacked,
            onDismissed: { onDismissed(notification.id) })
        .scaleEffect(1 - 0.05 * CGFloat(depth), anchor: .bottom)
        .opacity(isStacked && index > 2 ? 0 : 1)
        .allowsHitTesting(!behind)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if index == 0, !behind { frontHeight = height }
        }
        .overlay {
            // While stacked, a click anywhere on the front card opens the stack.
            Color.clear
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture { withAnimation(Self.spring) { isExpanded = true } }
                .help("Show all \(items.count) notifications")
                .allowsHitTesting(isStacked && index == 0)
        }
        // Outermost, so that the stack layout draws the newest card on top.
        .zIndex(Double(-index))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if items.count > 1 {
                Button {
                    withAnimation(Self.spring) { isExpanded.toggle() }
                } label: {
                    // The chevron follows the count, so that every app name
                    // starts at the same edge.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(app).font(.headline)
                        Text("\(items.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")
            } else {
                Text(app).font(.headline)
            }
            Spacer()
            if items.contains(where: \.dismissable) {
                Button("Clear", action: onClear)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Dismiss all \(app) notifications on the device")
            }
        }
        .padding(.horizontal, 11)
    }
}

/// Swipe to dismiss that can be switched off without changing the view
/// structure. A branch here would give the cards a new identity when a
/// stack opens or closes, and SwiftUI would fade them instead of moving them.
private struct StackSwipe: ViewModifier {
    let enabled: Bool
    let onSwipe: () -> Void

    func body(content: Content) -> some View {
        content.swipeToDismiss(enabled: true, active: enabled, onDismiss: onSwipe)
    }
}

/// Places cards as a list, or stacked: every card at the top, each one
/// behind offset down by `peek`, so that its bottom edge shows.
private struct StackLayout: Layout {
    var stacked: Bool
    var spacing: CGFloat = 8
    var peek: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        guard let first = heights.first else { return CGSize(width: width, height: 0) }
        if stacked {
            return CGSize(width: width, height: first + peek * CGFloat(min(heights.count - 1, 2)))
        }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(heights.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let origin = stacked
                ? CGPoint(x: bounds.minX, y: bounds.minY + peek * CGFloat(min(index, 2)))
                : CGPoint(x: bounds.minX, y: y)
            subview.place(at: origin, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }
}

private struct NotificationCard: View {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String
    let notification: PhoneNotification
    /// False inside an app group, whose header already names the app.
    var showsAppName = true
    /// True for a card behind the front of a stack: only its edge shows.
    var contentHidden = false
    /// While stacked behind, the card takes the front card's height.
    var fixedHeight: CGFloat? = nil
    /// False while stacked; then the whole stack swipes as one.
    var swipeEnabled = true
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
        .opacity(contentHidden ? 0 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: fixedHeight, alignment: .top)
        .clipped()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        // A faint edge, so that stacked cards read as separate layers.
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(StackSwipe(enabled: swipeEnabled && notification.dismissable, onSwipe: dismiss))
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
    /// When `active` is false, the view ignores swipes and they pass on.
    func swipeToDismiss(enabled: Bool, active: Bool = true, onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeToDismiss(enabled: enabled, active: active, onDismiss: onDismiss))
    }
}

private struct SwipeToDismiss: ViewModifier {
    let enabled: Bool
    var active = true
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
                HorizontalSwipeCatcher(active: active, onChange: change, onEnd: end)
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
    var active = true
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.active = active
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class CatcherView: NSView {
        var active = true
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
                tracking = active && bounds.contains(point) ? .deciding : .idle
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
