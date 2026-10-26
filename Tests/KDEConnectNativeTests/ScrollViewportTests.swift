import AppKit
import Testing
@testable import KDEConnectNative

@MainActor
struct ScrollViewportTests {
    @Test func visibleRectExcludesInsetsForBothCoordinateSystems() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 400)
        let insets = NSEdgeInsets(top: 40, left: 25, bottom: 10, right: 15)
        #expect(ScrollViewport.visibleRect(bounds: bounds, insets: insets, flipped: true)
                == CGRect(x: 35, y: 60, width: 260, height: 350))
        #expect(ScrollViewport.visibleRect(bounds: bounds, insets: insets, flipped: false)
                == CGRect(x: 35, y: 30, width: 260, height: 350))
    }

    @Test func largeInsetsProduceAnEmptyViewport() {
        let rect = ScrollViewport.visibleRect(bounds: CGRect(x: 0, y: 0, width: 40, height: 20),
                                              insets: NSEdgeInsets(top: 15, left: 25, bottom: 10, right: 20),
                                              flipped: true)
        #expect(rect.isEmpty)
        #expect(rect.width == 0)
        #expect(rect.height == 0)
    }

    @Test func rangeIncludesHeaderInsetAndShortDocuments() {
        let insets = NSEdgeInsets(top: 207.5, left: 144, bottom: 0, right: 0)
        let range = ScrollViewport.verticalRange(documentFrame: CGRect(x: 0, y: 0, width: 900, height: 604),
                                                 viewportHeight: 640, insets: insets, flipped: true)
        #expect(range.lowerBound == -207.5)
        #expect(range.upperBound == -36)
        let tiny = ScrollViewport.verticalRange(documentFrame: CGRect(x: 0, y: 0, width: 900, height: 100),
                                                viewportHeight: 640, insets: insets, flipped: true)
        #expect(tiny.lowerBound == tiny.upperBound)
    }

    @Test func unflippedRangeUsesBottomThenTopInset() {
        let range = ScrollViewport.verticalRange(documentFrame: CGRect(x: 0, y: 10, width: 100, height: 600),
                                                 viewportHeight: 300,
                                                 insets: NSEdgeInsets(top: 40, left: 0, bottom: 10, right: 0),
                                                 flipped: false)
        #expect(range == 0...350)
    }
}
