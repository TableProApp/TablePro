import CloudKit
import Combine
import Foundation
import os
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import TableProTestSupport
import Testing

// The core engine as the coordinator drives it: what it was asked, and a script for what a pass does.
final class FakeSyncEngine: SyncEngine, @unchecked Sendable {
    struct State {
        var info = SyncStatusInfo(
            provider: nil,
            phase: .idle,
            lastPassMs: nil,
            problem: nil,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
        var passes: [PassReasonTag] = []
        var providers: [SyncProviderTag] = []
        var categories: [SyncCategoriesArg] = []
        var hostChanges: [SyncHostChange] = []
        var hostChangeAttempts = 0
        var refuseHostChanges = false
        var refuseCategories = false
        // As the core's service opened Off answers every provider call.
        var refusesProviderCalls = false
        var icloudAccount: String?
        var serviceAccount: String?
        var uploadsAgain = 0
        // How many host changes the engine held at each flush.
        var flushes: [Int] = []
        var flush: (@Sendable () async -> Void)?
        var recording: (@Sendable () async -> Void)?
        var pass: (@Sendable (PassReasonTag) async -> Void)?
    }

    let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    func status() -> SyncStatusInfo {
        read { $0.info }
    }

    func syncNow(why: PassReasonTag) async throws {
        let pass = try state.withLockUnchecked { state in
            guard !state.refusesProviderCalls else { throw Self.notAllowed }
            state.passes.append(why)
            return state.pass
        }
        await pass?(why)
    }

    func chooseProvider(provider: SyncProviderTag) async throws {
        try state.withLockUnchecked { state in
            guard !state.refusesProviderCalls else { throw Self.notAllowed }
            state.providers.append(provider)
            state.info.provider = provider
        }
    }

    private static var notAllowed: AccountError {
        .network("sync personal data while sync is off")
    }

    func setCategories(categories: SyncCategoriesArg) async throws {
        let refused = state.withLockUnchecked { state in
            guard !state.refuseCategories else { return true }
            state.categories.append(categories)
            return false
        }
        if refused {
            throw AccountError.network("the engine did not take the categories")
        }
    }

    func recordHostChanges(kind: String, written: [String], deleted: [String]) async throws {
        await read { $0.recording }?()
        let refused = state.withLockUnchecked { state in
            state.hostChangeAttempts += 1
            guard !state.refuseHostChanges else { return true }
            state.hostChanges.append(SyncHostChange(kind: kind, written: written, deleted: deleted))
            return false
        }
        if refused {
            throw AccountError.network("the engine is not ready")
        }
    }

    func uploadAgain() async throws {
        update { $0.uploadsAgain += 1 }
    }

    func icloudAccount() -> String? {
        read { $0.icloudAccount }
    }

    func serviceAccount() -> String? {
        read { $0.serviceAccount }
    }

    func flushLegacyMarks() async throws {
        let flush = state.withLockUnchecked { state in
            state.flushes.append(state.hostChanges.count)
            return state.flush
        }
        await flush?()
    }
}

@MainActor
private final class Fixture {
    let database = FakeCloudKitDatabase()
    let transport: CloudKitCoreTransport
    let engine = FakeSyncEngine()
    let clock = ManualClock()
    let policyChanges = PassthroughSubject<DisableReason?, Never>()
    let notifications = NotificationCenter()
    let journal = SyncHostJournal()
    var opening: AsyncGate?
    // The provider each open was asked for and each that opened, and the engine an open for Off gives when one is set.
    private(set) var openAttempts: [SyncProviderTag] = []
    private(set) var opened: [SyncProviderTag] = []
    var offEngine: FakeSyncEngine?
    // The engine iCloud's opens after the first give, when one is set.
    var reopened: FakeSyncEngine?
    let signInChanges = PassthroughSubject<Void, Never>()
    var enabled = true
    var settings = SyncSettings.default
    var keptAccounts: [String?] = []
    var keptServiceAccounts: [String?] = []
    var policy: DisableReason?
    var opens = true
    var listener: (any SyncListener)?
    private(set) var coreWriteReads = 0
    private let suite: EphemeralDefaults
    let metadata: SyncMetadataStorage
    private(set) var coordinator: SyncProviderCoordinator!

    init() throws {
        suite = try EphemeralDefaults("SyncProviderCoordinatorTests")
        metadata = SyncMetadataStorage(userDefaults: suite.defaults)
        transport = CloudKitCoreTransport(database: database)
        let host = SyncEngineHost(
            transport: transport,
            keepICloudAccount: { [unowned self] in keptAccounts.append($0) },
            keepServiceAccount: { [unowned self] in keptServiceAccounts.append($0) },
            signInChanges: signInChanges.eraseToAnyPublisher(),
            open: { [unowned self] provider, listener in
                openAttempts.append(provider)
                await opening?.wait()
                guard opens else { throw AccountError.network("the account did not open") }
                opened.append(provider)
                self.listener = listener
                if provider == .off, let offEngine {
                    return offEngine
                }
                if provider == .icloud, opened.filter({ $0 == .icloud }).count > 1, let reopened {
                    return reopened
                }
                return engine
            }
        )
        coordinator = SyncProviderCoordinator(
            host: host,
            loadSettings: { [unowned self] in
                var settings = settings
                settings.enabled = enabled
                return settings
            },
            licenseGate: { nil },
            policyGate: { [unowned self] in policy },
            policyChanges: policyChanges.eraseToAnyPublisher(),
            licenseChanges: Empty().eraseToAnyPublisher(),
            journal: journal,
            makeNetworkMonitor: { nil },
            metadata: metadata,
            pushRegistrar: .inert,
            activationClock: clock,
            notificationCenter: notifications,
            readCoreWrites: { [unowned self] in coreWriteReads += 1 }
        )
    }

