import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct IOSSyncPushTests {
    private let metadata: SyncMetadataStorage
    private let cacheDirectory: URL
    private let clock = ManualClock()
    private let transport: RecordingSyncTransport
    private let registrar = RecordingPushRegistrar()

    init() throws {
        transport = RecordingSyncTransport()
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.IOSSyncPush.\(UUID().uuidString)"))
        metadata = SyncMetadataStorage(userDefaults: defaults)
        _ = metadata.adoptReadableRecordTypes(IOSSyncCoordinator.readableRecordTypes)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sync-push-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeCoordinator(isEnabled: @escaping () -> Bool = { true }) -> IOSSyncCoordinator {
        let transport = transport
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: cacheDirectory, defaults: nil),
            makeTransport: { transport },
            isEnabled: isEnabled,
            notificationCenter: NotificationCenter(),
            networkMonitor: nil,
            activationClock: clock,
            pushRegistrar: registrar.registrar
        )
        coordinator.getCurrentState = { ([], [], []) }
        coordinator.onConnectionsChanged = { _ in true }
        coordinator.onGroupsChanged = { _ in true }
        coordinator.onTagsChanged = { _ in true }
        coordinator.getSavedQueries = { SavedQueryContents() }
        coordinator.onSavedQueriesChanged = { _ in true }
        return coordinator
    }

    @Test("A change notice downloads at once, inside the minute that holds activations back")
    func noticeDownloadsInsideTheInterval() async {
        let coordinator = makeCoordinator()
        await coordinator.syncOnSceneActivation()
        await coordinator.syncOnSceneActivation()
        #expect(coordinator.isHoldingActivations)
        #expect(await transport.pullCount == 1)

        await coordinator.sync(.remoteChange)

        #expect(await transport.pullCount == 2)
    }

    @Test("Notices before a run's download are answered by it")
    func noticesBeforeTheDownloadAddNoRun() async {
        let coordinator = makeCoordinator()
        let gate = AsyncGate()
        await transport.holdAccountChecks { await gate.wait() }
        let edit = Task { await coordinator.sync(.localChange) }
        await gate.arrived(1)

        // Each notice runs before the opener, since all of them share the main actor.
        let notices = (0..<5).map { _ in Task { await coordinator.sync(.remoteChange) } }
        let opener = Task { await gate.open() }
        for notice in notices {
            await notice.value
        }
        await opener.value
        await edit.value

        #expect(await transport.pullCount == 1)
    }

    @Test("Notices during a run's download add one more run, never one each")
    func noticesDuringTheDownloadAddOneRun() async {
        let coordinator = makeCoordinator()
        let gate = AsyncGate()
        await transport.holdPulls { await gate.wait() }
        let edit = Task { await coordinator.sync(.localChange) }
        await gate.arrived(1)

        await transport.holdPulls {}
        let notices = (0..<5).map { _ in Task { await coordinator.sync(.remoteChange) } }
        let opener = Task { await gate.open() }
        for notice in notices {
            await notice.value
        }
        await opener.value
        await edit.value

        #expect(await transport.pullCount == 2)
    }

    @Test("With sync off nothing registers, saves a subscription or downloads")
    func syncOffDoesNothing() async {
        let coordinator = makeCoordinator(isEnabled: { false })
        coordinator.registerForPushesIfEnabled()
        await coordinator.sync(.remoteChange)

        #expect(registrar.registrations == 0)
        #expect(await transport.subscriptionSaves == 0)
        #expect(await transport.pullCount == 0)
    }

    @Test("Turning sync on registers once, and turning it off unregisters")
    func registrationFollowsTheSwitch() async {
        let switchBox = SwitchBox()
        let coordinator = makeCoordinator(isEnabled: { switchBox.isOn })
        coordinator.registerForPushesIfEnabled()
        coordinator.registerForPushesIfEnabled()
        #expect(registrar.registrations == 1)

        switchBox.isOn = false
        coordinator.setEnabled(false)
        #expect(registrar.unregistrations == 1)

        switchBox.isOn = true
        coordinator.setEnabled(true)
        #expect(registrar.registrations == 2)
    }

    @Test("The subscription is saved once for the account")
    func subscriptionIsSavedOnce() async {
        let coordinator = makeCoordinator()
        await coordinator.sync(.userRequest)
        await coordinator.sync(.userRequest)

        #expect(await transport.subscriptionSaves == 1)
        #expect(metadata.subscribedAccountId == "recording-account")
    }

    @Test("A save that fails on the network leaves the run alone and is tried on the next run")
    func transientSaveFailureRetries() async {
        await transport.failSubscriptionSaves(with: CKError(.networkFailure))
        let coordinator = makeCoordinator()
        await coordinator.sync(.userRequest)
        #expect(coordinator.status == .idle)
        #expect(await transport.pullCount == 1)
        #expect(metadata.subscribedAccountId == nil)

        await transport.failSubscriptionSaves(with: nil)
        await coordinator.sync(.userRequest)
        #expect(await transport.subscriptionSaves == 2)
        #expect(metadata.subscribedAccountId == "recording-account")
    }
}

@MainActor
private final class SwitchBox {
    var isOn = true
}
