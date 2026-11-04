import Foundation
@testable import TablePro
import TableProTestSupport
import Testing
import UserNotifications

@MainActor
final class RecordingNotificationPresenter: UserNotificationPresenting {
    var status: UNAuthorizationStatus = .authorized
    private(set) var statusReads = 0
    private(set) var permissionRequests = 0
    private(set) var posted: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusReads += 1
        return status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        permissionRequests += 1
        status = .authorized
        return true
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {}

    func post(_ request: UNNotificationRequest) async throws { posted.append(request) }

    func removeDelivered(identifiers: [String]) { removedIdentifiers.append(contentsOf: identifiers) }
}

@MainActor
struct PluginNotificationServiceTests {
    private let presenter = RecordingNotificationPresenter()
    private let tracker = PluginInstallTracker(clock: ManualClock())

    private func makeService(isEnabled: Bool = true) -> PluginNotificationService {
        let service = PluginNotificationService(
            presenter: presenter,
            authorization: NotificationAuthorization(presenter: presenter),
            categories: NotificationCategoryRegistry(presenter: presenter),
            tracker: tracker,
            settings: { NotificationSettings(isEnabled: isEnabled) }
        )
        service.observeInstalls()
        return service
    }

    private func install(
        _ pluginId: String = "com.example.driver",
        trigger: PluginInstallTracker.Trigger,
        failing error: PluginError? = nil
    ) async {
        _ = try? await tracker.track(pluginId: pluginId, displayName: "Driver", trigger: trigger, retry: nil) { _ in
            if let error { throw error }
        }
    }

    private func rejected(_ bundleId: String) -> RejectedPlugin {
        RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/\(bundleId).tableplugin"),
            bundleId: bundleId,
            registryId: nil,
            name: bundleId,
            reason: "Built for an older PluginKit",
            isOutdated: true,
            providedDatabaseTypeIds: []
        )
    }

    @Test("A failed background update posts once, however often the retries fail")
    func updateFailurePostsOnce() async throws {
        let service = makeService()
        await install(trigger: .update, failing: PluginError.checksumMismatch)

        try await waitUntil { presenter.posted.count == 1 }
        let request = try #require(presenter.posted.first)
        #expect(request.identifier.hasSuffix("com.example.driver"))
        #expect(request.content.body == PluginError.checksumMismatch.localizedDescription)
        #expect(request.content.userInfo[PluginNotificationService.pluginIdKey] as? String == "com.example.driver")

        await install(trigger: .update, failing: PluginError.checksumMismatch)
        #expect(presenter.posted.count == 1)
        withExtendedLifetime(service) {}
    }

    @Test("A manual retry and a later successful install clear the delivered failure")
    func manualRetryClearsTheFailure() async throws {
        let service = makeService()
        await install(trigger: .update, failing: PluginError.checksumMismatch)
        try await waitUntil { presenter.posted.count == 1 }
        let identifier = try #require(presenter.posted.first?.identifier)

        let gate = AsyncGate()
        let retry = Task {
            try await tracker.track(pluginId: "com.example.driver", displayName: "Driver", trigger: .user, retry: nil) { _ in
                await gate.wait()
            }
        }
        await gate.arrived(1)
        #expect(presenter.removedIdentifiers == [identifier])
        await gate.open()
        try await retry.value

        await install(trigger: .update, failing: PluginError.checksumMismatch)
        try await waitUntil { presenter.posted.count == 2 }
        await install(trigger: .update)
        #expect(presenter.removedIdentifiers == [identifier, identifier])
        withExtendedLifetime(service) {}
    }

    @Test("A failed user install or rejected repair posts nothing")
    func onlyBackgroundUpdatesPost() async throws {
        let service = makeService()
        await install(trigger: .user, failing: PluginError.checksumMismatch)
        await install("com.example.other", trigger: .repair, failing: PluginError.checksumMismatch)

        #expect(presenter.posted.isEmpty)
        #expect(presenter.statusReads == 0)
        withExtendedLifetime(service) {}
    }

    @Test("With notifications switched off, a failure posts nothing and never asks for permission")
    func switchOffSkipsAndAsksNothing() async throws {
        presenter.status = .notDetermined
        let service = makeService(isEnabled: false)
        await install(trigger: .update, failing: PluginError.checksumMismatch)
        await service.notifyRejected([rejected("com.example.rejected")])

        #expect(presenter.posted.isEmpty)
        #expect(presenter.permissionRequests == 0)
        #expect(presenter.statusReads == 0)
    }

    @Test("A rejected plugin posts once across repeated reports, and leaves when it is no longer rejected")
    func rejectedPluginPostsOnce() async throws {
        let service = makeService()
        let plugin = rejected("com.example.rejected")

        await service.notifyRejected([plugin])
        await service.notifyRejected([plugin])
        #expect(presenter.posted.map { $0.identifier } == ["com.TablePro.plugin.failed.com.example.rejected"])

        await service.notifyRejected([])
        #expect(presenter.removedIdentifiers == ["com.TablePro.plugin.failed.com.example.rejected"])

        await service.notifyRejected([plugin])
        #expect(presenter.posted.count == 2)
    }

    @Test("Asking for permission happens once, in context, the first time a notification would post")
    func permissionAskedInContext() async throws {
        presenter.status = .notDetermined
        let service = makeService()
        await service.notifyRejected([rejected("com.example.rejected")])

        #expect(presenter.permissionRequests == 1)
        #expect(presenter.posted.count == 1)
    }
}
