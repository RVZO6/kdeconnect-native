import DBusKit
import Testing
@testable import KDEConnectKit

struct NotificationFilterTests {
    @Test func hidesNonDismissibleItems() {
        #expect(notificationForDisplay(id: "1", properties: ["dismissable": .bool(false)]) == nil)
    }

    @Test func keepsDismissibleAndUnknownItems() {
        #expect(notificationForDisplay(id: "2", properties: ["dismissable": .bool(true)])?.id == "2")
        #expect(notificationForDisplay(id: "3", properties: [:])?.id == "3")
        #expect(notificationForDisplay(id: "4", properties: ["dismissable": .string("invalid")])?.id == "4")
    }
}
