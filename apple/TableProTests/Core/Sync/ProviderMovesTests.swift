import Combine
import Foundation
import os
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import TableProTestSupport
import Testing

// What the moves did, in order, across the engine, the iCloud coordinator, CloudKit and the stored provider.
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
        var info = SyncStatusInfo(
            provider: .icloud,
            phase: .idle,
            lastPassMs: nil,
            problem: nil,
            waitingApprovals: 0,
            conflicts: 0,
            held: 0,
            queuedChanges: 0
        )
        var keys: KeyStateInfo = .approved(av: 1, keyDevice: "DEVICE")
        var moveFails = false
        var moveGate: AsyncGate?
    }

    let log: MoveLog
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(log: MoveLog) {
        self.log = log
    }

    func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { change(&$0) }
    }

    private func read<Value>(_ value: (State) -> Value) -> Value {
        state.withLockUnchecked { value($0) }
    }

    func status() -> SyncStatusInfo {
        read { $0.info }
    }

    func syncNow(why: PassReasonTag) async throws {
        log.append("syncNow")
    }

    func chooseProvider(provider: SyncProviderTag) async throws {
        log.append("chooseProvider \(provider)")
        update { $0.info.provider = provider }
    }

    func keyState() async throws -> KeyStateInfo {
        log.append("keyState")
        return read { $0.keys }
    }

    func planMoveToService() async throws -> MovePlanInfo {
        MovePlanInfo(records: 12, stayingBehind: 2, secretsToSeal: 3)
    }

    func moveToService() async throws {
        log.append("moveToService")
        await read { $0.moveGate }?.wait()
        if read({ $0.moveFails }) {
            throw ScriptedFailure()
        }
        update { $0.info.provider = .tableproSync }
    }

    func planMoveToIcloud() async throws -> MoveBackPlanInfo {
        MoveBackPlanInfo(icloudDeletions: 3)
    }

    func moveToIcloud(confirmedDeletions: UInt64) async throws {
        log.append("moveToIcloud \(confirmedDeletions)")
        if read({ $0.moveFails }) {
            throw ScriptedFailure()
        }
        update { $0.info.provider = .icloud }
    }

    func chooseForNewIdentity(choice: NewIdentityChoiceTag) async throws {
        log.append("chooseForNewIdentity \(choice)")
    }

    func deleteIcloudZone() async throws {
        log.append("deleteIcloudZone")
    }
}

@MainActor
private final class Fixture {
    let log = MoveLog()
    let engine: FakeMoveEngine
    let slice: SettingsSlice<SyncSettings>
    let engineChanges = PassthroughSubject<Void, Never>()
    var iCloudRuns = false
    var cloudKitClosed = true
    var opened = true
    var snapshot = ManagedPolicySnapshot()
    private(set) var moves: ProviderMoves!

    init(provider: SyncProviderSetting, engineProvider: SyncProviderTag?) {
        engine = FakeMoveEngine(log: log)
        engine.update { $0.info.provider = engineProvider }
        var settings = SyncSettings.default
        settings.provider = provider
        slice = SettingsSlice(settings)
        iCloudRuns = provider == .iCloud
        // As AppSettingsManager's commit does: iCloud follows the provider at once.
        slice.attach { [unowned self] _, new in
            log.append("provider \(new.provider.rawValue)")
            iCloudRuns = new.provider == .iCloud
        }
        let host = ProviderMoveHost(
            engine: { [unowned self] in engine },
            openedEngine: { [unowned self] in opened ? engine : nil },
            engineChanges: engineChanges.eraseToAnyPublisher(),
            iCloudRuns: { [unowned self] in iCloudRuns },
            iCloudPass: { [unowned self] in log.append("iCloudPass") },
            passesFinished: { [unowned self] in log.append("passesFinished") },
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
    }

    var provider: SyncProviderSetting {
        slice.value.provider
    }
}

@MainActor
struct ProviderMovesTests {
    // MARK: - To TablePro Sync

