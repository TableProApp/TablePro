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
        var uploadsAgain = 0
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
        let pass = state.withLockUnchecked { state in
            state.passes.append(why)
            return state.pass
        }
        await pass?(why)
    }

    func chooseProvider(provider: SyncProviderTag) async throws {
        update { state in
            state.providers.append(provider)
            state.info.provider = provider
        }
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
    var enabled = true
    var settings = SyncSettings.default
    var policy: DisableReason?
    var opens = true
    var listener: (any SyncListener)?
    private let suite: EphemeralDefaults
    let metadata: SyncMetadataStorage
    private(set) var coordinator: SyncProviderCoordinator!

    init() throws {
        suite = try EphemeralDefaults("SyncProviderCoordinatorTests")
        metadata = SyncMetadataStorage(userDefaults: suite.defaults)
        transport = CloudKitCoreTransport(database: database)
        let host = SyncEngineHost(transport: transport) { [unowned self] listener in
            await opening?.wait()
            guard opens else { throw AccountError.network("the account did not open") }
            self.listener = listener
            return engine
        }
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
            notificationCenter: notifications
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
        #expect(fixture.engine.read { $0.categories } == [SyncCategoriesArg(offKinds: ["favourite_table"], passwords: false)])

        fixture.settings.syncTableFavorites = true
        fixture.coordinator.categoriesChanged()
        try await waitUntil { fixture.engine.read { $0.categories.count } == 2 }
        await fixture.coordinator.passesFinished()

        #expect(fixture.engine.read { $0.categories }.last == SyncCategoriesArg(offKinds: [], passwords: false))
        #expect(fixture.passes.last == .person)
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

        #expect(Set(categories.offKinds) == ["group", "tag", "saved_query", "saved_query_folder"])
        #expect(categories.passwords)
        #expect(!SyncProviderCoordinator.categories(settings.settingConnections(false)).passwords)
        #expect(SyncProviderCoordinator.categories(settings.settingConnections(false)).offKinds.contains("connection"))
    }
}

extension SyncPushRegistrar {
    static let inert = SyncPushRegistrar(register: {}, unregister: {})
}