    var passes: [PassReasonTag] {
        engine.read { $0.passes }
    }

    var providers: [SyncProviderTag] {
        engine.read { $0.providers }
    }

    // What the engine's pass sends: one batch, then another, as an upload of two batches does.
    func uploadTwoBatches() {
        let transport = transport
        engine.update { state in
            state.pass = { _ in
                for name in ["Tag_A", "Tag_B"] {
                    _ = try? await transport.modify(
                        account: "_alice",
                        saves: [CloudKitRecord(recordType: "ConnectionTag", name: name, systemFields: nil, createdMs: nil, fields: [])],
                        deletes: []
                    )
                }
            }
        }
    }

    static func notice() -> [AnyHashable: Any] {
        [
            "aps": ["content-available": 1],
            "ck": [
                "ce": 2,
                "cid": CloudKitSyncEngine.defaultContainerID,
                "nid": UUID().uuidString,
                "met": ["dbs": 1, "sid": SyncPushSubscription.id]
            ] as [String: Any]
        ]
    }
}

@MainActor
struct SyncProviderCoordinatorTests {
    @Test("With the switch on, launch tells the engine iCloud and asks for a pass, with the transport open")
    func launchRunsOnICloud() async throws {
        let fixture = try Fixture()

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.providers == [.icloud])
        #expect(fixture.passes == [.launch])
        #expect(!fixture.transport.isClosed)
        #expect(fixture.coordinator.syncStatus == .idle)
    }