    @Test("From iCloud: the last iCloud pass, then iCloud stops, then the engine moves and syncs")
    func moveFromICloud() async throws {
        let fixture = Fixture(provider: .iCloud, engineProvider: .icloud)

        let outcome = try await fixture.moves.moveToService()

        #expect(outcome == .moved)
        #expect(fixture.log.all == [
            "keyState", "iCloudPass", "provider tablepro-sync", "passesFinished", "moveToService", "syncNow"
        ])
        #expect(fixture.provider == .tableproSync)
        #expect(!fixture.moves.awaitsMove)
    }

    @Test("From Off there is no iCloud pass to run first")
    func moveFromOff() async throws {
        let fixture = Fixture(provider: .off, engineProvider: .off)

        _ = try await fixture.moves.moveToService()

        #expect(!fixture.log.all.contains("iCloudPass"))
        #expect(fixture.log.all.contains("moveToService"))
        #expect(fixture.provider == .tableproSync)
    }

    @Test("Without the account's keys nothing changes and nothing goes up")
    func needsKeysChangesNothing() async throws {
        let states: [KeyStateInfo] = [.noKeys, .needsApproval(request: nil), .locked(cause: .deviceRemoved), .noDeviceStore]
        for keys in states {
            let fixture = Fixture(provider: .iCloud, engineProvider: .icloud)
            fixture.engine.update { $0.keys = keys }

            let outcome = try await fixture.moves.moveToService()

            #expect(outcome == .needsKeys(keys))
            #expect(fixture.log.all == ["keyState"])
            #expect(fixture.provider == .iCloud)
        }
    }

    @Test("A move that fails leaves the Mac on TablePro Sync waiting for it, and Try Again runs no second iCloud pass")
    func failedMoveWaits() async throws {
        let fixture = Fixture(provider: .iCloud, engineProvider: .icloud)
        fixture.engine.update { $0.moveFails = true }

        await #expect(throws: ScriptedFailure.self) {
            try await fixture.moves.moveToService()
        }
        #expect(fixture.provider == .tableproSync)
        #expect(fixture.moves.awaitsMove)

        fixture.engine.update { $0.moveFails = false }
        #expect(try await fixture.moves.moveToService() == .moved)
        #expect(fixture.log.all.filter { $0 == "iCloudPass" }.count == 1)
        #expect(!fixture.moves.awaitsMove)
    }

    @Test("A profile that leaves TablePro Sync out refuses the move before anything runs")
    func moveRefusedByTheProfile() async {
        let fixture = Fixture(provider: .iCloud, engineProvider: .icloud)
        fixture.snapshot = ManagedPolicySnapshot(personalSyncProvider: ["off", "icloud"])

        await #expect(throws: ProviderMoveError.notAllowed) {
            try await fixture.moves.moveToService()
        }
        #expect(fixture.log.all.isEmpty)
        #expect(fixture.provider == .iCloud)
    }

    @Test("A second move while one runs is refused")
    func oneMoveAtATime() async throws {
        let fixture = Fixture(provider: .off, engineProvider: .off)
        let gate = AsyncGate()
        fixture.engine.update { $0.moveGate = gate }

        let first = Task { try await fixture.moves.moveToService() }
        await gate.arrived(1)
        await #expect(throws: ProviderMoveError.inProgress) {
            try await fixture.moves.moveToService()
        }
        await gate.open()

        #expect(try await first.value == .moved)
    }

    // MARK: - Back to iCloud

    @Test("The move back opens CloudKit, passes the confirmed count, and hands CloudKit to iCloud open")
    func moveBack() async throws {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)

        try await fixture.moves.moveToICloud(confirmedDeletions: 3)

        #expect(fixture.log.all == ["passesFinished", "openCloudKit", "moveToIcloud 3", "provider icloud"])
        #expect(fixture.provider == .iCloud)
        #expect(!fixture.cloudKitClosed)
    }

    @Test("A move back that fails closes CloudKit again and stays on TablePro Sync")
    func failedMoveBack() async {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)
        fixture.engine.update { $0.moveFails = true }

        await #expect(throws: ScriptedFailure.self) {
            try await fixture.moves.moveToICloud(confirmedDeletions: 3)
        }

        #expect(fixture.log.all == ["passesFinished", "openCloudKit", "moveToIcloud 3", "closeCloudKit"])
        #expect(fixture.provider == .tableproSync)
        #expect(fixture.cloudKitClosed)
    }

    @Test("A profile that takes iCloud away refuses the move back")
    func moveBackRefusedByTheProfile() async {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)
        fixture.snapshot = ManagedPolicySnapshot(iCloudSyncAllowed: false)

        await #expect(throws: ProviderMoveError.notAllowed) {
            try await fixture.moves.moveToICloud(confirmedDeletions: 0)
        }
        #expect(fixture.log.all.isEmpty)
    }

    // MARK: - Off

    @Test("Off from TablePro Sync tells the engine")
    func offFromTableProSync() async {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)

        await fixture.moves.turnOff()

        #expect(fixture.provider == .off)
        #expect(fixture.log.all == ["provider off", "chooseProvider off"])
    }

    @Test("Off from iCloud is the coordinator's to tell the engine")
    func offFromICloud() async {
        let fixture = Fixture(provider: .iCloud, engineProvider: .icloud)

        await fixture.moves.turnOff()

        #expect(fixture.log.all == ["provider off"])
    }

    @Test("A reset to Off while the engine is on TablePro Sync turns the engine off too")
    func resetReconcilesTheEngine() async throws {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)
        fixture.moves.start()

        fixture.slice.value = .default

        try await waitUntil { fixture.engine.status().provider == .off }
        #expect(fixture.log.all.contains("chooseProvider off"))
    }

    @Test("An engine that opens on TablePro Sync after the Mac chose Off is turned off when it reports")
    func engineOpenedLaterIsReconciled() async throws {
        let fixture = Fixture(provider: .off, engineProvider: .tableproSync)
        fixture.opened = false
        fixture.moves.start()

        fixture.opened = true
        fixture.engineChanges.send()

        try await waitUntil { fixture.engine.status().provider == .off }
    }

    @Test("A stored TablePro Sync the engine has not moved to is left for the person to confirm")
    func storedTableProSyncWaits() async throws {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .off)
        fixture.moves.start()

        fixture.engineChanges.send()

        #expect(fixture.moves.awaitsMove)
        #expect(!fixture.log.all.contains { $0.hasPrefix("chooseProvider") })
    }

    // MARK: - Another account

    @Test("On iCloud the choice for another account is followed by an iCloud pass")
    func newIdentityOnICloud() async throws {
        for choice in [NewIdentityChoiceTag.moveMyData, .startEmpty] {
            let fixture = Fixture(provider: .iCloud, engineProvider: .icloud)

            try await fixture.moves.chooseForNewIdentity(choice)

            #expect(fixture.log.all == ["chooseForNewIdentity \(choice)", "iCloudPass"])
        }
    }

    @Test("On TablePro Sync the choice for another account is followed by an engine pass")
    func newIdentityOnTableProSync() async throws {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)

        try await fixture.moves.chooseForNewIdentity(.startEmpty)

        #expect(fixture.log.all == ["chooseForNewIdentity startEmpty", "syncNow"])
    }

    // MARK: - iCloud data

    @Test("Deleting the iCloud data opens CloudKit for the call and closes it after")
    func deleteICloudData() async throws {
        let fixture = Fixture(provider: .tableproSync, engineProvider: .tableproSync)

        #expect(fixture.moves.offersICloudDataDeletion)
        try await fixture.moves.deleteICloudData()

        #expect(fixture.log.all == ["passesFinished", "openCloudKit", "deleteIcloudZone", "closeCloudKit"])
    }

    @Test("The iCloud data stays while this Mac syncs with iCloud, and once the organization takes iCloud away")
    func deleteICloudDataRefused() async {
        let onICloud = Fixture(provider: .iCloud, engineProvider: .icloud)
        let managed = Fixture(provider: .off, engineProvider: .off)
        managed.snapshot = ManagedPolicySnapshot(iCloudSyncAllowed: false)

        for fixture in [onICloud, managed] {
            #expect(!fixture.moves.offersICloudDataDeletion)
            await #expect(throws: ProviderMoveError.notAllowed) {
                try await fixture.moves.deleteICloudData()
            }
            #expect(fixture.log.all.isEmpty)
        }
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
