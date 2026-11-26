import Combine
import Foundation
import os
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import TableProTestSupport
import Testing

// What the moves did, in order, across the services, CloudKit and the stored provider. Each service's calls carry the
// provider it was opened for.
private final class MoveLog: @unchecked Sendable {
    private let events = OSAllocatedUnfairLock(uncheckedState: [String]())

    func append(_ event: String) {
        events.withLockUnchecked { $0.append(event) }
    }

    var all: [String] {
        events.withLockUnchecked { $0 }
    }
}

private struct ScriptedFailure: Error {}

private final class FakeMoveEngine: SyncMoveEngine, @unchecked Sendable {
    struct State {
        var provider: SyncProviderTag?
        var keys: KeyStateInfo = .approved(av: 1, keyDevice: "DEVICE")
        var scopes: [ScopeStatusInfo] = []
        var moveFails = false
        var moveGate: AsyncGate?
        var moveBackGate: AsyncGate?
    }

    let opened: SyncProviderTag
    private let log: MoveLog
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(opened: SyncProviderTag, log: MoveLog) {
        self.opened = opened
        self.log = log
        state.withLockUnchecked { $0.provider = opened }
    }

    private var name: String {
        switch opened {
        case .off: "off"
        case .icloud: "icloud"
        case .tableproSync: "tablepro-sync"
        }
    }

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    private func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    func status() -> SyncStatusInfo {
        SyncStatusInfo(
            provider: read { $0.provider },
            phase: .idle,
            lastPassMs: nil,
            problem: nil,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
    }

    func scopeStatuses() -> [ScopeStatusInfo] {
        read { $0.scopes }
    }

    func syncNow(why: PassReasonTag) async throws {
        log.append("\(name) syncNow")
    }

    func chooseProvider(provider: SyncProviderTag) async throws {
        log.append("\(name) chooseProvider \(provider)")
        update { $0.provider = provider }
    }

    func keyState() async throws -> KeyStateInfo {
        log.append("\(name) keyState")
        return read { $0.keys }
    }

    func planMoveToService() async throws -> MovePlanInfo {
        MovePlanInfo(records: 12, stayingBehind: 2, secretsToSeal: 3)
    }

    func moveToService() async throws {
        log.append("\(name) moveToService")
        await read { $0.moveGate }?.wait()
        if read({ $0.moveFails }) {
            throw ScriptedFailure()
        }
    }

    func firstUpload() async throws {
        log.append("\(name) firstUpload")
        await read { $0.moveGate }?.wait()
        if read({ $0.moveFails }) {
            throw ScriptedFailure()
        }
    }

    func planMoveToIcloud() async throws -> MoveBackPlanInfo {
        MoveBackPlanInfo(icloudDeletions: 3)
    }

    func moveToIcloud(confirmedDeletions: UInt64) async throws {
        log.append("\(name) moveToIcloud \(confirmedDeletions)")
        await read { $0.moveBackGate }?.wait()
        if read({ $0.moveFails }) {
            throw ScriptedFailure()
        }
    }

    func chooseForNewIdentity(choice: NewIdentityChoiceTag) async throws {
        log.append("\(name) chooseForNewIdentity \(choice)")
    }

    func deleteIcloudZone() async throws {
        log.append("\(name) deleteIcloudZone")
    }
}

@MainActor
private final class Fixture {
    let log = MoveLog()
    let slice: SettingsSlice<SyncSettings>
    let engineChanges = PassthroughSubject<Void, Never>()
    // The one service open at a time, as `SyncEngineHost` keeps it: opening another replaces it.
    private(set) var opened: FakeMoveEngine?
    var iCloudRuns = false
    var cloudKitClosed = true
    var snapshot = ManagedPolicySnapshot()
    var passesGate: AsyncGate?
    var prepare: (FakeMoveEngine) -> Void = { _ in }
    private(set) var moves: ProviderMoves!

    init(provider: SyncProviderSetting, open: SyncProviderTag? = nil) {
        var settings = SyncSettings.default
        settings.provider = provider
        slice = SettingsSlice(settings)
        iCloudRuns = provider == .iCloud
        slice.attach { [unowned self] _, new in
            log.append("provider \(new.provider.rawValue)")
            iCloudRuns = new.provider == .iCloud
        }
        let host = ProviderMoveHost(
            engine: { [unowned self] provider in service(for: provider) },
            openedEngine: { [unowned self] provider in
                guard let opened, provider == .off || opened.opened == provider else { return nil }
                return opened
            },
            engineChanges: engineChanges.eraseToAnyPublisher(),
            iCloudRuns: { [unowned self] in iCloudRuns },
            passesFinished: { [unowned self] in
                log.append("passesFinished")
                await passesGate?.wait()
            },
            cloudKit: CloudKitReach(
                isClosed: { [unowned self] in cloudKitClosed },
                open: { [unowned self] in
                    log.append("openCloudKit")
                    cloudKitClosed = false
                },
                close: { [unowned self] in
                    log.append("closeCloudKit")
                    cloudKitClosed = true
                }
            ),
            policy: { [unowned self] in snapshot }
        )
        moves = ProviderMoves(host: host, settings: slice)
        if let open {
            _ = service(for: open)
        }
    }

