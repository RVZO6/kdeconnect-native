import AppKit
import SwiftUI

/// Keeps the sidebar button next to the window buttons.
///
/// SwiftUI puts a flexible space in front of the sidebar button. With the
/// sidebar open, that pushes the button to the right edge of the sidebar;
/// with it closed, the button jumps back to the window buttons. Without the
/// space, the button stays in one place in both states.
struct SidebarToggleAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            // SwiftUI creates the toolbar after this view joins the window,
            // and it can rebuild the items later, so watch every toolbar and
            // fix this window's one after each change.
            observer = NotificationCenter.default.addObserver(
                forName: NSToolbar.willAddItemNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.fix() }
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.fix() }
            }
        }

        private func fix() {
            if let toolbar = window?.toolbar { Self.removeLeadingSpace(from: toolbar) }
        }

        static func removeLeadingSpace(from toolbar: NSToolbar) {
            let ids = toolbar.items.map(\.itemIdentifier)
            guard let toggle = ids.firstIndex(where: { $0.rawValue.hasSuffix("toggleSidebar") || $0 == .toggleSidebar })
            else { return }
            for index in (0..<toggle).reversed() where ids[index] == .flexibleSpace || ids[index] == .space {
                toolbar.removeItem(at: index)
            }
        }
    }
}
