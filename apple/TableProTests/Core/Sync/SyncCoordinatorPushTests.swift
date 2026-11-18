import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct SyncCoordinatorPushTests {
    private let environment: SyncTestEnvironment
    private let clock = ManualClock()
    private let registrar = RecordingPushRegistrar()

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-push")
        setSyncEnabled(true)
    }

    private func setSyncEnabled(_ enabled: Bool) {
        var settings = SyncSettings.default
        settings.enabled = enabled
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
    }

    private func makeCoordinator(_ transport: any SyncTransport) -> SyncCoordinator {
        let base = environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID))
        return SyncCoordinator(
            services: base.services,
            recordCache: environment.recordCache,
            transport: transport,
            makeNetworkMonitor: { nil },
            columnLayouts: environment.columnLayouts,
            licenseGate: { nil },
            activationClock: clock,
            pushRegistrar: registrar.registrar
        )
    }

    // What CloudKit sends for the database subscription, in the form its own parser reads.
    private static func notice(subscriptionID: String = SyncPushSubscription.id) -> [AnyHashable: Any] {
        [
            "aps": ["content-available": 1],
            "ck": [
                "ce": 2,
                "cid": CloudKitSyncEngine.defaultContainerID,
                "nid": UUID().uuidString,
                "met": ["dbs": 1, "sid": subscriptionID]
            ] as [String: Any]
        ]
    }

    // The launch run of an app whose registration CloudKit answered.
    private func launch(_ coordinator: SyncCoordinator, registered: Bool, pulls: @escaping () async -> Int) async throws {
        coordinator.start()
        coordinator.pushRegistrationDidFinish(registered: registered)
        try await waitUntil { await pulls() == 1 }
        try await settle(coordinator)
    }

    // A run ends in a new hold, or in none when nothing was held.
    private func settle(_ coordinator: SyncCoordinator) async throws {
        try await waitUntil {
            coordinator.syncStatus != .syncing && (clock.pendingSleeperCount > 0 || !coordinator.isHoldingActivations)
        }
    }

    @Test("A change notice downloads at once, inside the hold that keeps activations back")
    func noticeDownloadsInsideTheHold() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: true) { await transport.pullCount }
        await coordinator.sync(.activation)
        #expect(coordinator.isHoldingActivations)
        #expect(await transport.pullCount == 1)

        coordinator.handleRemoteNotification(Self.notice())

        try await waitUntil { await transport.pullCount == 2 }
        #expect(clock.now.offset == .zero)
    }

    @Test("Notices before a run's download are answered by it")
    func noticesBeforeTheDownloadAddNoRun() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        let reads = ZoneReadCount()
        // The first zone read of a run comes before its download.
        await transport.whileZoneIsRead {
            guard reads.next() == 1 else { return }
            for _ in 0..<5 {
                await coordinator.sync(.remoteChange)
            }
        }

        await coordinator.sync(.userRequest)
        try await settle(coordinator)

        #expect(await transport.pullCount == 1)
    }

    @Test("Notices after a run's download began add one more run, never one each")
    func noticesDuringTheDownloadAddOneRun() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        let reads = ZoneReadCount()
        // The second zone read of a run comes after its download.
        await transport.whileZoneIsRead {
            guard reads.next() == 2 else { return }
            for _ in 0..<5 {
                await coordinator.sync(.remoteChange)
            }
        }

        await coordinator.sync(.userRequest)
        try await waitUntil { await transport.pullCount == 2 }
        try await settle(coordinator)

        #expect(await transport.pullCount == 2)
    }

    @Test("With sync off nothing registers, no subscription is saved, and notices are ignored")
    func syncOffDoesNothing() async throws {
        setSyncEnabled(false)
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        coordinator.start()
        coordinator.pushRegistrationDidFinish(registered: true)
        coordinator.handleRemoteNotification(Self.notice())
        await coordinator.sync(.remoteChange)

        #expect(registrar.registrations == 0)
        #expect(registrar.unregistrations == 0)
        #expect(await transport.subscriptionSaveCount == 0)
        #expect(await transport.pullCount == 0)
        #expect(!coordinator.isPushLive)
    }

    @Test("Turning sync on registers, and turning it off unregisters and ends push")
    func registrationFollowsTheSwitch() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: true) { await transport.pullCount }
        #expect(registrar.registrations == 1)
        #expect(coordinator.isPushLive)

        setSyncEnabled(false)
        coordinator.disableSync()
        #expect(registrar.unregistrations == 1)
        #expect(!coordinator.isPushLive)

        setSyncEnabled(true)
        coordinator.enableSync()
        #expect(registrar.registrations == 2)
        #expect(!coordinator.isPushLive)
    }

    @Test("The subscription is saved once per account, and again for a new account")
    func subscriptionIsSavedOncePerAccount() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        await coordinator.sync(.launch)
        await coordinator.sync(.userRequest)
        #expect(await transport.subscriptionSaveCount == 1)
        #expect(environment.metadata.subscribedAccountId == ScriptedSyncTransport.accountId)

        await transport.setAccountId("another")
        await coordinator.sync(.accountChange)
        #expect(await transport.subscriptionSaveCount == 2)
        #expect(environment.metadata.subscribedAccountId == "another")
    }

    @Test("A save that fails leaves the run alone, and activations keep the one minute hold")
    func failedSaveKeepsTheMinute() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        await transport.failSubscriptionSaves(with: CKError(.networkFailure))
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: true) { await transport.pullCount }

        #expect(coordinator.syncStatus == .idle)
        #expect(!coordinator.isPushLive)
        #expect(coordinator.activationHoldInterval == SyncCoordinator.activationInterval)

        await transport.failSubscriptionSaves(with: nil)
        await coordinator.sync(.userRequest)
        #expect(await transport.subscriptionSaveCount == 2)
        #expect(coordinator.isPushLive)
    }

    @Test("An activation every 30 s for an hour downloads 60 times without push and 4 times with it",
          arguments: [(false, 60), (true, 4)])
    func activationsForAnHour(registered: Bool, downloads: Int) async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: registered) { await transport.pullCount }
        #expect(coordinator.isPushLive == registered)

        for _ in 1..<120 {
            clock.advance(by: .seconds(30))
            try await settle(coordinator)
            await coordinator.sync(.activation)
            try await settle(coordinator)
        }

        #expect(await transport.pullCount == downloads)
    }

    // A transport whose deltas carry what `remote` holds, the way another Mac's saves arrive.
    private func makeRemoteServer(_ remote: RemoteChanges) throws -> ScriptedSyncTransport {
        environment.metadata.saveToken(try Self.makeChangeToken())
        let token = try Self.makeChangeToken()
        return ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID, echoing: { _, _ in
            PullResult(changedRecords: remote.take(), deletedRecordIDs: [], newToken: token)
        })
    }

    private func endHold(_ coordinator: SyncCoordinator) async throws {
        await clock.waitUntilSleeping()
        clock.advance(by: coordinator.activationHoldInterval)
        try await waitUntil { !coordinator.isHoldingActivations }
    }

    private static var remoteTag: CKRecord {
        SyncRecordMapper.toCKRecord(ConnectionTag(name: "from another Mac"), in: SyncTestEnvironment.zoneID)
    }

    @Test("An activation that brings a change no notice announced goes back to the minute, and the next notice ends that")
    func missedNoticeFallsBackToTheMinute() async throws {
        let remote = RemoteChanges()
        let transport = try makeRemoteServer(remote)
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: true) { await transport.pullCount }
        #expect(coordinator.activationHoldInterval == SyncCoordinator.pushFallbackInterval)

        remote.put(Self.remoteTag)
        try await endHold(coordinator)
        await coordinator.sync(.activation)
        try await settle(coordinator)

        #expect(await transport.pullCount == 2)
        #expect(!coordinator.isPushLive)
        #expect(coordinator.activationHoldInterval == SyncCoordinator.activationInterval)

        // Counted synchronously, so a payload the filter let through shows before any run starts.
        let noticesBefore = coordinator.pushChannel.noticesReceived
        coordinator.handleRemoteNotification(Self.notice(subscriptionID: "other"))
        coordinator.handleRemoteNotification(["aps": ["alert": "Hello"]])
        #expect(coordinator.pushChannel.noticesReceived == noticesBefore)

        coordinator.handleRemoteNotification(Self.notice())
        try await waitUntil { await transport.pullCount == 3 }
        try await settle(coordinator)
        #expect(coordinator.isPushLive)
        #expect(await transport.subscriptionSaveCount == 2)
    }

    @Test("A notice that lands during an activation's run keeps the changes it brings announced")
    func noticeDuringTheActivationKeepsPushLive() async throws {
        let remote = RemoteChanges()
        let transport = try makeRemoteServer(remote)
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: true) { await transport.pullCount }

        remote.put(Self.remoteTag)
        try await endHold(coordinator)
        let reads = ZoneReadCount()
        await transport.whileZoneIsRead {
            guard reads.next() == 1 else { return }
            coordinator.handleRemoteNotification(Self.notice())
        }
        await coordinator.sync(.activation)
        try await settle(coordinator)

        #expect(coordinator.isPushLive)
        #expect(coordinator.activationHoldInterval == SyncCoordinator.pushFallbackInterval)
    }

    @Test("A notice whose download failed still announces the change the next activation brings")
    func noticeBeforeAFailedDownloadKeepsPushLive() async throws {
        let remote = RemoteChanges()
        let transport = try makeRemoteServer(remote)
        let coordinator = makeCoordinator(transport)
        try await launch(coordinator, registered: true) { await transport.pullCount }

        remote.put(Self.remoteTag)
        try await endHold(coordinator)
        await transport.failPulls(with: CKError(.networkFailure))
        let reads = ZoneReadCount()
        await transport.whileZoneIsRead {
            guard reads.next() == 1 else { return }
            coordinator.handleRemoteNotification(Self.notice())
        }
        await coordinator.sync(.userRequest)
        #expect(coordinator.syncStatus == .error(.offline))

        await transport.failPulls(with: nil)
        await coordinator.sync(.activation)
        try await settle(coordinator)

        #expect(coordinator.isPushLive)
        #expect(coordinator.activationHoldInterval == SyncCoordinator.pushFallbackInterval)
    }

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: PushTestsChangeTokenArchive.self)
        archiver.encode(PushTestsChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

@MainActor
private final class ZoneReadCount {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

// What another device saved since the last fetch, handed out once.
private final class RemoteChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord] = []

    func put(_ record: CKRecord) {
        lock.withLock { records.append(record) }
    }

    func take() -> [CKRecord] {
        lock.withLock {
            defer { records = [] }
            return records
        }
    }
}

@objc(SyncCoordinatorPushTestsChangeTokenArchive)
private final class PushTestsChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