    func service(for provider: SyncProviderTag) -> FakeMoveEngine {
        if let opened, provider == .off || opened.opened == provider {
            return opened
        }
        let engine = FakeMoveEngine(opened: provider, log: log)
        prepare(engine)
        opened = engine
        return engine
    }

    var provider: SyncProviderSetting {
        slice.value.provider
    }
}

@MainActor
struct ProviderMovesTests {
    // MARK: - To TablePro Sync

    @Test("From iCloud the move runs on iCloud's service, then the provider changes and TablePro Sync's takes the first pass")
    func moveFromICloud() async throws {
        let fixture = Fixture(provider: .iCloud, open: .icloud)

        let outcome = try await fixture.moves.moveToService()

        #expect(outcome == .moved)
        #expect(fixture.log.all == [
            "icloud keyState", "icloud moveToService", "provider tablepro-sync", "passesFinished",
            "tablepro-sync syncNow"
        ])
        #expect(fixture.provider == .tableproSync)
        #expect(fixture.opened?.opened == .tableproSync)
        #expect(!fixture.moves.awaitsMove)
    }

    @Test("From Off it is the first upload, on the service open for Off")
    func moveFromOff() async throws {
        let fixture = Fixture(provider: .off)

        _ = try await fixture.moves.moveToService()

        #expect(fixture.log.all == ["off keyState", "off firstUpload", "provider tablepro-sync", "tablepro-sync syncNow"])
        #expect(fixture.provider == .tableproSync)
    }

    @Test("Without the account's keys nothing changes and nothing goes up")
    func needsKeysChangesNothing() async throws {
        let states: [KeyStateInfo] = [.noKeys, .needsApproval(request: nil), .locked(cause: .deviceRemoved), .noDeviceStore]
        for keys in states {
            let fixture = Fixture(provider: .iCloud)
            fixture.prepare = { $0.update { $0.keys = keys } }

            let outcome = try await fixture.moves.moveToService()

            #expect(outcome == .needsKeys(keys))
            #expect(fixture.log.all == ["icloud keyState"])
            #expect(fixture.provider == .iCloud)
        }
    }

    @Test("A move that fails keeps the stored provider, so Try Again runs on the same service")
    func failedMoveKeepsTheProvider() async throws {
        let fixture = Fixture(provider: .iCloud, open: .icloud)
        fixture.opened?.update { $0.moveFails = true }

        await #expect(throws: ScriptedFailure.self) {
            try await fixture.moves.moveToService()
        }
        #expect(fixture.provider == .iCloud)

        fixture.opened?.update { $0.moveFails = false }
        #expect(try await fixture.moves.moveToService() == .moved)
        #expect(fixture.log.all.filter { $0 == "icloud moveToService" }.count == 2)
        #expect(fixture.provider == .tableproSync)
    }

    @Test("A profile that leaves TablePro Sync out refuses the move before anything runs")
    func moveRefusedByTheProfile() async {
        let fixture = Fixture(provider: .iCloud)
        fixture.snapshot = ManagedPolicySnapshot(personalSyncProvider: ["off", "icloud"])

        await #expect(throws: ProviderMoveError.notAllowed) {
            try await fixture.moves.moveToService()
        }
        #expect(fixture.log.all.isEmpty)
        #expect(fixture.provider == .iCloud)
    }

    @Test("A server that keeps no personal data refuses the move before anything runs")
    func moveRefusedByTheServer() async throws {
        let fixture = Fixture(provider: .off, open: .off)
        fixture.opened?.update {
            $0.scopes = [ScopeStatusInfo(scope: "personal", writable: true, personalSync: false, passwordSync: true, historySync: nil)]
        }
        fixture.moves.start()
        fixture.engineChanges.send()

        await #expect(throws: ProviderMoveError.serverRefusesPersonalSync) {
            try await fixture.moves.moveToService()
        }
        #expect(!fixture.log.all.contains("off firstUpload"))
    }

    @Test("A second move while one runs is refused")
    func oneMoveAtATime() async throws {
        let fixture = Fixture(provider: .off, open: .off)
        let gate = AsyncGate()
        fixture.opened?.update { $0.moveGate = gate }

        let first = Task { try await fixture.moves.moveToService() == .moved }
        await gate.arrived(1)
        await #expect(throws: ProviderMoveError.inProgress) {
            try await fixture.moves.moveToService()
        }
        await gate.open()

        #expect(try await first.value)
    }

    @Test("Off chosen while the engine moves wins: the provider stays Off and no first pass runs")
    func offDuringAMoveWins() async throws {
        let fixture = Fixture(provider: .iCloud, open: .icloud)
        let gate = AsyncGate()
        fixture.opened?.update { $0.moveGate = gate }

        let move = Task { try await fixture.moves.moveToService() == .moved }
        await gate.arrived(1)
        fixture.slice.update { $0.provider = .off }
        await gate.open()

        await #expect(throws: ProviderMoveError.superseded) {
            try await move.value
        }
        #expect(fixture.provider == .off)
        #expect(!fixture.log.all.contains("tablepro-sync syncNow"))
    }

    // MARK: - Back to iCloud

    @Test("The move back runs on TablePro Sync's service with CloudKit open, and hands CloudKit to iCloud open")
    func moveBack() async throws {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)

        try await fixture.moves.moveToICloud(confirmedDeletions: 3)

        #expect(fixture.log.all == ["passesFinished", "openCloudKit", "tablepro-sync moveToIcloud 3", "provider icloud"])
        #expect(fixture.provider == .iCloud)
        #expect(!fixture.cloudKitClosed)
    }

    @Test("A move back that fails closes CloudKit again and stays on TablePro Sync")
    func failedMoveBack() async {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)
        fixture.opened?.update { $0.moveFails = true }

        await #expect(throws: ScriptedFailure.self) {
            try await fixture.moves.moveToICloud(confirmedDeletions: 3)
        }

        #expect(fixture.log.all == ["passesFinished", "openCloudKit", "tablepro-sync moveToIcloud 3", "closeCloudKit"])
        #expect(fixture.provider == .tableproSync)
        #expect(fixture.cloudKitClosed)
    }

    @Test("Off chosen during the move back wins, and CloudKit closes again")
    func offDuringTheMoveBack() async throws {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)
        let gate = AsyncGate()
        fixture.opened?.update { $0.moveBackGate = gate }

        let move = Task { try await fixture.moves.moveToICloud(confirmedDeletions: 3) }
        await gate.arrived(1)
        fixture.slice.update { $0.provider = .off }
        await gate.open()

        await #expect(throws: ProviderMoveError.superseded) {
            try await move.value
        }
        #expect(fixture.provider == .off)
        #expect(fixture.cloudKitClosed)
    }

    @Test("A profile that takes iCloud away refuses the move back")
    func moveBackRefusedByTheProfile() async {
        let fixture = Fixture(provider: .tableproSync)
        fixture.snapshot = ManagedPolicySnapshot(iCloudSyncAllowed: false)

        await #expect(throws: ProviderMoveError.notAllowed) {
            try await fixture.moves.moveToICloud(confirmedDeletions: 0)
        }
        #expect(fixture.log.all.isEmpty)
    }

    // MARK: - Off

    @Test("Off from TablePro Sync tells its service")
    func offFromTableProSync() async {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)

        await fixture.moves.turnOff()

        #expect(fixture.provider == .off)
        #expect(fixture.log.all == ["provider off", "tablepro-sync chooseProvider off"])
    }

    @Test("Off from iCloud is the coordinator's to tell the engine")
    func offFromICloud() async {
        let fixture = Fixture(provider: .iCloud, open: .icloud)

        await fixture.moves.turnOff()

        #expect(fixture.log.all == ["provider off"])
    }

    @Test("A reset to Off while TablePro Sync's service is open turns it off too")
    func resetReconcilesTheEngine() async throws {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)
        fixture.moves.start()

        fixture.slice.value = .default

        try await waitUntil { fixture.opened?.status().provider == .off }
        #expect(fixture.log.all.contains("tablepro-sync chooseProvider off"))
    }

    @Test("A profile that requires TablePro Sync leaves the Mac off and waiting for the person's upload")
    func forcedTableProSyncWaits() async throws {
        let fixture = Fixture(provider: .off)
        fixture.snapshot = ManagedPolicySnapshot(personalSyncProvider: ["tablepro-sync"])

        #expect(fixture.moves.awaitsMove)

        _ = try await fixture.moves.moveToService()

        #expect(fixture.provider == .tableproSync)
        #expect(!fixture.moves.awaitsMove)
        #expect(fixture.log.all.contains("off firstUpload"))
    }

    // MARK: - Another account

    @Test("The choice for another account goes to the service in use, then a pass")
    func newIdentity() async throws {
        for (provider, name) in [(SyncProviderSetting.iCloud, "icloud"), (.tableproSync, "tablepro-sync")] {
            let fixture = Fixture(provider: provider)

            try await fixture.moves.chooseForNewIdentity(.startEmpty)

            #expect(fixture.log.all == ["\(name) chooseForNewIdentity startEmpty", "\(name) syncNow"])
        }
    }

    // MARK: - iCloud data

    @Test("Deleting the iCloud data opens CloudKit for the call and closes it after")
    func deleteICloudData() async throws {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)

        #expect(fixture.moves.offersICloudDataDeletion)
        try await fixture.moves.deleteICloudData()

        #expect(fixture.log.all == ["passesFinished", "openCloudKit", "tablepro-sync deleteIcloudZone", "closeCloudKit"])
    }

    @Test("A profile that takes iCloud away while the deletion waits keeps CloudKit closed and deletes nothing")
    func policyRevokedBeforeCloudKitOpens() async throws {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)
        let gate = AsyncGate()
        fixture.passesGate = gate

        let deletion = Task { try await fixture.moves.deleteICloudData() }
        await gate.arrived(1)
        fixture.snapshot = ManagedPolicySnapshot(iCloudSyncAllowed: false)
        await gate.open()

        await #expect(throws: ProviderMoveError.notAllowed) {
            try await deletion.value
        }
        #expect(!fixture.log.all.contains("openCloudKit"))
        #expect(!fixture.log.all.contains("tablepro-sync deleteIcloudZone"))
        #expect(fixture.cloudKitClosed)
    }

    @Test("The iCloud data stays while this Mac syncs with iCloud, and once the organization takes iCloud away")
    func deleteICloudDataRefused() async {
        let onICloud = Fixture(provider: .iCloud)
        let managed = Fixture(provider: .off)
        managed.snapshot = ManagedPolicySnapshot(iCloudSyncAllowed: false)

        for fixture in [onICloud, managed] {
            #expect(!fixture.moves.offersICloudDataDeletion)
            await #expect(throws: ProviderMoveError.notAllowed) {
                try await fixture.moves.deleteICloudData()
            }
            #expect(fixture.log.all.isEmpty)
        }
    }

    // MARK: - Server policies

    @Test("The scopes come from the open service, and only a personal scope with its switch off refuses")
    func serverScopes() async throws {
        let fixture = Fixture(provider: .tableproSync, open: .tableproSync)
        let scopes = [
            ScopeStatusInfo(scope: "personal", writable: true, personalSync: true, passwordSync: false, historySync: nil),
            ScopeStatusInfo(scope: "history", writable: true, personalSync: true, passwordSync: nil, historySync: false),
        ]
        fixture.opened?.update { $0.scopes = scopes }
        fixture.moves.start()

        fixture.engineChanges.send()

        #expect(fixture.moves.scopes == scopes)
        #expect(!ProviderMoves.refusesPersonalSync(scopes))
        #expect(ProviderMoves.refusesPersonalSync([
            ScopeStatusInfo(scope: "personal", writable: true, personalSync: false, passwordSync: nil, historySync: nil)
        ]))
        #expect(!ProviderMoves.refusesPersonalSync([]))
    }

    // MARK: - Words

    @Test("The engine's codes map to words that never name the engine", arguments: [
        "sync.network", "sync.locked", "sync.license_expired", "sync.signed_out", "sync.unimplemented"
    ])
    func messagesForCodes(code: String) {
        let message = ProviderMoves.message(forCode: code)
        #expect(!message.isEmpty)
        #expect(!message.contains(code))
    }
}