    @Test("With the switch off, nothing opens the engine and the transport stays closed")
    func switchOffOpensNothing() async throws {
        let fixture = try Fixture()
        fixture.enabled = false

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.coordinator.syncStatus == .disabled(.userDisabled))
        #expect(fixture.passes.isEmpty)
        #expect(fixture.listener == nil)
        #expect(fixture.transport.isClosed)
    }

    @Test("A profile that leaves iCloud out keeps it off from launch, with the organization as the reason")
    func managedAtLaunch() async throws {
        let fixture = try Fixture()
        fixture.policy = .managedPolicy

        fixture.coordinator.start()
        await fixture.coordinator.syncNow()

        #expect(fixture.coordinator.syncStatus == .disabled(.managedPolicy))
        #expect(fixture.passes.isEmpty)
        #expect(fixture.transport.isClosed)
    }

    @Test("A profile that arrives during an upload stops it: the batch in flight is cancelled and no later one is sent")
    func policyStopsAnUploadInFlight() async throws {
        let fixture = try Fixture()
        fixture.database.update { $0.modifiesToHold = 1 }
        fixture.uploadTwoBatches()
        fixture.coordinator.start()
        try await waitUntil { fixture.database.modifyStarted == 1 }

        fixture.policy = .managedPolicy
        fixture.policyChanges.send(.managedPolicy)
        await fixture.coordinator.passesFinished()
        try await waitUntil { fixture.providers.last == .off }

        #expect(fixture.coordinator.syncStatus == .disabled(.managedPolicy))
        #expect(fixture.database.read { $0.modifiesCancelled } == 1)
        #expect(fixture.database.modifyStarted == 1)
        #expect(fixture.transport.isClosed)
    }

    @Test("A stop while the engine is still opening keeps iCloud off: no pass runs and the engine is told off")
    func stopWhileTheEngineOpens() async throws {
        let fixture = try Fixture()
        let opening = AsyncGate()
        fixture.opening = opening
        fixture.coordinator.start()
        await opening.arrived(1)

        fixture.policy = .managedPolicy
        fixture.policyChanges.send(.managedPolicy)
        await opening.open()
        await fixture.coordinator.passesFinished()
        try await waitUntil { fixture.providers == [.off] }

        #expect(fixture.coordinator.syncStatus == .disabled(.managedPolicy))
        #expect(fixture.passes.isEmpty)
        #expect(fixture.transport.isClosed)
    }

    @Test("Turned off and on again during a pass, the transport opens only once that pass ends")
    func reopenWaitsForTheStalePass() async throws {
        let fixture = try Fixture()
        let gate = AsyncGate()
        fixture.engine.update { $0.pass = { _ in await gate.wait() } }
        fixture.coordinator.start()
        await gate.arrived(1)

        fixture.enabled = false
        fixture.coordinator.disableSync()
        fixture.enabled = true
        fixture.coordinator.enableSync()
        #expect(fixture.transport.isClosed)
        await gate.open()
        await fixture.coordinator.passesFinished()

        #expect(!fixture.transport.isClosed)
        #expect(fixture.passes == [.launch, .person])
        #expect(fixture.coordinator.syncStatus == .idle)
    }

    @Test("Turning the switch off closes the transport and tells the engine iCloud is off")
    func switchingOff() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.enabled = false
        fixture.coordinator.disableSync()
        try await waitUntil { fixture.providers.last == .off }

        #expect(fixture.coordinator.syncStatus == .disabled(.userDisabled))
        #expect(fixture.transport.isClosed)
        #expect(fixture.opened == [.icloud])
    }

    @Test("Turning the switch on opens the transport and runs the person's pass")
    func switchingOn() async throws {
        let fixture = try Fixture()
        fixture.enabled = false
        fixture.coordinator.start()

        fixture.enabled = true
        fixture.coordinator.enableSync()
        await fixture.coordinator.passesFinished()

        #expect(fixture.passes == [.person])
        #expect(fixture.providers == [.icloud])
        #expect(!fixture.transport.isClosed)
    }

    @Test("Turned on after a write opened the engine Off, iCloud opens an engine of its own, which runs the pass")
    func switchingOnAfterAnOffOpen() async throws {
        let fixture = try Fixture()
        let off = FakeSyncEngine()
        off.update { state in
            state.refusesProviderCalls = true
            state.info.provider = .off
            state.info.phase = .off
        }
        fixture.offEngine = off
        fixture.enabled = false
        fixture.coordinator.start()
        fixture.journal.recorded(.connection, written: ["A"])
        try await waitUntil { off.read { $0.hostChanges.count } == 1 }

        fixture.enabled = true
        fixture.coordinator.enableSync()
        await fixture.coordinator.passesFinished()

        #expect(fixture.opened == [.off, .icloud])
        #expect(fixture.providers == [.icloud])
        #expect(fixture.passes == [.person])
        #expect(off.read { $0.passes }.isEmpty)
        #expect(fixture.coordinator.syncStatus == .idle)
    }

    @Test("An iCloud open that fails after an Off open shows sync failed, and the next pass opens it")
    func failedICloudOpenAfterAnOffOpen() async throws {
        let fixture = try Fixture()
        let off = FakeSyncEngine()
        off.update { state in
            state.refusesProviderCalls = true
            state.info.provider = .off
            state.info.phase = .off
        }
        fixture.offEngine = off
        fixture.enabled = false
        fixture.coordinator.start()
        fixture.journal.recorded(.connection, written: ["A"])
        try await waitUntil { off.read { $0.hostChanges.count } == 1 }

        fixture.opens = false
        fixture.enabled = true
        fixture.coordinator.enableSync()
        await fixture.coordinator.passesFinished()
        #expect(fixture.coordinator.syncStatus == .error(.unexpected))

        fixture.opens = true
        await fixture.coordinator.syncNow()

        #expect(fixture.opened == [.off, .icloud])
        #expect(fixture.passes == [.person])
        #expect(fixture.coordinator.syncStatus == .idle)
    }

    @Test("With iCloud stopped by the organization and the switch on, a write opens the engine Off, not for iCloud")
    func writeUnderAPolicyOpensOff() async throws {
        let fixture = try Fixture()
        fixture.policy = .managedPolicy
        fixture.coordinator.start()

        fixture.journal.recorded(.group, written: ["G"])
        try await waitUntil { fixture.engine.read { $0.hostChanges.count } == 1 }

        #expect(fixture.opened == [.off])
        #expect(fixture.passes.isEmpty)
        #expect(fixture.transport.isClosed)
    }

    @Test("A stop with no service open for iCloud opens none to tell it Off")
    func stopOpensNothingToTellOff() async throws {
        let fixture = try Fixture()
        fixture.opens = false
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.enabled = false
        fixture.coordinator.disableSync()
        // Choices run in order, so this pass's runs after the stop's.
        fixture.opens = true
        fixture.enabled = true
        fixture.coordinator.enableSync()
        await fixture.coordinator.passesFinished()

        #expect(fixture.openAttempts == [.icloud, .icloud])
        #expect(fixture.providers == [.icloud])
        #expect(fixture.passes == [.person])
    }

    @Test("A quit waits for the writes told so far to reach the engine, then for its marks to flush")
    func quitFlushesTheMarks() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.journal.recorded(.connection, written: ["A"])
        await fixture.coordinator.flushBeforeQuit()

        #expect(fixture.engine.read { $0.flushes } == [1])
    }

    @Test("A quit flushes the service that is open, whichever provider it was opened for")
    func quitFlushesAnOffService() async throws {
        let fixture = try Fixture()
        let off = FakeSyncEngine()
        fixture.offEngine = off
        fixture.enabled = false
        fixture.coordinator.start()

        fixture.journal.recorded(.connection, deleted: ["A"])
        await fixture.coordinator.flushBeforeQuit()

        #expect(fixture.opened == [.off])
        #expect(off.read { $0.flushes } == [1])
    }

    @Test("After iCloud stopped, a sign-in change opens iCloud's service again, which keeps the mirror, and tells it Off")
    func reopenIsToldTheOffChoice() async throws {
        let fixture = try Fixture()
        let replacement = FakeSyncEngine()
        fixture.reopened = replacement
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        fixture.enabled = false
        fixture.coordinator.disableSync()
        try await waitUntil { fixture.providers.last == .off }

        fixture.signInChanges.send()

        try await waitUntil { replacement.read { $0.providers } == [.off] }
        #expect(fixture.opened == [.icloud, .icloud])
        #expect(fixture.transport.isClosed)
    }

    @Test("While iCloud runs, a sign-in change opens its service again and tells it iCloud")
    func reopenIsToldICloud() async throws {
        let fixture = try Fixture()
        let replacement = FakeSyncEngine()
        fixture.reopened = replacement
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.signInChanges.send()

        try await waitUntil { replacement.read { $0.providers } == [.icloud] }
        #expect(fixture.opened == [.icloud, .icloud])
    }

    @Test("A quit waits for the marks of a service a sign-in change closed")
    func quitWaitsForAClosedServicesFlush() async throws {
        let fixture = try Fixture()
        let gate = AsyncGate()
        let closed = fixture.engine
        closed.update { $0.flush = { await gate.wait() } }
        fixture.reopened = FakeSyncEngine()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.signInChanges.send()
        await gate.arrived(1)
        let quitting = Task { await fixture.coordinator.flushBeforeQuit() }
        try await waitUntil { fixture.clock.pendingSleeperCount == 2 }
        fixture.clock.advance(by: SyncProviderCoordinator.quitFlushLimit)
        await quitting.value

        #expect(fixture.opened == [.icloud, .icloud])
        #expect(fixture.reopened?.read { $0.flushes }.isEmpty == true)
        await gate.open()
        try await waitUntil { fixture.reopened?.read { $0.flushes } == [0] }
    }

    @Test("A write told to a service a sign-in change closed meanwhile flushes that service itself")
    func deliveryToAClosedServiceFlushesIt() async throws {
        let fixture = try Fixture()
        let gate = AsyncGate()
        let closed = fixture.engine
        let replacement = FakeSyncEngine()
        fixture.reopened = replacement
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        closed.update { $0.recording = { await gate.wait() } }

        fixture.journal.recorded(.connection, deleted: ["A"])
        await gate.arrived(1)
        fixture.signInChanges.send()
        try await waitUntil { fixture.opened == [.icloud, .icloud] }
        await gate.open()

        try await waitUntil { closed.read { $0.flushes } == [0, 1] }
        #expect(replacement.read { $0.hostChanges }.isEmpty)
    }

    @Test("A flush that does not answer holds the quit only for the limit")
    func quitFlushIsBounded() async throws {
        let fixture = try Fixture()
        let gate = AsyncGate()
        fixture.engine.update { $0.flush = { await gate.wait() } }
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        let quitting = Task { await fixture.coordinator.flushBeforeQuit() }
        await gate.arrived(1)
        // The activation hold after the launch pass sleeps too, for longer.
        try await waitUntil { fixture.clock.pendingSleeperCount == 2 }
        fixture.clock.advance(by: SyncProviderCoordinator.quitFlushLimit)
        await quitting.value
        await gate.open()

        #expect(fixture.engine.read { $0.flushes } == [0])
    }

    @Test("A quit before sync started opens nothing")
    func quitBeforeStartOpensNothing() async throws {
        let fixture = try Fixture()

        await fixture.coordinator.flushBeforeQuit()

        #expect(fixture.openAttempts.isEmpty)
    }

    @Test("A CloudKit notice asks the engine for a pass")
    func noticeAsksForAPass() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.coordinator.handleRemoteNotification(Fixture.notice())
        await fixture.coordinator.passesFinished()

        #expect(fixture.passes == [.launch, .cloudKitPush])
    }

    @Test("What arrives during a pass runs once after it, as the strongest of what arrived")
    func requestsDuringAPassRunOnceAfter() async throws {
        let fixture = try Fixture()
        let gate = AsyncGate()
        fixture.engine.update { $0.pass = { _ in await gate.wait() } }
        fixture.coordinator.start()
        await gate.arrived(1)

        fixture.coordinator.handleRemoteNotification(Fixture.notice())
        let asked = Task { await fixture.coordinator.syncNow() }
        fixture.coordinator.handleRemoteNotification(Fixture.notice())
        await gate.open()
        await asked.value

        #expect(fixture.passes == [.launch, .person])
    }

    @Test("After a pass, an activation waits out the interval and then runs once")
    func activationIsHeldForTheInterval() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.coordinator.syncIfNeeded()
        fixture.coordinator.syncIfNeeded()
        #expect(fixture.passes == [.launch])

        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: SyncProviderCoordinator.activationInterval)
        try await waitUntil { fixture.passes.count == 2 }
        await fixture.coordinator.passesFinished()

        #expect(fixture.passes == [.launch, .foreground])
    }

    @Test("A removed zone shows as such, and Upload Again asks the engine before a pass")
    func removedZoneAndUploadAgain() async throws {
        let fixture = try Fixture()
        fixture.engine.update { $0.info.phase = .zoneRemoved }
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        #expect(fixture.coordinator.syncStatus == .error(.blocked(.dataDeletedFromICloud)))

        await fixture.coordinator.uploadAgain()

        #expect(fixture.engine.read { $0.uploadsAgain } == 1)
        #expect(fixture.passes == [.launch, .person])
    }

    @Test("Upload Again does nothing unless the zone was removed")
    func uploadAgainNeedsARemovedZone() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        await fixture.coordinator.uploadAgain()

        #expect(fixture.engine.read { $0.uploadsAgain } == 0)
    }

    @Test("An account whose core did not open leaves no engine, and the status says sync failed")
    func engineThatDoesNotOpen() async throws {
        let fixture = try Fixture()
        fixture.opens = false

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.coordinator.syncStatus == .error(.unexpected))
    }

    @Test("The engine's signal reads its status again")
    func listenerRefreshesStatus() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.engine.update { state in
            state.info.problem = "sync.icloud.quota_exceeded"
            state.info.lastPassMs = 1_764_000_000_000
        }
        try #require(fixture.listener).statusChanged()

        try await waitUntil { fixture.coordinator.syncStatus == .error(.blocked(.storageFull)) }
        #expect(fixture.coordinator.lastSyncDate == Date(timeIntervalSince1970: 1_764_000_000))
    }

    @Test("Each pass the engine finished has the stores it may have written read again, once")
    func aFinishedPassReadsTheCoresWrites() async throws {
        let fixture = try Fixture()
        let engine = fixture.engine
        engine.update { state in
            state.pass = { _ in engine.update { $0.info.lastPassMs = 1_764_000_000_000 } }
        }
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        #expect(fixture.coreWriteReads == 1)

        engine.update { $0.info.problem = "sync.icloud.quota_exceeded" }
        try #require(fixture.listener).statusChanged()
        try await waitUntil { fixture.coordinator.syncStatus == .error(.blocked(.storageFull)) }
        #expect(fixture.coreWriteReads == 1)

        engine.update { state in
            state.info.problem = nil
            state.info.lastPassMs = 1_764_000_060_000
        }
        try #require(fixture.listener).statusChanged()
        try await waitUntil { fixture.coreWriteReads == 2 }
    }

    @Test("An iCloud account change cancels the call in flight, then asks for a pass")
    func accountChange() async throws {
        let fixture = try Fixture()
        fixture.database.update { $0.modifiesToHold = 1 }
        fixture.uploadTwoBatches()
        fixture.coordinator.start()
        try await waitUntil { fixture.database.modifyStarted == 1 }

        fixture.notifications.post(name: .CKAccountChanged, object: nil)
        try await waitUntil { fixture.database.read { $0.modifiesCancelled } == 1 }
        try await waitUntil { fixture.passes.count == 2 }
        await fixture.coordinator.passesFinished()

        #expect(fixture.passes == [.launch, .accountChanged])
        #expect(!fixture.transport.isClosed)
    }

    @Test("A store's write reaches the engine at once, offline too, and asks for one pass after a quiet spell")
    func journalReachesTheEngineAndDebouncesAPass() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        fixture.journal.recorded(.connection, written: ["A"])
        fixture.journal.recorded(.group, deleted: ["G"])
        try await waitUntil { fixture.engine.read { $0.hostChanges.count } == 2 }
        #expect(fixture.engine.read { $0.hostChanges } == [
            SyncHostChange(kind: "connection", written: ["A"], deleted: []),
            SyncHostChange(kind: "group", written: [], deleted: ["G"])
        ])
        #expect(fixture.passes == [.launch])

        // The activation hold after the launch pass sleeps too, for longer.
        try await waitUntil { fixture.clock.pendingSleeperCount == 2 }
        fixture.clock.advance(by: SyncProviderCoordinator.journalDebounce)
        try await waitUntil { fixture.passes.count == 2 }
        await fixture.coordinator.passesFinished()

        #expect(fixture.passes == [.launch, .journal])
    }

    @Test("With iCloud off, a store's write still reaches the engine for the previous stable, and asks for no pass")
    func journalWhileOffReachesTheEngine() async throws {
        let fixture = try Fixture()
        fixture.enabled = false
        fixture.coordinator.start()

        fixture.journal.recorded(.connection, deleted: ["A"])

        try await waitUntil { fixture.engine.read { $0.hostChanges.count } == 1 }
        await fixture.coordinator.passesFinished()
        #expect(fixture.engine.read { $0.hostChanges } == [SyncHostChange(kind: "connection", written: [], deleted: ["A"])])
        #expect(fixture.passes.isEmpty)
        #expect(fixture.transport.isClosed)
    }

    @Test("A change the engine did not take goes again with the next, ahead of it and merged by kind")
    func refusedHostChangesGoAgain() async throws {
        let fixture = try Fixture()
        fixture.enabled = false
        fixture.engine.update { $0.refuseHostChanges = true }
        fixture.coordinator.start()
        fixture.journal.recorded(.connection, written: ["A"])
        fixture.journal.recorded(.group, deleted: ["G"])
        try await waitUntil { fixture.engine.read { $0.hostChangeAttempts } >= 2 }

        fixture.engine.update { $0.refuseHostChanges = false }
        fixture.journal.recorded(.connection, deleted: ["A"])

        try await waitUntil { fixture.engine.read { $0.hostChanges.count } == 2 }
        #expect(fixture.engine.read { $0.hostChanges } == [
            SyncHostChange(kind: "connection", written: [], deleted: ["A"]),
            SyncHostChange(kind: "group", written: [], deleted: ["G"])
        ])
    }

    @Test("A pass tells the engine this Mac's categories once, and a change tells it again with a pass")
    func categoriesReachTheEngine() async throws {
        let fixture = try Fixture()
        fixture.settings.syncTableFavorites = false
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        #expect(fixture.engine.read { $0.categories } == [
            SyncCategoriesArg(offKinds: ["favourite_table"], passwords: true)
        ])

        fixture.settings.syncTableFavorites = true
        fixture.coordinator.categoriesChanged()
        try await waitUntil { fixture.engine.read { $0.categories.count } == 2 }
        await fixture.coordinator.passesFinished()

        #expect(fixture.engine.read { $0.categories }.last == SyncCategoriesArg(offKinds: [], passwords: true))
        #expect(fixture.passes.last == .person)
    }

    @Test("The iCloud account the engine used is kept after each pass, for the next launch's open")
    func theEnginesICloudAccountIsKept() async throws {
        let fixture = try Fixture()
        fixture.engine.update { $0.icloudAccount = "_alice" }

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.keptAccounts.last == "_alice")
    }

    @Test("The TablePro Sync sign-in the engine follows is kept when it opens and after each status change")
    func theEnginesServiceAccountIsKept() async throws {
        let fixture = try Fixture()
        fixture.engine.update { $0.serviceAccount = "https://api.tablepro.app acct_a" }

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        #expect(fixture.keptServiceAccounts.last == "https://api.tablepro.app acct_a")

        fixture.engine.update { $0.serviceAccount = "https://api.tablepro.app acct_b" }
        fixture.listener?.statusChanged()
        try await waitUntil { fixture.keptServiceAccounts.last == "https://api.tablepro.app acct_b" }
    }

    @Test("The open hands the core the sign-in it kept and this Mac's route publisher")
    func openConfigCarriesTheKeptAccounts() {
        let publisher = UUID()
        let config = SyncEngineHost.openConfig(
            provider: .tableproSync,
            settings: .default,
            icloudAccount: "_alice",
            serviceAccount: "https://api.tablepro.app acct_a",
            routePublisher: publisher
        )

        #expect(config.icloudAccount == "_alice")
        #expect(config.serviceAccount == "https://api.tablepro.app acct_a")
        #expect(config.routePublisher == publisher.uuidString)
    }

    @Test("A pass whose categories the engine refused sends nothing, so a category turned off never goes up")
    func refusedCategoriesStopThePass() async throws {
        let fixture = try Fixture()
        fixture.engine.update { $0.refuseCategories = true }

        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()

        #expect(fixture.providers == [.icloud])
        #expect(fixture.passes.isEmpty)
    }

    @Test("A stop followed at once by an allow still stops iCloud before it waits for the switch again")
    func stopThenAllowStillStops() async throws {
        let fixture = try Fixture()
        fixture.coordinator.start()
        await fixture.coordinator.passesFinished()
        var seen: [SyncStatus] = []
        let watching = fixture.coordinator.$syncStatus.sink { seen.append($0) }
        defer { watching.cancel() }

        fixture.policy = .managedPolicy
        fixture.policyChanges.send(.managedPolicy)
        fixture.policy = nil
        fixture.policyChanges.send(nil)
        try await waitUntil { seen.last == .idle }
        await fixture.coordinator.passesFinished()

        #expect(seen.contains(.disabled(.managedPolicy)))
        #expect(fixture.transport.isClosed == false)
    }

    @Test("Allowed again with the switch off, iCloud stays off for the person's reason")
    func allowedAgainFollowsTheSwitch() async throws {
        let fixture = try Fixture()
        fixture.enabled = false
        fixture.policy = .managedPolicy
        fixture.coordinator.start()
        #expect(fixture.coordinator.syncStatus == .disabled(.managedPolicy))

        fixture.policy = nil
        fixture.policyChanges.send(nil)

        try await waitUntil { fixture.coordinator.syncStatus == .disabled(.userDisabled) }
        #expect(fixture.transport.isClosed)
    }
}

