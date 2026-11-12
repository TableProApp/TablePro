import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct SyncCoordinatorActivationTests {
    private let environment: SyncTestEnvironment
    private let clock = ManualClock()

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-activation")
        var settings = SyncSettings.default
        settings.enabled = true
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
    }

    private func makeCoordinator(_ transport: ScriptedSyncTransport) -> SyncCoordinator {
        environment.makeCoordinator(transport: transport, activationClock: clock)
    }

    @Test("An activation while the launch run has yet to download adds no second run")
    func activationDuringLaunchRunIsDropped() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        let activated = ActivationLatch()
        await transport.whileZoneIsRead {
            guard activated.claim() else { return }
            await coordinator.sync(.activation)
        }

        await coordinator.sync(.launch)
        #expect(activated.isClaimed)

        // Held instead of dropped, it would run once the interval ends.
        await clock.waitUntilSleeping()
        clock.advance(by: SyncCoordinator.activationInterval)
        try await waitUntil { !coordinator.isHoldingActivations }
        try await waitUntil { coordinator.syncStatus != .syncing }
        #expect(await transport.pullCount == 1)
    }

    @Test("Activations inside the interval wait for its end and then download once")
    func activationsInsideTheIntervalRunOnceAtItsEnd() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        await coordinator.sync(.launch)
        #expect(await transport.pullCount == 1)

        await coordinator.sync(.activation)
        await coordinator.sync(.activation)
        #expect(await transport.pullCount == 1)

        await clock.waitUntilSleeping()
        clock.advance(by: SyncCoordinator.activationInterval)
        try await waitUntil { await transport.pullCount == 2 }
        try await waitUntil { coordinator.syncStatus != .syncing }
        #expect(await transport.pullCount == 2)
    }

    @Test("An activation after the interval downloads at once")
    func activationAfterTheIntervalRuns() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        await coordinator.sync(.launch)

        await clock.waitUntilSleeping()
        clock.advance(by: SyncCoordinator.activationInterval)
        try await waitUntil { !coordinator.isHoldingActivations }
        await coordinator.sync(.activation)
        #expect(await transport.pullCount == 2)
    }

    @Test("An edit queued behind an activation during a download is not held with it")
    func queuedEditIsNotHeldBehindAnActivation() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        await coordinator.sync(.launch)
        await clock.waitUntilSleeping()
        clock.advance(by: SyncCoordinator.activationInterval)
        try await waitUntil { !coordinator.isHoldingActivations }

        // The second zone read of a run comes after its download, where an activation is queued, not dropped.
        let reads = ZoneReadCounter()
        await transport.whileZoneIsRead {
            guard reads.next() == 2 else { return }
            await coordinator.sync(.activation)
            await coordinator.sync(.localChange)
        }
        await coordinator.sync(.userRequest)
        try await waitUntil { await transport.pullCount == 3 }
    }

    @Test("Turning sync off ends the activation hold")
    func syncOffEndsTheHold() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        await coordinator.sync(.launch)
        #expect(coordinator.isHoldingActivations)

        var settings = SyncSettings.default
        settings.enabled = false
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        coordinator.start()
        #expect(!coordinator.isHoldingActivations)
    }

    @Test("A failed download leaves the next activation free to run")
    func failedDownloadDoesNotHoldActivation() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        await transport.failPulls(with: CKError(.networkFailure))
        let coordinator = makeCoordinator(transport)
        await coordinator.sync(.launch)
        #expect(await transport.pullCount == 1)

        await transport.failPulls(with: nil)
        await coordinator.sync(.activation)
        #expect(await transport.pullCount == 2)
    }
}

@MainActor
private final class ActivationLatch {
    private(set) var isClaimed = false

    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

@MainActor
private final class ZoneReadCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
