import AppKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing
import UserNotifications

@MainActor
private final class StubPermissionPresenter: UserNotificationPresenting {
    var status: UNAuthorizationStatus = .authorized
    private(set) var requests = 0

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        requests += 1
        return false
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {}

    func post(_ request: UNNotificationRequest) async throws {}

    func removeDelivered(identifiers: [String]) {}
}

@MainActor
struct NotificationPermissionMonitorTests {
    @Test("A permission turned off in System Settings shows once TablePro is active again")
    func readsAgainOnActivation() async throws {
        let presenter = StubPermissionPresenter()
        let center = NotificationCenter()
        let monitor = NotificationPermissionMonitor(
            authorization: NotificationAuthorization(presenter: presenter),
            center: center
        )
        await monitor.refresh()
        #expect(monitor.status == .authorized)

        presenter.status = .denied
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        try await waitUntil { monitor.status == .denied }
    }

    @Test("Reading the permission never asks for it")
    func neverRequests() async {
        let presenter = StubPermissionPresenter()
        presenter.status = .notDetermined
        let monitor = NotificationPermissionMonitor(
            authorization: NotificationAuthorization(presenter: presenter),
            center: NotificationCenter()
        )
        await monitor.refresh()
        #expect(monitor.status == .notDetermined)
        #expect(presenter.requests == 0)
    }
}