@MainActor
struct SyncEngineHostTests {
    private let icloud = FakeSyncEngine()
    private let service = FakeSyncEngine()

    private func host(opening: AsyncGate? = nil, opens: @escaping @MainActor (SyncProviderTag) -> Void = { _ in }) -> SyncEngineHost {
        SyncEngineHost(
            transport: CloudKitCoreTransport(database: FakeCloudKitDatabase()),
            open: { [icloud, service] provider, _ in
                opens(provider)
                await opening?.wait()
                return provider == .icloud ? icloud : service
            }
        )
    }

    @Test("Off reaches iCloud's service only: with another provider's open, iCloud has none, though Off is served")
    func iCloudsServiceIsNamedExplicitly() async throws {
        let host = host()

        #expect(try await host.engine(for: .icloud) === icloud)
        #expect(await host.existingEngine(for: .icloud) === icloud)
        #expect(try await host.engine(for: .tableproSync) === service)

        #expect(await host.existingEngine(for: .icloud) == nil)
        #expect(try await host.engine(for: .off) === service)
    }

    // A new engine for each open, so a test can tell the service before a sign-in change from the one after.
    private static func reopeningHost(
        signInChanges: PassthroughSubject<Void, Never>,
        opening: AsyncGate? = nil,
        opened: OSAllocatedUnfairLock<[(SyncProviderTag, FakeSyncEngine)]>
    ) -> SyncEngineHost {
        SyncEngineHost(
            transport: CloudKitCoreTransport(database: FakeCloudKitDatabase()),
            signInChanges: signInChanges.eraseToAnyPublisher(),
            open: { provider, _ in
                let engine = FakeSyncEngine()
                let count = opened.withLock { opens in
                    opens.append((provider, engine))
                    return opens.count
                }
                if count == 1 {
                    await opening?.wait()
                }
                return engine
            }
        )
    }

