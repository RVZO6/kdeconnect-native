import AppKit
import Testing
@testable import KDEConnectNative

@MainActor
struct NotificationTextTests {
    @Test func labelsRemainSelectableAndReadOnly() {
        let label = NotificationText.makeLabel()
        NotificationText(text: "Notification title", isTitle: true).configure(label)
        #expect(label.isSelectable)
        #expect(!label.isEditable)
        #expect(!label.isBordered)
        #expect(!label.drawsBackground)
        #expect(label.stringValue == "Notification title")
        #expect(label.textColor == .labelColor)
    }

    @Test func multilineTextWrapsAndBodyStopsAtFourLines() {
        let label = NotificationText.makeLabel()
        let text = String(repeating: "Notification text with a long subject. ", count: 20)
        NotificationText(text: text).configure(label)
        let wide = NotificationText.size(of: label, width: 450)
        let narrow = NotificationText.size(of: label, width: 220)
        #expect(narrow.height > wide.height)
        NotificationText(text: text, lineLimit: 4).configure(label)
        let limited = NotificationText.size(of: label, width: 220)
        #expect(limited.height < narrow.height)
        #expect(label.maximumNumberOfLines == 4)
        #expect(label.cell?.truncatesLastVisibleLine == true)
        #expect(label.textColor == .secondaryLabelColor)
    }

    @Test func changedNotificationUpdatesExistingLabel() {
        let label = NotificationText.makeLabel()
        NotificationText(text: "Old").configure(label)
        NotificationText(text: "New").configure(label)
        #expect(label.stringValue == "New")
    }
}
