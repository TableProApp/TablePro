import CloudKit
import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
private final class LibraryStateBox {
    var connections: [DatabaseConnection] = []
    var groups: [ConnectionGroup] = []
    var tags: [ConnectionTag] = []
    var duringPull: () -> Void = {}
    var duringPush: () -> Void = {}
    var duringAccountCheck: () -> Void = {}
    var syncEnabled = true

    func runDuringPull() {
        duringPull()
    }

    func runDuringPush() {
        duringPush()
    }

    func runDuringAccountCheck() {
        duringAccountCheck()
    }
}

private actor FakeSyncTransport: IOSSyncTransport {
    let currentZoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let remoteRecords: [CKRecord]
    private let box: LibraryStateBox
    private let accountId: String?
    private let recordsTheServerNeverHad: Set<String>
    private(set) var pushedRecords: [CKRecord] = []
    private(set) var pushedDeletions: [CKRecord.ID] = []
    private(set) var pullCount = 0
    private(set) var accountLookups = 0

    init(
        remoteRecords: [CKRecord],
        box: LibraryStateBox,
        accountId: String? = "account-a",
        recordsTheServerNeverHad: Set<String> = []
    ) {
        self.remoteRecords = remoteRecords
        self.box = box
        self.accountId = accountId
        self.recordsTheServerNeverHad = recordsTheServerNeverHad
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        accountLookups += 1
        await box.runDuringAccountCheck()
        guard let accountId else { throw CKError(.notAuthenticated) }
        return accountId
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        await box.runDuringPull()
        return PullResult(changedRecords: remoteRecords, deletedRecordIDs: [], newToken: nil)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        pushedRecords.append(contentsOf: records)
        pushedDeletions.append(contentsOf: deletions)
        await box.runDuringPush()
        let missing = deletions.filter { recordsTheServerNeverHad.contains($0.recordName) }
        return PushOutcome(
            savedRecords: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) }),
            deletedRecordIDs: Set(deletions).subtracting(missing),
            failures: Dictionary(uniqueKeysWithValues: missing.map { recordID in
                (
                    recordID,
                    SyncItemFailure(code: .unknownItem, serverRecord: nil, clientRecord: nil, message: "Record not found")
                )
            })
        )
    }
}

@MainActor
@Suite("iOS sync coordinator")
struct IOSSyncCoordinatorTests {
    private let metadata: SyncMetadataStorage
    private let cacheDirectory: URL
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.IOSSync.\(UUID().uuidString)"))
        metadata = SyncMetadataStorage(userDefaults: defaults)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sync-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private var tokenKey: String { "com.TablePro.sync.serverChangeToken" }