    @Test("Closing the open service flushes it and opens one Off in its place")
    func closeRetiresTheService() async throws {
        let opened = OSAllocatedUnfairLock<[(SyncProviderTag, FakeSyncEngine)]>(initialState: [])
        let host = Self.reopeningHost(signInChanges: PassthroughSubject<Void, Never>(), opened: opened)
        let first = try await host.engine(for: .tableproSync)

        host.close()
        let closed = host.openedEngine(for: .off)
        try await waitUntil { opened.withLock { $0.count } == 2 }
        let second = try await host.engine(for: .off)

        #expect(closed == nil)
        #expect(second !== first)
        #expect(second === opened.withLock { $0[1].1 })
        #expect(opened.withLock { $0.map { $0.0 } } == [.tableproSync, .off])
        try await waitUntil { opened.withLock { $0[0].1 }.read { $0.flushes }.count == 1 }
    }

    @Test("A sign-in change closes the open service and opens one for the same provider")
    func signInChangeReopens() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let opened = OSAllocatedUnfairLock<[(SyncProviderTag, FakeSyncEngine)]>(initialState: [])
        let host = Self.reopeningHost(signInChanges: changes, opened: opened)
        let first = try await host.engine(for: .icloud)

        changes.send()
        try await waitUntil { opened.withLock { $0.count } == 2 }
        let second = try await host.engine(for: .icloud)

