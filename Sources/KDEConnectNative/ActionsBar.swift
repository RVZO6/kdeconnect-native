import KDEConnectKit
import SwiftUI

/// The device actions as icons in one floating glass capsule. A label with
/// the name of an action shows above it on hover and slides from one action
/// to the next. While files go out, a progress capsule comes out of the bar.
struct ActionsBar: View {
    @Environment(KDEConnectStore.self) private var store
    let device: Device

    @Namespace private var glass
    @State private var hovered: String?
    /// The action that the label points at. It stays set after the label hides.
    @State private var labelAnchor: String?
    @State private var hideTask: Task<Void, Never>?
    /// When the Messages pop-up last closed.
    @State private var messagesClosedAt: ContinuousClock.Instant?

    /// The progress capsule has a fixed width, and the same space stays
    /// empty on the other side, so that the actions never move.
    static let transferWidth: CGFloat = 76
    private static let transferSpacing: CGFloat = 10

    var body: some View {
        let transfer = store.transfers[device.id]
        // Less than the gap, so that the two capsules join only while the
        // progress capsule grows out of the bar or shrinks back into it.
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: Self.transferSpacing) {
                Color.clear.frame(width: Self.transferWidth, height: 1)
                actions
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("actions", in: glass)
                ZStack {
                    if let transfer {
                        TransferCapsule(transfer: transfer)
                            .hoverLabel(TransferCapsule.label(transfer), id: "transfer", hovered: hover)
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("transfer", in: glass)
                            .transition(.blurReplace.combined(with: .scale(0.4, anchor: .leading))
                                .combined(with: .offset(x: -Self.transferWidth / 2)))
                    }
                }
                .frame(width: Self.transferWidth, alignment: .leading)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: transfer.map(ObjectIdentifier.init))
        .onReceive(NotificationCenter.default.publisher(for: .debugHoverAction)) { note in
            if let id = note.object as? String { hover(id, true) } else if let hovered { hover(hovered, false) }
        }
        .overlayPreferenceValue(HoverLabelKey.self) { labels in
            GeometryReader { proxy in
                // The label stays at the last action while it fades out. The
                // transition is on the label, not on the positioned view, so
                // that it grows up out of the action under the pointer.
                if let shown = labels.first(where: { $0.id == labelAnchor }) {
                    let frame = proxy[shown.anchor]
                    ZStack {
                        if hovered != nil {
                            HoverLabel(text: shown.text)
                                .transition(.opacity.combined(with: .scale(0.7, anchor: .bottom))
                                    .combined(with: .offset(y: 4)))
                        }
                    }
                    .position(x: frame.midX, y: frame.minY - 20)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var actions: some View {
        let id = device.id
        return HStack(spacing: 2) {
            if device.has(.findMyPhone) {
                ActionButton("Ring", symbol: "speaker.wave.3", hovered: hover) {
                    store.perform("Ring") { try await $0.ring(id) }
                }
            }
            if device.has(.ping) {
                ActionButton("Ping", symbol: "dot.radiowaves.left.and.right", hovered: hover) {
                    store.perform("Ping") { try await $0.ping(id) }
                }
            }
            if device.has(.clipboard) {
                ActionButton("Send Clipboard", symbol: "doc.on.clipboard", hovered: hover) {
                    store.perform("Send clipboard") { try await $0.sendClipboard(id) }
                }
            }
            if device.has(.share) {
                ActionButton("Send Files", symbol: "paperplane", hovered: hover) {
                    FileSender.choose(for: device, store: store)
                }
            }
            if device.has(.sms) {
                ActionButton("Messages", symbol: "message", hovered: hover, action: openMessages)
                    .popover(isPresented: messagesShown, arrowEdge: .top) {
                        MessagesPopover(deviceId: id)
                            .environment(store)
                    }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var messagesShown: Binding<Bool> {
        Binding {
            store.messagesDeviceId == device.id
        } set: { shown in
            guard !shown, store.messagesDeviceId == device.id else { return }
            store.messagesDeviceId = nil
            messagesClosedAt = .now
        }
    }

    private func openMessages() {
        // A click on the button while the pop-up is open first closes the
        // pop-up. The click must not open it again.
        if let closed = messagesClosedAt, ContinuousClock.now - closed < .milliseconds(300) { return }
        hover("Messages", false)
        let id = device.id
        Task {
            await store.contacts(for: id).requestAccess()
            // The user can select another device while the prompt is open.
            // A stale ID would open the pop-up later, on a return to this one.
            guard store.selectedDeviceId == id else { return }
            store.messagesDeviceId = id
        }
    }

    /// Shows a label at once. Hides it a moment later, so that a move to the
    /// next action slides the label there instead of hiding and showing it.
    private func hover(_ id: String, _ inside: Bool) {
        hideTask?.cancel()
        // The label must not show under the open pop-up's arrow.
        if inside, id == "Messages", store.messagesDeviceId == device.id { return }
        if inside {
            if hovered == nil { labelAnchor = id }
            withAnimation(.snappy(duration: hovered == nil ? 0.16 : 0.24)) {
                hovered = id
                labelAnchor = id
            }
        } else if hovered == id {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.14)) { hovered = nil }
            }
        }
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let hovered: (String, Bool) -> Void
    let action: () -> Void

    init(_ title: String, symbol: String, hovered: @escaping (String, Bool) -> Void, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.hovered = hovered
        self.action = action
    }

    /// An icon only; the name shows in the hover label and to VoiceOver.
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarGlyphButtonStyle())
        .foregroundStyle(.primary)
        .hoverLabel(title, id: title, hovered: hovered)
        .accessibilityLabel(title)
    }
}

/// A ring that fills while the files go out, then a check mark or a warning.
private struct TransferCapsule: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                switch transfer.phase {
                case .sending:
                    ProgressRing(fraction: transfer.fraction)
                        .transition(.scale(0.5).combined(with: .opacity))
                case .finished:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white, .green)
                        .transition(.scale(0.5).combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white, .orange)
                        .transition(.scale(0.5).combined(with: .opacity))
                }
            }
            .frame(width: 20, height: 20)
            Text(status)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                // The number changes ten times a second; an animation on
                // each change would keep it blurred.
                .transaction { $0.animation = nil }
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: transfer.phase)
        .animation(.smooth(duration: 0.2), value: transfer.fraction)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(transfer))
        .accessibilityValue(status)
    }

    private var status: String {
        switch transfer.phase {
        case .sending: "\(Int((transfer.fraction * 100).rounded(.down)))%"
        case .finished: "Sent"
        case .failed: "Failed"
        }
    }

    /// The hover label: which file goes out, or why the transfer failed.
    static func label(_ transfer: FileTransfer) -> String {
        let items = transfer.items
        let current = items.indices.contains(transfer.currentIndex) ? items[transfer.currentIndex].name : ""
        switch transfer.phase {
        case .failed(let reason): return reason
        case .finished: return items.count == 1 ? "Sent \(current)" : "Sent \(items.count) files"
        case .sending:
            return items.count == 1 ? "Sending \(current)"
                : "Sending \(current) (\(transfer.currentIndex + 1) of \(items.count))"
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}

/// The small label above the bar, like a tooltip but at once and without
/// the system delay.
private struct HoverLabel: View {
    let text: String

    var body: some View {
        Text(Self.shortened(text))
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    /// Keeps a long file name from making the label wider than the window.
    static func shortened(_ text: String, limit: Int = 44) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return text.prefix(half) + "…" + text.suffix(half)
    }
}

private struct HoverLabelAnchor {
    let id: String
    let text: String
    let anchor: Anchor<CGRect>
}

private struct HoverLabelKey: PreferenceKey {
    static let defaultValue: [HoverLabelAnchor] = []
    static func reduce(value: inout [HoverLabelAnchor], nextValue: () -> [HoverLabelAnchor]) {
        value += nextValue()
    }
}

private extension View {
    /// Reports this view's frame and label to the bar, and its hover state.
    func hoverLabel(_ text: String, id: String, hovered: @escaping (String, Bool) -> Void) -> some View {
        onHover { hovered(id, $0) }
            .anchorPreference(key: HoverLabelKey.self, value: .bounds) { [HoverLabelAnchor(id: id, text: text, anchor: $0)] }
    }
}
