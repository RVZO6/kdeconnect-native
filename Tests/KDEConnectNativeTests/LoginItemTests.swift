import ServiceManagement
import Testing
@testable import KDEConnectNative

@MainActor
struct LoginItemTests {
    @Test func pendingApprovalIsStillRegistered() {
        #expect(LoginItem.isRegistered(status: .enabled))
        #expect(LoginItem.isRegistered(status: .requiresApproval))
        #expect(!LoginItem.isRegistered(status: .notRegistered))
        #expect(!LoginItem.isRegistered(status: .notFound))
    }
}
