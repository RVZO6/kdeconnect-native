import AppKit
import SwiftUI

/// Use an AppKit label for selectable notification text. SwiftUI's selectable
/// Text can draw with an inverted vertical axis inside animated, clipped cards.
struct NotificationText: NSViewRepresentable {
    let text: String
    var isTitle = false
    var lineLimit = 0

    func makeNSView(context: Context) -> NSTextField {
        Self.makeLabel()
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        configure(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        Self.size(of: nsView, width: proposal.width)
    }

    static func makeLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = true
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func configure(_ label: NSTextField) {
        // Do not reset the user's selection on unrelated view updates.
        if label.stringValue != text { label.stringValue = text }
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isTitle ? .medium : .regular)
        label.textColor = isTitle ? .labelColor : .secondaryLabelColor
        label.maximumNumberOfLines = lineLimit
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = lineLimit > 0
    }

    static func size(of label: NSTextField, width: CGFloat?) -> CGSize {
        let width = max(0, width ?? label.intrinsicContentSize.width)
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = label.cell?.cellSize(forBounds: bounds).height ?? 0
        return CGSize(width: width, height: ceil(height))
    }
}
