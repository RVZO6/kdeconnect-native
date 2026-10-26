import AppKit
import KDEConnectKit
import Observation
import SwiftUI

/// Phone notifications as separate cards. Swipe a card off to either side
/// with two fingers to dismiss it, as with notification banners.
struct NotificationCards: View, Equatable {
    @Environment(KDEConnectStore.self) private var store
    let deviceId: String
    let isReachable: Bool
    let notifications: [PhoneNotification]
    /// Cards that flew off. They stay hidden until the phone confirms.
    @State private var dismissed: Set<String> = []
    /// Apps whose group is open. A group of more than one starts as a stack.
    @State private var expanded: Set<String> = []

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.deviceId == rhs.deviceId && lhs.isReachable == rhs.isReachable && lhs.notifications == rhs.notifications
    }

    /// Notifications grouped by app. The app with the newest notification
    /// comes first; inside a group, the newest is on top.
    private var groups: [(app: String, items: [PhoneNotification])] {
        let visible = notifications.filter { !dismissed.contains($0.id) }
        var order: [String] = []
        var byApp: [String: [PhoneNotification]] = [:]
        // notifications is already newest first.
        for item in visible {
            let app = item.appName.isEmpty ? "Other" : item.appName
            if byApp[app] == nil { order.append(app) }
            byApp[app, default: []].append(item)
        }
        return order.map { ($0, byApp[$0]!) }
    }

    var body: some View {
        let _ = UIBenchmark.recordUpdate("NotificationCards")
        let groups = groups
        LazyVStack(alignment: .leading, spacing: 18) {
            if groups.isEmpty {
                Text(isReachable ? "No notifications." : "Notifications show when the device is connected.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
            }
            ForEach(groups, id: \.app) { group in
                NotificationGroup(
                    app: group.app, items: group.items, deviceId: deviceId,
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
        .onChange(of: notifications.map(\.id)) { _, ids in
            dismissed.formIntersection(ids)
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugToggleStacks)) { _ in
            // Keep this on the parent: off-screen lazy groups do not have
            // a header subscriber yet, but must use the same expanded state.
            let apps = Set(groups.filter { $0.items.count > 1 }.map(\.app))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                expanded = apps.isSubset(of: expanded) ? [] : apps
            }
        }
    }

    private func clear(_ items: [PhoneNotification]) {
        let targets = items.filter(\.dismissable)
        withAnimation(.snappy(duration: 0.25)) { dismissed.formUnion(targets.map(\.id)) }
        let deviceId = self.deviceId
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
        let _ = UIBenchmark.recordUpdate("NotificationGroup")
        VStack(alignment: .leading, spacing: 8) {
            header
            StackLayout(stacked: isStacked) {
                ForEach(items.enumerated(), id: \.element.id) { index, notification in
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
        .background {
            // Only the front card determines the collapsed height. Keep
            // this observer out of every other card's geometry graph.
            if index == 0 {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { frontHeight = $0 }
                    .allowsHitTesting(false)
            }
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

    /// The app's first letter on a tile in the app's own colour.
    private var appTile: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(appTint(for: app).gradient)
            .frame(width: 20, height: 20)
            .overlay {
                Text(app.prefix(1).uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
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
                        appTile
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    appTile
                    Text(app).font(.headline)
                }
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
        guard let front = subviews.first else { return CGSize(width: width, height: 0) }
        if stacked {
            // Every card behind the front has the front's fixed height.
            // Measuring invisible cards still builds and lays out their text.
            let height = front.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return CGSize(width: width, height: height + peek * CGFloat(min(subviews.count - 1, 2)))
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(heights.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if stacked {
            guard let front = subviews.first else { return }
            let height = front.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + peek * CGFloat(min(index, 2))),
                              proposal: ProposedViewSize(width: bounds.width, height: height))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y),
                          proposal: ProposedViewSize(width: bounds.width, height: size.height))
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
    @State private var hover = NotificationHoverState()

    var body: some View {
        let _ = UIBenchmark.recordUpdate("NotificationCard")
        VStack(alignment: .leading, spacing: 6) {
            // Keep the card, its identity, and its reply state in the layout,
            // but do not build text fields or glass buttons behind a stack.
            if !contentHidden {
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
                    // Highlight and copy the text with the pointer.
                    .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if canReply {
                        NotificationReplyButton(hover: hover, replying: $replying)
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
        }
        .padding(12)
        .opacity(contentHidden ? 0 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: fixedHeight, alignment: .top)
        .clipped()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        // A faint edge, so that stacked cards read as separate layers.
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
        .onHover { hover.isHovering = $0 }
        .modifier(StackSwipe(enabled: swipeEnabled && notification.dismissable, onSwipe: dismiss))
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                let text = [notification.title, notification.text].filter { !$0.isEmpty }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
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

/// Only the reply button observes hover changes. The text, card layout,
/// context menu and native swipe catcher do not need to rebuild for them.
@MainActor
@Observable
private final class NotificationHoverState {
    var isHovering = false
}

private struct NotificationReplyButton: View {
    let hover: NotificationHoverState
    @Binding var replying: Bool

    var body: some View {
        let _ = UIBenchmark.recordUpdate("NotificationReplyButton")
        Button("Reply", systemImage: "arrowshape.turn.up.left") { replying.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .opacity(hover.isHovering || replying ? 1 : 0)
            .help("Reply")
            .animation(.easeOut(duration: 0.12), value: hover.isHovering)
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
                // Only the event catcher is conditional, not the card. A
                // disabled catcher must not install a scroll-event monitor.
                if active {
                    HorizontalSwipeCatcher(onChange: change, onEnd: end)
                }
            }
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

    private func change(_ delta: CGFloat, width: CGFloat) {
        // Read the width from the native catcher only during a swipe, not
        // through a SwiftUI geometry observer on every scrolling card.
        self.width = width
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