        #expect(second !== first)
        #expect(second === opened.withLock { $0[1].1 })
        #expect(opened.withLock { $0.map { $0.0 } } == [.icloud, .icloud])
        #expect(host.openedEngine(for: .icloud) === second)
    }

    @Test("An open in flight when the sign-in changes is never kept, and its callers get the one opened after")
    func openDuringASignInChangeIsDropped() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let gate = AsyncGate()
        let opened = OSAllocatedUnfairLock<[(SyncProviderTag, FakeSyncEngine)]>(initialState: [])
        let host = Self.reopeningHost(signInChanges: changes, opening: gate, opened: opened)
        let asked = Task { try await host.engine(for: .off) }
        await gate.arrived(1)

        changes.send()
        await gate.open()
        let engine = try await asked.value

        #expect(opened.withLock { $0.map { $0.0 } } == [.off, .off])
        #expect(engine === opened.withLock { $0[1].1 })
        #expect(host.openedEngine(for: .off) === engine)
    }

    @Test("Once the quit stops reopening, a sign-in change closes nothing and opens nothing")
    func noReopenOnceQuitting() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let opened = OSAllocatedUnfairLock<[(SyncProviderTag, FakeSyncEngine)]>(initialState: [])
        let host = Self.reopeningHost(signInChanges: changes, opened: opened)
        let first = try await host.engine(for: .icloud)

        host.stopReopening()
        changes.send()

        #expect(host.openedEngine(for: .icloud) === first)
        #expect(opened.withLock { $0.count } == 1)
    }

    @Test("With no service open, a sign-in change opens none")
    func signInChangeWithNothingOpen() async throws {
        let changes = PassthroughSubject<Void, Never>()
        let opened = OSAllocatedUnfairLock<[(SyncProviderTag, FakeSyncEngine)]>(initialState: [])
        let host = Self.reopeningHost(signInChanges: changes, opened: opened)

        changes.send()
        #expect(await host.existingEngine(for: nil) == nil)

        #expect(opened.withLock { $0.isEmpty })
    }

    @Test("Asking for iCloud's service waits for its open in flight and never opens one itself")
    func existingWaitsAndNeverOpens() async throws {
        let opened = OSAllocatedUnfairLock<[SyncProviderTag]>(initialState: [])
        let gate = AsyncGate()
        let host = host(opening: gate) { provider in opened.withLock { $0.append(provider) } }
        #expect(await host.existingEngine(for: .icloud) == nil)
        #expect(opened.withLock { $0 }.isEmpty)

        let opening = Task { try await host.engine(for: .icloud) }
        await gate.arrived(1)
        let existing = Task { await host.existingEngine(for: .icloud) }
        await gate.open()

        #expect(await existing.value === icloud)
        #expect(try await opening.value === icloud)
        #expect(opened.withLock { $0 } == [.icloud])
    }
}

