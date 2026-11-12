import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct IOSSyncActivationTests {
    private let metadata: SyncMetadataStorage
    private let cacheDirectory: URL
    private let clock = ManualClock()
    private let transport: RecordingSyncTransport

    init() throws {
        transport = RecordingSyncTransport()
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.IOSSyncActivation.\(UUID().uuidString)"))
        metadata = SyncMetadataStorage(userDefaults: defaults)
        _ = metadata.adoptReadableRecordTypes(IOSSyncCoordinator.readableRecordTypes)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sync-activation-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeCoordinator() -> IOSSyncCoordinator {
        let transport = transport
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: cacheDirectory, defaults: nil),
            makeTransport: { transport },
            isEnabled: { true },
            notificationCenter: NotificationCenter(),
            networkMonitor: nil,
            activationClock: clock
        )
        coordinator.getCurrentState = { ([], [], []) }
        coordinator.onConnectionsChanged = { _ in true }
        coordinator.onGroupsChanged = { _ in true }
        coordinator.onTagsChanged = { _ in true }
        coordinator.getSavedQueries = { SavedQueryContents() }
        coordinator.onSavedQueriesChanged = { _ in true }
        return coordinator
    }

    private func endInterval() async {
        await clock.waitUntilSleeping()
        clock.advance(by: IOSSyncCoordinator.activationInterval)
    }

    @Test("Ten activations within a minute of a download start one run, and the held one runs once when the minute ends")
    func activationsInsideTheIntervalRunOnce() async throws {
        let coordinator = makeCoordinator()

        for _ in 0..<10 {
            await coordinator.syncOnSceneActivation()
        }
        #expect(await transport.pullCount == 1)
        #expect(coordinator.isHoldingActivations)

        await endInterval()
        try await waitUntil { await transport.pullCount == 2 }

        // Waits for any run still going, so a second held run would show as a fourth pull.
        await coordinator.sync(.userRequest)
        #expect(await transport.pullCount == 3)
    }

    @Test("With no activation held, the end of the interval starts no run")
    func quietIntervalStartsNothing() async throws {
        let coordinator = makeCoordinator()
        await coordinator.syncOnSceneActivation()

        await endInterval()
        try await waitUntil { !coordinator.isHoldingActivations }
        await coordinator.sync(.userRequest)

        #expect(await transport.pullCount == 2)
    }

    @Test("An edit and the person's request run at once inside the interval")
    func editsAndRequestsAreNeverHeld() async {
        let coordinator = makeCoordinator()
        await coordinator.syncOnSceneActivation()

        await coordinator.sync(.localChange)
        #expect(await transport.pullCount == 2)
        await coordinator.sync(.userRequest)
        #expect(await transport.pullCount == 3)
    }

    @Test("A background refresh runs inside the interval")
    func backgroundRefreshIsNeverHeld() async {
        let coordinator = makeCoordinator()
        await coordinator.syncOnSceneActivation()

        // What the BGAppRefresh task calls.
        await coordinator.sync(.activation)

        #expect(await transport.pullCount == 2)
    }

    @Test("An activation while a run has not started its download is answered by that run")
    func activationBeforeTheDownloadIsDropped() async throws {
        let coordinator = makeCoordinator()
        let gate = AsyncGate()
        await transport.holdAccountChecks { await gate.wait() }
        let edit = Task { await coordinator.sync(.localChange) }
        await gate.arrived(1)

        // Runs only once the activation below has returned or waits on the run, since both share the main actor.
        let opener = Task { await gate.open() }
        await coordinator.syncOnSceneActivation()
        await opener.value
        await edit.value
        #expect(await transport.pullCount == 1)

        await endInterval()
        try await waitUntil { !coordinator.isHoldingActivations }
        await coordinator.sync(.userRequest)
        #expect(await transport.pullCount == 2)
    }

    @Test("An activation during a download runs once the interval ends, since the download began before it")
    func activationDuringTheDownloadRunsAfterTheInterval() async throws {
        let coordinator = makeCoordinator()
        let gate = AsyncGate()
        await transport.holdPulls { await gate.wait() }
        let edit = Task { await coordinator.sync(.localChange) }
        await gate.arrived(1)

        // Runs only once the activation below waits on the run, since both share the main actor.
        let opener = Task { await gate.open() }
        await coordinator.syncOnSceneActivation()
        await opener.value
        await edit.value
        #expect(await transport.pullCount == 1)
        #expect(coordinator.isHoldingActivations)

        await endInterval()
        try await waitUntil { await transport.pullCount == 2 }
    }

    @Test("A download that fails starts no interval, so the next activation runs")
    func failedDownloadHoldsNothing() async {
        let coordinator = makeCoordinator()
        coordinator.onConnectionsChanged = { _ in false }
        await coordinator.syncOnSceneActivation()
        #expect(!coordinator.isHoldingActivations)

        coordinator.onConnectionsChanged = { _ in true }
        await coordinator.syncOnSceneActivation()

        #expect(await transport.pullCount == 2)
    }

    @Test("Turning sync off drops a held activation")
    func turningSyncOffDropsTheHold() async throws {
        let coordinator = makeCoordinator()
        await coordinator.syncOnSceneActivation()
        await coordinator.syncOnSceneActivation()
        await clock.waitUntilSleeping()

        coordinator.setEnabled(false)

        #expect(!coordinator.isHoldingActivations)
        #expect(clock.pendingSleeperCount == 0)
    }
}