// The core engine as both the iCloud coordinator and the moves drive it, one per provider it is opened for, so the
// handoff runs through the real coordinator and engine host.
private final class CoordinatedEngine: SyncEngine, SyncMoveEngine, @unchecked Sendable {
    let opened: SyncProviderTag
    private let state: OSAllocatedUnfairLock<(provider: SyncProviderTag, calls: [String])>
    private let listener: any SyncListener

    init(opened: SyncProviderTag, listener: any SyncListener) {
        self.opened = opened
        self.listener = listener
        state = OSAllocatedUnfairLock(uncheckedState: (opened, []))
    }

    var calls: [String] {
        state.withLockUnchecked { $0.calls }
    }

    private func record(_ call: String, provider: SyncProviderTag? = nil) {
        state.withLockUnchecked {
            if let provider {
                $0.provider = provider
            }
            $0.calls.append(call)
        }
        listener.statusChanged()
    }

    func status() -> SyncStatusInfo {
        SyncStatusInfo(
            provider: state.withLockUnchecked { $0.provider },
            phase: .idle,
            lastPassMs: nil,
            problem: nil,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
    }

    func scopeStatuses() -> [ScopeStatusInfo] { [] }
    func syncNow(why: PassReasonTag) async throws { record("sync") }
    func chooseProvider(provider: SyncProviderTag) async throws { record("choose \(provider)", provider: provider) }
    func setCategories(categories: SyncCategoriesArg) async throws {}
    func recordHostChanges(kind: String, written: [String], deleted: [String]) async throws {}
    func uploadAgain() async throws {}
    func icloudAccount() -> String? { nil }
    func keyState() async throws -> KeyStateInfo { .approved(av: 1, keyDevice: "DEVICE") }
    func planMoveToService() async throws -> MovePlanInfo { MovePlanInfo(records: 1, stayingBehind: 0, secretsToSeal: 0) }
    func moveToService() async throws { record("move to service") }
    func firstUpload() async throws { record("first upload") }
    func planMoveToIcloud() async throws -> MoveBackPlanInfo { MoveBackPlanInfo(icloudDeletions: 0) }
    func moveToIcloud(confirmedDeletions: UInt64) async throws { record("move to iCloud") }
    func chooseForNewIdentity(choice: NewIdentityChoiceTag) async throws {}
    func deleteIcloudZone() async throws {}
}

@MainActor
private final class Services {
    var all: [CoordinatedEngine] = []