    private func makeCoordinator(box: LibraryStateBox, transport: FakeSyncTransport) -> IOSSyncCoordinator {
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: cacheDirectory, defaults: nil),
            makeTransport: { transport },
            isEnabled: { box.syncEnabled },
            notificationCenter: NotificationCenter()
        )
        coordinator.getCurrentState = { (box.connections, box.groups, box.tags) }
        coordinator.onConnectionsChanged = { box.connections = $0 }
        coordinator.onGroupsChanged = { box.groups = $0 }
        coordinator.onTagsChanged = { box.tags = $0 }
        return coordinator
    }

    @Test("A rename made while the sync waits on iCloud is kept and pushed")
    func editDuringPullIsKept() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Old", type: .mysql)
        box.connections = [local]
        let remote = DatabaseConnection(name: "From Mac", type: .postgresql)
        let transport = FakeSyncTransport(
            remoteRecords: [SyncRecordMapper.toRecord(remote, zoneID: zoneID)],
            box: box
        )
        let coordinator = makeCoordinator(box: box, transport: transport)
        box.duringPull = {
            box.connections[0].name = "New"
            coordinator.markDirty(local.id)
        }

        await coordinator.sync()

        #expect(box.connections.first { $0.id == local.id }?.name == "New")
        #expect(box.connections.contains { $0.id == remote.id })
        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection)
        #expect(pushed.first { $0.id == local.id }?.name == "New")
    }

    @Test("A connection edited while its push is in flight stays marked for the next sync")
    func editDuringPushStaysDirty() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Old", type: .mysql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        box.duringPush = {
            box.connections[0].name = "Edited during push"
            coordinator.markDirty(local.id)
        }

        await coordinator.sync()

        #expect(metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
        #expect(box.connections.first?.name == "Edited during push")
    }

    @Test("A push nothing touched clears the connection's flag")
    func untouchedPushClearsDirty() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Stable", type: .mysql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)

        await coordinator.sync()

        #expect(!metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
        #expect(coordinator.status == .idle)
    }

    @Test("A favorite set on iPhone reaches the record")
    func favoriteIsPushed() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql, isFavorite: true)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection)
        #expect(pushed.first?.isFavorite == true)
    }

    @Test("Sync is off: changes wait, and nothing is pulled or pushed")
    func disabledSyncOnlyQueues() async {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Local", type: .mysql)
        box.connections = [local]
        box.syncEnabled = false
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        coordinator.markDirty(local.id)
        coordinator.markDeleted(UUID())
        await coordinator.sync()

        #expect(await transport.pullCount == 0)
        #expect(await transport.accountLookups == 0)
        #expect(await transport.pushedRecords.isEmpty)
        #expect(metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
        #expect(metadata.tombstones(for: .connection).count == 1)
        #expect(coordinator.status == .disabled(.userDisabled))
    }

    @Test("A sample connection is never pushed, even when marked")
    func sampleIsNeverPushed() async {
        let box = LibraryStateBox()
        let sample = DatabaseConnection(name: "Sample", type: .sqlite, database: "Chinook.sqlite", isSample: true)
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [sample, local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(sample.id)
        coordinator.markDirty(local.id)

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(pushed == [local.id])
    }

    @Test("A second sync waits for the one already running instead of returning early")
    func concurrentSyncJoins() async {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        async let first: Void = coordinator.sync()
        async let second: Void = coordinator.sync()
        _ = await (first, second)

        #expect(await transport.pullCount == 1)
        #expect(coordinator.status == .idle)
        #expect(coordinator.lastSyncDate != nil)
    }

    @Test("Turning sync on sends what changed while it was off, except the sample")
    func enablingSendsQueuedChanges() async throws {
        let box = LibraryStateBox()
        let sample = DatabaseConnection(name: "Sample", type: .sqlite, database: "Chinook.sqlite", isSample: true)
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [sample, local]
        box.syncEnabled = false
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(sample.id)
        coordinator.markDirty(local.id)

        box.syncEnabled = true
        coordinator.setEnabled(true)
        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(pushed == [local.id])
    }

    @Test("Turning sync off forgets the last sync, so turning it on again shows the first pull")
    func disablingResetsFirstSync() async {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        await coordinator.sync()
        #expect(coordinator.hasCompletedFirstSync)

        box.syncEnabled = false
        coordinator.setEnabled(false)

        #expect(coordinator.hasCompletedFirstSync == false)
    }

    @Test("Turning sync off wins over a sync that was already running")
    func disablingWinsOverRunningSync() async {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        box.duringPull = {
            box.syncEnabled = false
            coordinator.setEnabled(false)
        }

        await coordinator.sync()

        #expect(coordinator.status == .disabled(.userDisabled))
        #expect(coordinator.lastSyncDate == nil)
    }

    // MARK: - iCloud account

    @Test("Signing in to a different Apple Account starts sync over and still sends the edits waiting to go up")
    func accountSwitchResetsSyncState() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let cachedID = SyncRecordMapper.recordID(type: .connection, id: local.id.uuidString, in: zoneID)
        let cache = SyncRecordCache(directory: cacheDirectory, defaults: nil)
        let staleRecord = SyncRecordMapper.toRecord(local, zoneID: zoneID)
        staleRecord["staleAccountMarker"] = "account-a" as CKRecordValue
        cache.store([staleRecord])
        metadata.lastAccountId = "account-a"
        metadata.lastSyncDate = Date()
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-b")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        coordinator.markDeleted(UUID())
        var lastSyncDateDuringPull: Date? = Date()
        var cachedDuringPull: CKRecord?
        box.duringPull = {
            lastSyncDateDuringPull = coordinator.lastSyncDate
            cachedDuringPull = cache.record(for: cachedID)
        }

        await coordinator.sync()

        let pushed = await transport.pushedRecords
        #expect(pushed.compactMap(SyncRecordMapper.toConnection).map(\.id) == [local.id])
        #expect(pushed.allSatisfy { $0["staleAccountMarker"] == nil })
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(cachedDuringPull == nil)
        #expect(metadata.dirtyIds(for: .connection).isEmpty)
        #expect(metadata.tombstones(for: .connection).isEmpty)
        #expect(metadata.userDefaults.data(forKey: tokenKey) == nil)
        #expect(lastSyncDateDuringPull == nil)
        #expect(metadata.lastAccountId == "account-b")
        #expect(box.connections.contains { $0.id == local.id })
        #expect(coordinator.status == .idle)
    }

    @Test("A connection added while the new account is being looked up reaches that account")
    func editDuringAccountLookupIsPushed() async throws {
        let box = LibraryStateBox()
        metadata.lastAccountId = "account-a"
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-b")
        let coordinator = makeCoordinator(box: box, transport: transport)
        let added = DatabaseConnection(name: "Prod", type: .postgresql)
        box.duringAccountCheck = {
            box.connections.append(added)
            coordinator.markDirty(added.id)
        }

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection)
        #expect(pushed.map(\.id) == [added.id])
        #expect(metadata.dirtyIds(for: .connection).isEmpty)
        #expect(metadata.lastAccountId == "account-b")
    }

    @Test("The same account keeps its queued edits, deletions and change token")
    func sameAccountKeepsState() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let deleted = UUID()
        metadata.lastAccountId = "account-a"
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-a")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        coordinator.markDeleted(deleted)

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(pushed == [local.id])
        #expect(await transport.pushedDeletions.map(\.recordName).contains { $0.contains(deleted.uuidString) })
        #expect(metadata.userDefaults.data(forKey: tokenKey) == Data([1, 2, 3]))
        #expect(metadata.lastAccountId == "account-a")
    }

    @Test("With no account recorded yet, queued changes go up and the account is recorded")
    func firstSeenAccountPushesQueue() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-a")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(pushed == [local.id])
        #expect(metadata.lastAccountId == "account-a")
    }

    @Test("A device that synced on a build that never recorded its account starts over once and keeps its queue")
    func unrecordedAccountStartsOverOnce() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let deleted = UUID()
        let cachedID = SyncRecordMapper.recordID(type: .connection, id: local.id.uuidString, in: zoneID)
        let cache = SyncRecordCache(directory: cacheDirectory, defaults: nil)
        let staleRecord = SyncRecordMapper.toRecord(local, zoneID: zoneID)
        staleRecord["staleAccountMarker"] = "account-a" as CKRecordValue
        cache.store([staleRecord])
        metadata.lastSyncDate = Date()
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-b")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        coordinator.markDeleted(deleted)
        var cachedDuringPull: CKRecord? = staleRecord
        box.duringPull = { cachedDuringPull = cache.record(for: cachedID) }

        await coordinator.sync()

        let pushed = await transport.pushedRecords
        #expect(cachedDuringPull == nil)
        #expect(pushed.compactMap(SyncRecordMapper.toConnection).map(\.id) == [local.id])
        #expect(pushed.allSatisfy { $0["staleAccountMarker"] == nil })
        #expect(await transport.pushedDeletions.map(\.recordName).contains { $0.contains(deleted.uuidString) })
        #expect(metadata.userDefaults.data(forKey: tokenKey) == nil)
        #expect(metadata.lastAccountId == "account-b")

        var cachedDuringSecondPull: CKRecord?
        box.duringPull = { cachedDuringSecondPull = cache.record(for: cachedID) }
        coordinator.markDirty(local.id)
        await coordinator.sync()

        #expect(cachedDuringSecondPull != nil)
    }

    @Test("An edit made during the first pull for a new account is pushed to that account")
    func editAfterSwitchIsPushed() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Old", type: .mysql)
        box.connections = [local]
        metadata.lastAccountId = "account-a"
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-b")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        box.duringPull = {
            box.connections[0].name = "Renamed"
            coordinator.markDirty(local.id)
        }

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection)
        #expect(pushed.map(\.id) == [local.id])
        #expect(pushed.first?.name == "Renamed")
    }

    @Test("After an account change made while sync was off, edits go up to the new account and deletions do not")
    func accountChangedWhileOffSendsEditsOnly() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Local", type: .mysql)
        box.connections = [local]
        box.syncEnabled = false
        metadata.lastAccountId = "account-a"
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-b")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        coordinator.markDeleted(UUID())

        box.syncEnabled = true
        coordinator.setEnabled(true)
        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection)
        #expect(pushed.map(\.id) == [local.id])
        #expect(await transport.pushedDeletions.isEmpty)
        #expect(box.connections == [local])
    }

    @Test("Turning sync off during the account check keeps the recorded account and the queue")
    func disablingDuringAccountCheckKeepsState() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Local", type: .mysql)
        box.connections = [local]
        metadata.lastAccountId = "account-a"
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-b")
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        box.duringAccountCheck = {
            box.syncEnabled = false
            coordinator.setEnabled(false)
        }

        await coordinator.sync()

        #expect(metadata.lastAccountId == "account-a")
        #expect(metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
        #expect(await transport.pullCount == 0)
        #expect(coordinator.status == .disabled(.userDisabled))
    }

    @Test("An account that cannot be looked up is never pulled, and nothing recorded is dropped")
    func failedAccountLookupNeverPulls() async throws {
        let box = LibraryStateBox()
        metadata.lastAccountId = "account-a"
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: nil)
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(await transport.pullCount == 0)
        #expect(coordinator.status == .error(.accountUnavailable))
        #expect(metadata.lastAccountId == "account-a")
        #expect(metadata.userDefaults.data(forKey: tokenKey) == Data([1, 2, 3]))
    }

    @Test("Deleting a connection the new account never had clears its deletion instead of retrying it")
    func deletionTheServerNeverHadIsCleared() async throws {
        let box = LibraryStateBox()
        let kept = DatabaseConnection(name: "Kept", type: .mysql)
        box.connections = [kept]
        metadata.lastAccountId = "account-a"
        let recordName = SyncRecordMapper.recordID(type: .connection, id: kept.id.uuidString, in: zoneID).recordName
        let transport = FakeSyncTransport(
            remoteRecords: [],
            box: box,
            accountId: "account-b",
            recordsTheServerNeverHad: [recordName]
        )
        let coordinator = makeCoordinator(box: box, transport: transport)
        await coordinator.sync()

        box.connections = []
        coordinator.markDeleted(kept.id)
        await coordinator.sync()

        #expect(await transport.pushedDeletions.map(\.recordName) == [recordName])
        #expect(metadata.tombstones(for: .connection).isEmpty)
        #expect(coordinator.status == .idle)
    }
}
