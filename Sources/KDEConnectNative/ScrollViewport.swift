import AppKit

/// Geometry shared by swipe hit testing and the UI benchmark. AppKit's
/// clip-view bounds include content underneath safe-area bars, so they are
/// not the same as the interactive viewport.
@MainActor
enum ScrollViewport {
    static func visibleRect(bounds: CGRect, insets: NSEdgeInsets, flipped: Bool) -> CGRect {
        CGRect(x: bounds.minX + insets.left,
               y: bounds.minY + (flipped ? insets.top : insets.bottom),
               width: max(0, bounds.width - insets.left - insets.right),
               height: max(0, bounds.height - insets.top - insets.bottom))
    }

    static func visibleRect(of scroll: NSScrollView) -> CGRect {
        visibleRect(bounds: scroll.contentView.bounds, insets: scroll.contentInsets,
                    flipped: scroll.contentView.isFlipped)
    }

    static func verticalRange(documentFrame: CGRect, viewportHeight: CGFloat,
                              insets: NSEdgeInsets, flipped: Bool) -> ClosedRange<CGFloat> {
        let leading = flipped ? insets.top : insets.bottom
        let trailing = flipped ? insets.bottom : insets.top
        let lower = documentFrame.minY - leading
        let upper = max(lower, documentFrame.maxY - viewportHeight + trailing)
        return lower...upper
    }

    static func verticalRange(of scroll: NSScrollView) -> ClosedRange<CGFloat> {
        guard let document = scroll.documentView else {
            let y = scroll.contentView.bounds.minY
            return y...y
        }
        return verticalRange(documentFrame: document.frame, viewportHeight: scroll.contentView.bounds.height,
                             insets: scroll.contentInsets, flipped: scroll.contentView.isFlipped)
    }

    static func scrollToTop(_ scroll: NSScrollView) {
        let range = verticalRange(of: scroll)
        let y = scroll.contentView.isFlipped ? range.lowerBound : range.upperBound
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