    func first(_ provider: SyncProviderTag) -> CoordinatedEngine? {
        all.first { $0.opened == provider }
    }
}

@MainActor
struct ProviderMovesCoordinatorTests {
    @Test("From a running iCloud the coordinator's Off goes to iCloud's service, and TablePro Sync's takes the first pass")
    func moveFromICloudThroughTheCoordinator() async throws {
        let suite = try EphemeralDefaults("ProviderMovesCoordinatorTests")
        let services = Services()
        let transport = CloudKitCoreTransport(database: FakeCloudKitDatabase())
        let host = SyncEngineHost(transport: transport) { provider, listener in
            let engine = CoordinatedEngine(opened: provider, listener: listener)
            services.all.append(engine)
            return engine
        }
        var initial = SyncSettings.default
        initial.provider = .iCloud
        let slice = SettingsSlice(initial)
        let coordinator = SyncProviderCoordinator(
            host: host,
            loadSettings: { slice.value },
            licenseGate: { nil },
            policyGate: { nil },
            policyChanges: Empty().eraseToAnyPublisher(),
            licenseChanges: Empty().eraseToAnyPublisher(),
            journal: SyncHostJournal(),
            makeNetworkMonitor: { nil },
            metadata: SyncMetadataStorage(userDefaults: suite.defaults),
            pushRegistrar: .inert,
            activationClock: ManualClock(),
            notificationCenter: NotificationCenter()
        )
        // As AppSettingsManager's commit does.
        slice.attach { old, new in
            guard old.enabled != new.enabled else { return }
            if new.enabled {
                coordinator.enableSync()
            } else {
                coordinator.disableSync()
            }
        }
        let moves = ProviderMoves(
            host: ProviderMoveHost(
                engine: { provider in
                    guard let engine = try await host.engine(for: provider) as? any SyncMoveEngine else {
                        throw ProviderMoveError.engineUnavailable
                    }
                    return engine
                },
                openedEngine: { provider in host.openedEngine(for: provider) as? any SyncMoveEngine },
                engineChanges: host.statusChanges.eraseToAnyPublisher(),
                iCloudRuns: { coordinator.syncStatus.isEnabled },
                passesFinished: { await coordinator.passesFinished() },
                cloudKit: CloudKitReach(
                    isClosed: { transport.isClosed },
                    open: { transport.open() },
                    close: { transport.close() }
                ),
                policy: { ManagedPolicySnapshot() }
            ),
            settings: slice
        )
        coordinator.start()
        await coordinator.passesFinished()

        #expect(try await moves.moveToService() == .moved)
        try await waitUntil { services.first(.icloud)?.calls.contains("choose off") == true }
        await coordinator.passesFinished()

        let iCloud = try #require(services.first(.icloud))
        let service = try #require(services.first(.tableproSync))
        #expect(iCloud.calls.contains("move to service"))
        #expect(iCloud.calls.last == "choose off")
        #expect(service.calls == ["sync"])
        #expect(service.status().provider == .tableproSync)
        #expect(transport.isClosed)
        #expect(slice.value.provider == .tableproSync)
    }
}