struct SyncProviderCoordinatorStatusTests {
    private static func info(_ phase: SyncPhaseTag, problem: String? = nil) -> SyncStatusInfo {
        SyncStatusInfo(
            provider: .icloud,
            phase: phase,
            lastPassMs: nil,
            problem: problem,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
    }

    @Test("Each phase of the engine reads as the status the app already shows")
    func phases() {
        #expect(SyncEngineRules.status(Self.info(.idle)) == .idle)
        #expect(SyncEngineRules.status(Self.info(.syncing)) == .syncing)
        #expect(SyncEngineRules.status(Self.info(.zoneRemoved)) == .error(.blocked(.dataDeletedFromICloud)))
        #expect(SyncEngineRules.status(Self.info(.waiting(retryInMs: 500))) == .error(.busy))
        #expect(SyncEngineRules.status(Self.info(.off)) == .idle)
        #expect(SyncEngineRules.status(Self.info(.unavailable)) == .error(.blocked(.unavailable)))
        #expect(SyncEngineRules.status(Self.info(.pullOnly)) == .error(.unexpected))
        #expect(SyncEngineRules.status(Self.info(.idle, problem: "sync.icloud.network")) == .error(.offline))
        #expect(SyncEngineRules.status(Self.info(.idle, problem: "sync.icloud.account_changed")) == .idle)
        // Only the engine's phase offers Upload Again.
        #expect(SyncEngineRules.status(Self.info(.idle, problem: "sync.icloud.zone_deleted_by_user")) == .error(.unexpected))
    }

    @Test("Each iCloud problem code is the condition the person can act on")
    func problems() {
        let expected: [String: SyncError?] = [
            "sync.icloud.no_account": .blocked(.signedOut),
            "sync.icloud.restricted": .blocked(.accountRestricted),
            "sync.icloud.account_temporarily_unavailable": .blocked(.accountNotReady),
            "sync.icloud.quota_exceeded": .blocked(.storageFull),
            "sync.icloud.network": .offline,
            "sync.icloud.throttled": .busy,
            "sync.state.anchor_unsettled": .waitingForKeychain,
            "sync.device_store.locked": .waitingForKeychain,
            "sync.adapter.store": .pullNotSaved,
            "sync.unimplemented": .blocked(.unavailable),
            "sync.icloud.account_changed": nil,
            "sync.cancelled": nil,
            "sync.icloud.other": .unexpected
        ]
        for (code, error) in expected {
            #expect(SyncEngineRules.error(forProblem: code) == error, "\(code)")
        }
    }

    @Test("The person's pass stands in for any other, and a journal pass for none")
    func strongestPass() {
        #expect(SyncEngineRules.stronger(nil, .foreground) == .foreground)
        #expect(SyncEngineRules.stronger(.foreground, .person) == .person)
        #expect(SyncEngineRules.stronger(.person, .cloudKitPush) == .person)
        #expect(SyncEngineRules.stronger(.journal, .foreground) == .foreground)
        #expect(SyncEngineRules.stronger(.cloudKitPush, .journal) == .cloudKitPush)
        #expect(SyncEngineRules.stronger(.cloudKitPush, .accountChanged) == .accountChanged)
        #expect(SyncEngineRules.stronger(.accountChanged, .person) == .person)
    }

    @Test("Each switch that is off names its core kinds, and passwords ride only with connections")
    func categoriesFromTheSwitches() {
        var settings = SyncSettings.default
        settings.enabled = true
        settings.syncGroupsAndTags = false
        settings.syncSQLFavorites = false
        settings.syncPasswords = true

        let categories = SyncProviderCoordinator.categories(settings)

        #expect(Set(categories.offKinds) == [
            "group", "tag", "connection_project", "saved_query", "saved_query_folder",
        ])
        #expect(categories.passwords)
        #expect(!SyncProviderCoordinator.categories(settings.settingConnections(false)).passwords)
        #expect(SyncProviderCoordinator.categories(settings.settingConnections(false)).offKinds.contains("connection"))
    }
}

extension SyncPushRegistrar {
    static let inert = SyncPushRegistrar(register: {}, unregister: {})
}
