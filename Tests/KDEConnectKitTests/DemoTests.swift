import Testing
@testable import KDEConnectKit

@MainActor
struct DemoTests {
    @Test func defaultDemoIsUnchanged() {
        let store = KDEConnectStore()
        store.showDemo()
        #expect(store.selectedDevice?.notifications.count == 9)
        #expect(store.selectedDevice?.notifications.first?.appName == "Messages")
    }

    @Test func largeDemoHasStableGroupsAndDescendingIDs() {
        let store = KDEConnectStore()
        store.showDemo(notificationCount: 300, appCount: 20)
        let notifications = store.selectedDevice?.notifications ?? []
        #expect(notifications.count == 300)
        #expect(Set(notifications.map(\.id)).count == 300)
        #expect(Set(notifications.map(\.appName)).count == 20)
        #expect(notifications.compactMap { Int($0.id) } == Array((1...300).reversed()))
    }

    @Test func emptyDemoAndZeroAppsAreSafe() {
        let store = KDEConnectStore()
        store.showDemo(notificationCount: 0)
        #expect(store.selectedDevice?.notifications.isEmpty == true)
        store.showDemo(notificationCount: 3, appCount: 0)
        #expect(Set(store.selectedDevice?.notifications.map(\.appName) ?? []).count == 1)
    }
}
