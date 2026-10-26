import KDEConnectKit
import SwiftUI

/// Shows and hides the sidebar as SwiftUI animations.
///
/// Each toggle runs as one SwiftUI animation, so the page moves together
/// with the sidebar. Toggles that arrive during an animation wait their
/// turn, so each one plays in full.
@MainActor
final class SidebarAnimator {
    static let shared = SidebarAnimator()
    static let animation = Animation.smooth(duration: 0.3)
    /// More toggles than this are dropped, so that a long burst ends soon.
    private static let maxPending = 6

    private var pending: [() -> Void] = []
    private var isRunning = false

    func toggle(_ shown: Binding<Bool>) {
        guard pending.count < Self.maxPending else { return }
        pending.append {
            withAnimation(Self.animation) { shown.wrappedValue.toggle() }
        }
        if !isRunning { runNext() }
    }

    private func runNext() {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }
        isRunning = true
        pending.removeFirst()()
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            runNext()
        }
    }
}

extension Notification.Name {
    /// Sent by the View menu command, which has no access to the window's state.
    static let toggleSidebarRequest = Notification.Name("KDEConnectNativeToggleSidebar")
}

/// The sidebar button and the + button in one glass capsule. While the
/// sidebar opens, the + grows out of the capsule; while it closes, the + goes
/// back into it.
struct SidebarControls: View {
    @Environment(KDEConnectStore.self) private var store
    @Binding var shown: Bool

    private var sidebarShown: Bool { shown }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    SidebarAnimator.shared.toggle($shown)
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 36, height: 30)
                        .contentShape(Rectangle())
                }
                .help(sidebarShown ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(sidebarShown ? "Hide Sidebar" : "Show Sidebar")

                if sidebarShown {
                    Button {
                        store.isPairingSheetShown = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .disabled(store.status != .connected)
                    .help("Pair a new device")
                    .accessibilityLabel("New Device")
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.4, anchor: .leading).combined(with: .opacity),
                        removal: .scale(scale: 0.4, anchor: .leading).combined(with: .opacity)))
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
