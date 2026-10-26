import KDEConnectKit
import Testing
@testable import KDEConnectNative

@MainActor
struct NotificationInputTests {
    @Test func unchangedListInputsCompareEqual() throws {
        let store = KDEConnectStore()
        store.showDemo()
        let device = try #require(store.selectedDevice)
        let first = NotificationCards(deviceId: device.id, isReachable: device.isReachable,
                                      notifications: device.notifications)
        let same = NotificationCards(deviceId: device.id, isReachable: device.isReachable,
                                     notifications: device.notifications)
        #expect(first == same)
        let offline = NotificationCards(deviceId: device.id, isReachable: false,
                                        notifications: device.notifications)
        #expect(first != offline)
        var changed = device.notifications
        changed[0].text = "Changed notification text"
        #expect(first != NotificationCards(deviceId: device.id, isReachable: device.isReachable, notifications: changed))
        #expect(first != NotificationCards(deviceId: "another-device", isReachable: device.isReachable,
                                           notifications: device.notifications))
    }
}
