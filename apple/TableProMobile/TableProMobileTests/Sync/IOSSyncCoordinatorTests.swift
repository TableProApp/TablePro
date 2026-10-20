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
    var savedQueries: SavedQueryContents? = SavedQueryContents()
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
    private let remoteDeletions: [CKRecord.ID]
    private let box: LibraryStateBox
    private var accountId: String?
    private let recordsTheServerNeverHad: Set<String>
    private var accountStatuses: [CKAccountStatus] = [.available]
    private var itemFailure: SyncItemFailure?
    private var pullErrors: [any Error] = []
    private var interruption: (savedCount: Int, cause: CKError)?
    private var newToken: CKServerChangeToken?
    private(set) var pushedRecords: [CKRecord] = []
    private(set) var pushedDeletions: [CKRecord.ID] = []
    private(set) var pushCount = 0
    private(set) var pullCount = 0
    private(set) var accountLookups = 0
    private(set) var zoneSaves = 0

    init(
        remoteRecords: [CKRecord],
        box: LibraryStateBox,
        accountId: String? = "account-a",
        recordsTheServerNeverHad: Set<String> = [],
        remoteDeletions: [CKRecord.ID] = []
    ) {
        self.remoteRecords = remoteRecords
        self.remoteDeletions = remoteDeletions
        self.box = box
        self.accountId = accountId
        self.recordsTheServerNeverHad = recordsTheServerNeverHad
    }

    /// Each read takes the next status; the last one answers every read after it.
    func answerAccountStatus(_ statuses: [CKAccountStatus]) {
        accountStatuses = statuses
    }

    func signIn(as accountId: String) {
        self.accountId = accountId
    }

    /// Every record and deletion in a push fails on its own with `code`, the way CloudKit reports a
    /// full iCloud inside a partial failure.
    func failEveryItem(with code: CKError.Code, retryAfter: TimeInterval? = nil) {
        itemFailure = SyncItemFailure(
            code: code,
            serverRecord: nil,
            clientRecord: nil,
            retryAfter: retryAfter,
            message: "Error saving record <CKRecordID: 0x1; recordName=x>: rejected"
        )
    }

    func acceptEveryItem() {
        itemFailure = nil
    }

    /// The next pulls throw these, one each, before pulls succeed again.
    func failNextPulls(with errors: [any Error]) {
        pullErrors = errors
    }

    /// The next push saves its first `savedCount` records, then a later batch throws `cause`.
    func interruptNextPush(afterSaving savedCount: Int, with cause: CKError) {
        interruption = (savedCount, cause)
    }

    func answerPulls(withToken token: CKServerChangeToken) {
        newToken = token
    }

    func accountStatus() async throws -> CKAccountStatus {
        let status = accountStatuses.first ?? .available
        if accountStatuses.count > 1 {
            accountStatuses.removeFirst()
        }
        return status
    }

    func currentAccountId() async throws -> String {
        accountLookups += 1
        await box.runDuringAccountCheck()
        guard let accountId else { throw CKError(.notAuthenticated) }
        return accountId
    }

    func ensureZoneExists() async throws {
        zoneSaves += 1
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        await box.runDuringPull()
        if !pullErrors.isEmpty {
            throw pullErrors.removeFirst()
        }
        return PullResult(changedRecords: remoteRecords, deletedRecordIDs: remoteDeletions, newToken: newToken)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        pushCount += 1
        pushedRecords.append(contentsOf: records)
        pushedDeletions.append(contentsOf: deletions)
        await box.runDuringPush()
        if let interruption {
            self.interruption = nil
            let saved = records.prefix(interruption.savedCount)
            let completed = PushOutcome(savedRecords: Dictionary(uniqueKeysWithValues: saved.map { ($0.recordID, $0) }))
            throw SyncPushInterruption(completed: completed, cause: interruption.cause)
        }
        if let itemFailure {
            let ids = records.map(\.recordID) + deletions
            return PushOutcome(failures: Dictionary(uniqueKeysWithValues: ids.map { ($0, itemFailure) }))
        }
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
        // As on a device that already ran this build, so a run keeps the change token it found.
        _ = metadata.adoptReadableRecordTypes(IOSSyncCoordinator.readableRecordTypes)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sync-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private var tokenKey: String { "com.TablePro.sync.serverChangeToken" }

    private func makeCoordinator(
        box: LibraryStateBox,
        transport: FakeSyncTransport,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> IOSSyncCoordinator {
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: cacheDirectory, defaults: nil),
            makeTransport: { transport },
            isEnabled: { box.syncEnabled },
            notificationCenter: notificationCenter,
            networkMonitor: nil
        )
        coordinator.getCurrentState = { (box.connections, box.groups, box.tags) }
        coordinator.onConnectionsChanged = { box.connections = $0; return true }
        coordinator.onGroupsChanged = { box.groups = $0; return true }
        coordinator.onTagsChanged = { box.tags = $0; return true }
        coordinator.getSavedQueries = { box.savedQueries }
        coordinator.onSavedQueriesChanged = { box.savedQueries = $0; return true }
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

    @Test("A copy stored before this build read them takes the profile link and route from the cached record")
    func olderCopyTakesProfileAndRouteFromTheCache() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(
            name: "Profile",
            type: .postgresql,
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "db", username: "")
        )
        box.connections = [local]
        let cached = SyncRecordMapper.toRecord(local, zoneID: zoneID)
        let profileId = UUID()
        cached[ConnectionSyncField.sshProfileId.key] = profileId.uuidString as CKRecordValue
        SyncRecordCache(directory: cacheDirectory, defaults: nil).store([cached])
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(box.connections.first?.sshProfileId == profileId)
    }

    @Test("A profile unlinked here is not linked again from the cached record")
    func unlinkedCopyIsNotRelinkedFromTheCache() async throws {
        let box = LibraryStateBox()
        var local = DatabaseConnection(
            name: "Unlinked",
            type: .postgresql,
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "other.example", username: "deploy")
        )
        local.clearsSSHProfileLink = true
        box.connections = [local]
        let cached = SyncRecordMapper.toRecord(local, zoneID: zoneID)
        cached[ConnectionSyncField.sshProfileId.key] = UUID().uuidString as CKRecordValue
        SyncRecordCache(directory: cacheDirectory, defaults: nil).store([cached])
        let coordinator = makeCoordinator(box: box, transport: FakeSyncTransport(remoteRecords: [], box: box))

        await coordinator.sync()

        #expect(box.connections.first?.sshProfileId == nil)
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

    @Test("A sync asked for during a run waits for it and runs once more, never cutting it short")
    func concurrentSyncQueuesOneMore() async {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        async let first: Void = coordinator.sync()
        async let second: Void = coordinator.sync()
        _ = await (first, second)

        #expect(await transport.pullCount == 2)
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
        #expect(coordinator.status == .error(.blocked(.accountNotReady)))
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

    // MARK: - Failures, holding back and retrying

    @Test("A full iCloud reported item by item blocks uploads as storage full and keeps every change and Last Sync")
    func perItemQuotaBlocksAsStorageFull() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let deleted = UUID()
        metadata.lastAccountId = "account-a"
        metadata.lastSyncDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lastSync = metadata.lastSyncDate
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        coordinator.markDeleted(deleted)

        await coordinator.sync()

        #expect(coordinator.status == .error(.blocked(.storageFull)))
        #expect(metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
        #expect(metadata.tombstones(for: .connection).map(\.id) == [deleted.uuidString])
        #expect(coordinator.lastSyncDate == lastSync)
        #expect(metadata.lastSyncDate == lastSync)
    }

    @Test("While iCloud is full an edit sends nothing, a foreground only downloads, and the person's request uploads")
    func storageFullHoldsAutomaticUploads() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        await coordinator.sync()
        #expect(await transport.pushCount == 1)

        await coordinator.sync(.localChange)
        #expect(await transport.pullCount == 1)
        #expect(await transport.pushCount == 1)

        await coordinator.sync(.activation)
        #expect(await transport.pullCount == 2)
        #expect(await transport.pushCount == 1)
        #expect(coordinator.status == .error(.blocked(.storageFull)))

        await transport.acceptEveryItem()
        await coordinator.sync(.userRequest)
        #expect(await transport.pushCount == 2)
        #expect(coordinator.status == .idle)
        #expect(!metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
    }

    /// The download was throttled while uploads were held, and with the status still on the
    /// blocker nothing kept the wait, so the next foreground asked again at once.
    @Test("A download throttled while iCloud is full keeps the notice and waits out the throttle")
    func throttledDownloadWaitsOutTheThrottle() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        await coordinator.sync()
        let throttle = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 600)])
        await transport.failNextPulls(with: [throttle])

        await coordinator.sync(.activation)
        await coordinator.sync(.activation)

        #expect(await transport.pullCount == 2)
        #expect(coordinator.status == .error(.blocked(.storageFull)))
    }

    @Test("A standing problem stays on screen while an automatic run checks on it, and the person's request shows progress")
    func standingProblemDoesNotFlicker() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        await coordinator.sync()
        var statusDuringPull: SyncStatus?
        box.duringPull = { statusDuringPull = coordinator.status }

        await coordinator.sync(.activation)
        #expect(statusDuringPull == .error(.blocked(.storageFull)))

        await coordinator.sync(.userRequest)
        #expect(statusDuringPull == .syncing)
    }

    @Test("Screen Time or device management blocking iCloud reads as restricted, and nothing is fetched")
    func restrictedAccountIsBlocked() async throws {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.answerAccountStatus([.restricted])
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(coordinator.status == .error(.blocked(.accountRestricted)))
        #expect(await transport.accountLookups == 0)
        #expect(await transport.pullCount == 0)
    }

    @Test("A request refused as not signed in reads the account again and reports what the account is")
    func notAuthenticatedIsReadAgain() async throws {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: nil)
        await transport.answerAccountStatus([.available, .restricted])
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(coordinator.status == .error(.blocked(.accountRestricted)))
    }

    @Test("An account change looks at the account again, even while it was restricted", .timeLimit(.minutes(1)))
    func accountChangeLooksAgain() async throws {
        let box = LibraryStateBox()
        let center = NotificationCenter()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.answerAccountStatus([.restricted, .available])
        let coordinator = makeCoordinator(box: box, transport: transport, notificationCenter: center)
        await coordinator.sync()
        #expect(coordinator.status == .error(.blocked(.accountRestricted)))

        center.post(name: .CKAccountChanged, object: nil)
        await ObservedCondition.wait { coordinator.status == .idle }

        #expect(await transport.pullCount == 1)
    }

    @Test("Downloaded changes are acknowledged even when the upload after them fails")
    func pullTokenSavedWhenPushFails() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        metadata.lastAccountId = "account-a"
        let token = try Self.makeChangeToken()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.answerPulls(withToken: token)
        await transport.failEveryItem(with: .quotaExceeded)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)

        await coordinator.sync()

        #expect(coordinator.status == .error(.blocked(.storageFull)))
        #expect(metadata.userDefaults.data(forKey: tokenKey) != nil)
    }

    @Test("A record iCloud refuses on its own stays pending, and the rest of the run still counts as synced")
    func rejectedRecordStillStampsLastSync() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failEveryItem(with: .invalidArguments)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)

        await coordinator.sync()

        #expect(coordinator.status == .error(.recordsRejected(count: 1)))
        #expect(coordinator.lastSyncDate != nil)
        #expect(metadata.dirtyIds(for: .connection).contains(local.id.uuidString))
    }

    @Test("An upload cut short settles what already went up and keeps the rest pending")
    func interruptedPushSettlesWhatSaved() async throws {
        let box = LibraryStateBox()
        let first = DatabaseConnection(name: "First", type: .mysql)
        let second = DatabaseConnection(name: "Second", type: .mysql)
        box.connections = [first, second]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.interruptNextPush(afterSaving: 1, with: CKError(.networkFailure))
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(first.id)
        coordinator.markDirty(second.id)

        await coordinator.sync()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        let saved = try #require(pushed.first)
        let unsent = try #require(pushed.last)
        #expect(saved != unsent)
        #expect(!metadata.dirtyIds(for: .connection).contains(saved.uuidString))
        #expect(metadata.dirtyIds(for: .connection).contains(unsent.uuidString))
        #expect(coordinator.status == .error(.offline))
    }

    @Test("A cancelled run reports nothing and leaves the status it found")
    func cancellationKeepsPreviousStatus() async throws {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failNextPulls(with: [CKError(.networkUnavailable), CancellationError()])
        let coordinator = makeCoordinator(box: box, transport: transport)
        await coordinator.sync()
        #expect(coordinator.status == .error(.offline))

        await coordinator.sync()

        #expect(await transport.pullCount == 2)
        #expect(coordinator.status == .error(.offline))
        #expect(coordinator.lastSyncDate == nil)
    }

    @Test("An expired change token is dropped and everything is fetched again in the same run")
    func expiredTokenFetchesEverything() async throws {
        let box = LibraryStateBox()
        metadata.lastAccountId = "account-a"
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failNextPulls(with: [CKError(.changeTokenExpired)])
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(await transport.pullCount == 2)
        #expect(metadata.userDefaults.data(forKey: tokenKey) == nil)
        #expect(coordinator.status == .idle)
    }

    @Test("The sync zone is created once, not on every run")
    func zoneIsSavedOnlyUntilConfirmed() async {
        let box = LibraryStateBox()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()
        await coordinator.sync()

        #expect(await transport.zoneSaves == 1)
        #expect(metadata.zoneState == .confirmed)
    }

    @Test("Data deleted from iCloud is never uploaded again on a trigger, only when the person asks")
    func deletedDataWaitsForThePerson() async throws {
        let box = LibraryStateBox()
        let edited = DatabaseConnection(name: "Edited", type: .mysql)
        let untouched = DatabaseConnection(name: "Untouched", type: .mysql)
        box.connections = [edited, untouched]
        metadata.lastAccountId = "account-a"
        metadata.zoneState = .confirmed
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failNextPulls(with: [CKError(.userDeletedZone), CKError(.zoneNotFound)])
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(edited.id)

        await coordinator.sync()
        #expect(coordinator.status == .error(.blocked(.dataDeletedFromICloud)))
        #expect(metadata.zoneState == .removed)

        await coordinator.sync(.activation)
        await coordinator.sync(.localChange)
        #expect(await transport.pullCount == 2)
        #expect(await transport.zoneSaves == 0)
        #expect(await transport.pushCount == 0)
        #expect(coordinator.status == .error(.blocked(.dataDeletedFromICloud)))

        await coordinator.uploadAgain()

        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(Set(pushed) == [edited.id, untouched.id])
        #expect(await transport.zoneSaves == 1)
        #expect(metadata.zoneState == .confirmed)
        #expect(coordinator.status == .idle)
    }

    /// The block used to live only in memory, so a relaunch forgot it and the first run uploaded
    /// into a recreated zone without asking.
    @Test("Data removed from iCloud still waits for the person after a relaunch")
    func removedZoneSurvivesRelaunch() async throws {
        let box = LibraryStateBox()
        metadata.lastAccountId = "account-a"
        metadata.zoneState = .removed
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failNextPulls(with: [CKError(.userDeletedZone)])

        let coordinator = makeCoordinator(box: box, transport: transport)
        #expect(coordinator.status == .error(.blocked(.dataDeletedFromICloud)))

        await coordinator.sync(.activation)

        #expect(await transport.zoneSaves == 0)
        #expect(await transport.pushCount == 0)
        #expect(coordinator.status == .error(.blocked(.dataDeletedFromICloud)))
    }

    /// The changes this device held while the zone was gone go up right after the zone is found,
    /// rather than waiting for an unrelated edit while the status already reads up to date.
    @Test("When another device brings deleted data back, a download finds it and the held changes go up")
    func restoredZoneLiftsTheBlock() async throws {
        let box = LibraryStateBox()
        let held = DatabaseConnection(name: "Held", type: .mysql)
        box.connections = [held]
        metadata.lastAccountId = "account-a"
        metadata.zoneState = .confirmed
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failNextPulls(with: [CKError(.userDeletedZone)])
        let coordinator = makeCoordinator(box: box, transport: transport)
        await coordinator.sync()
        #expect(coordinator.status == .error(.blocked(.dataDeletedFromICloud)))
        coordinator.markDirty(held.id)

        await coordinator.sync(.activation)

        #expect(coordinator.status == .idle)
        #expect(metadata.zoneState == .confirmed)
        #expect(await transport.zoneSaves == 0)
        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toConnection).map(\.id)
        #expect(pushed == [held.id])
        #expect(metadata.dirtyIds(for: .connection).isEmpty)
    }

    @Test("Signing in to another Apple Account lifts the last account's full storage at once")
    func accountSwitchLiftsTheBlock() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box, accountId: "account-a")
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        await coordinator.sync()
        #expect(coordinator.status == .error(.blocked(.storageFull)))

        await transport.signIn(as: "account-b")
        await transport.acceptEveryItem()
        await coordinator.sync(.activation)

        #expect(await transport.pushCount == 2)
        #expect(coordinator.status == .idle)
        #expect(metadata.lastAccountId == "account-b")
    }

    @Test("Triggers that arrive during a run lead to one more run, with the one that may do the most")
    func pendingTriggersRunOnceWithTheWidest() async throws {
        let box = LibraryStateBox()
        let local = DatabaseConnection(name: "Prod", type: .postgresql)
        box.connections = [local]
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDirty(local.id)
        await coordinator.sync()
        await transport.acceptEveryItem()
        var queued: [Task<Void, Never>] = []
        box.duringPull = {
            guard queued.isEmpty else { return }
            queued.append(Task { await coordinator.sync(.localChange) })
            queued.append(Task { await coordinator.sync(.userRequest) })
        }

        await coordinator.sync(.activation)
        for task in queued {
            await task.value
        }

        #expect(await transport.pullCount == 3)
        #expect(await transport.pushCount == 2)
        #expect(coordinator.status == .idle)
    }

    // MARK: - Saved queries

    @Test("A saved query and its folder saved on the Mac reach the store")
    func pulledSavedQueryIsStored() async {
        let box = LibraryStateBox()
        let connectionId = UUID()
        let folder = SavedQueryFolder(name: "Reports", connectionId: connectionId)
        let query = SavedQuery(name: "One", query: "SELECT 1", keyword: "one", folderId: folder.id, connectionId: connectionId)
        let records = [SyncRecordMapper.toRecord(folder, zoneID: zoneID), SyncRecordMapper.toRecord(query, zoneID: zoneID)]
        let transport = FakeSyncTransport(remoteRecords: records, box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(box.savedQueries == SavedQueryContents(queries: [query], folders: [folder]))
    }

    @Test("A full upload sends every saved query except those the sample owns, even when one is marked")
    func sampleSavedQueriesStayOnTheDevice() async {
        let box = LibraryStateBox()
        let sample = DatabaseConnection(name: "Sample", type: .sqlite, database: "Chinook.sqlite", isSample: true)
        box.connections = [sample]
        let global = SavedQuery(name: "Global", query: "SELECT 1")
        let sampleQuery = SavedQuery(name: "Sample", query: "SELECT 2", connectionId: sample.id)
        let sampleFolder = SavedQueryFolder(name: "Sample", connectionId: sample.id)
        box.savedQueries = SavedQueryContents(queries: [global, sampleQuery], folders: [sampleFolder])
        metadata.zoneState = .removed
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        coordinator.setEnabled(true)
        #expect(metadata.dirtyIds(for: .favorite) == [global.id.uuidString])
        #expect(metadata.dirtyIds(for: .favoriteFolder).isEmpty)
        coordinator.markDirty(savedQueries: [sampleQuery.id], folders: [sampleFolder.id])
        await coordinator.sync()

        let pushed = await transport.pushedRecords.map(\.recordID.recordName)
        #expect(pushed == [SyncRecordMapper.recordID(type: .favorite, id: global.id.uuidString, in: zoneID).recordName])
    }

    @Test("A saved query and a folder deleted on iPhone are deleted in iCloud")
    func savedQueryDeletionsArePushed() async {
        let box = LibraryStateBox()
        let queryId = UUID()
        let folderId = UUID()
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDeleted(savedQueries: [queryId], folders: [folderId])

        await coordinator.sync()

        let deleted = Set(await transport.pushedDeletions.map(\.recordName))
        #expect(deleted == [
            SyncRecordMapper.recordID(type: .favorite, id: queryId.uuidString, in: zoneID).recordName,
            SyncRecordMapper.recordID(type: .favoriteFolder, id: folderId.uuidString, in: zoneID).recordName
        ])
        #expect(metadata.tombstones(for: .favorite).isEmpty)
        #expect(metadata.tombstones(for: .favoriteFolder).isEmpty)
    }

    @Test("An older pulled query takes a contested keyword, and the younger one here gives it up in iCloud too")
    func keywordContestReleasesTheYounger() async {
        let box = LibraryStateBox()
        let connectionId = UUID()
        let local = SavedQuery(name: "Local", query: "SELECT 1", keyword: "one", connectionId: connectionId)
        let remote = SavedQuery(
            name: "Remote",
            query: "SELECT 2",
            keyword: "one",
            connectionId: connectionId,
            createdAt: local.createdAt.addingTimeInterval(-3_600)
        )
        box.savedQueries = SavedQueryContents(queries: [local])
        let transport = FakeSyncTransport(remoteRecords: [SyncRecordMapper.toRecord(remote, zoneID: zoneID)], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        let stored = box.savedQueries ?? SavedQueryContents()
        #expect(stored.queries.count == 2)
        #expect(stored.query(remote.id)?.keyword == "one")
        #expect(stored.query(local.id)?.keyword == nil)
        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toSavedQuery)
        #expect(pushed.map(\.id) == [local.id])
        #expect(pushed.first?.keyword == nil)
    }

    @Test("A stale copy that still claims a keyword its query lost is corrected in iCloud, though nothing changes here")
    func staleKeywordClaimIsPushed() async {
        let box = LibraryStateBox()
        let connectionId = UUID()
        let holder = SavedQuery(
            name: "Holder",
            query: "SELECT 1",
            keyword: "one",
            connectionId: connectionId,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let loser = SavedQuery(
            name: "Loser",
            query: "SELECT 2",
            connectionId: connectionId,
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        var stale = loser
        stale.keyword = "one"
        box.savedQueries = SavedQueryContents(queries: [holder, loser])
        let transport = FakeSyncTransport(remoteRecords: [SyncRecordMapper.toRecord(stale, zoneID: zoneID)], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(box.savedQueries == SavedQueryContents(queries: [holder, loser]))
        let pushed = await transport.pushedRecords.compactMap(SyncRecordMapper.toSavedQuery)
        #expect(pushed.map(\.id) == [loser.id])
        #expect(pushed.first?.keyword == nil)
    }

    @Test("A query moved to the sample stays on the device when its old iCloud copy is deleted elsewhere")
    func sampleQueryOutlivesItsOldCopy() async {
        let box = LibraryStateBox()
        let sample = DatabaseConnection(name: "Sample", type: .sqlite, database: "Chinook.sqlite", isSample: true)
        box.connections = [sample]
        let query = SavedQuery(name: "Moved", query: "SELECT 1", connectionId: sample.id)
        box.savedQueries = SavedQueryContents(queries: [query])
        let deletion = SyncRecordMapper.recordID(type: .favorite, id: query.id.uuidString, in: zoneID)
        let transport = FakeSyncTransport(remoteRecords: [], box: box, remoteDeletions: [deletion])
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        #expect(box.savedQueries == SavedQueryContents(queries: [query]))
    }

    @Test("A folder deleted on the Mac moves what was inside it up a level")
    func remoteFolderDeletionMovesContentsUp() async {
        let box = LibraryStateBox()
        let parent = SavedQueryFolder(name: "Parent")
        let deleted = SavedQueryFolder(name: "Deleted", parentId: parent.id)
        let child = SavedQueryFolder(name: "Child", parentId: deleted.id)
        let query = SavedQuery(name: "Inside", query: "SELECT 1", folderId: deleted.id)
        box.savedQueries = SavedQueryContents(queries: [query], folders: [parent, deleted, child])
        let deletion = SyncRecordMapper.recordID(type: .favoriteFolder, id: deleted.id.uuidString, in: zoneID)
        let transport = FakeSyncTransport(remoteRecords: [], box: box, remoteDeletions: [deletion])
        let coordinator = makeCoordinator(box: box, transport: transport)

        await coordinator.sync()

        let contents = box.savedQueries ?? SavedQueryContents()
        #expect(contents.folders.map(\.id) == [parent.id, child.id])
        #expect(contents.folder(child.id)?.parentId == parent.id)
        #expect(contents.query(query.id)?.folderId == parent.id)
        #expect(await transport.pushedRecords.isEmpty)
    }

    @Test("A build that reads saved queries fetches everything once on a device that synced without them")
    func grownReadableSetFetchesEverythingOnce() async {
        let box = LibraryStateBox()
        metadata.lastAccountId = "account-a"
        _ = metadata.adoptReadableRecordTypes(["Connection", "ConnectionGroup", "ConnectionTag"])
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        let transport = FakeSyncTransport(remoteRecords: [], box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        var tokensDuringPull: [Data?] = []
        box.duringPull = { tokensDuringPull.append(metadata.userDefaults.data(forKey: tokenKey)) }

        await coordinator.sync()
        metadata.userDefaults.set(Data([1, 2, 3]), forKey: tokenKey)
        await coordinator.sync()

        #expect(tokensDuringPull == [nil, Data([1, 2, 3])])
    }

    @Test("A connection and a saved query deleted here are not brought back by a pull before their deletion goes up")
    func pendingDeletionsAreNotBroughtBack() async {
        let box = LibraryStateBox()
        let connection = DatabaseConnection(name: "Deleted", type: .mysql)
        let query = SavedQuery(name: "Deleted", query: "SELECT 1")
        let records = [SyncRecordMapper.toRecord(connection, zoneID: zoneID), SyncRecordMapper.toRecord(query, zoneID: zoneID)]
        let transport = FakeSyncTransport(remoteRecords: records, box: box)
        let coordinator = makeCoordinator(box: box, transport: transport)
        coordinator.markDeleted(connection.id)
        coordinator.markDeleted(savedQueries: [query.id])

        await coordinator.sync()

        #expect(box.connections.isEmpty)
        #expect(box.savedQueries?.queries.isEmpty == true)
        #expect(await transport.pushedDeletions.count == 2)
    }

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: ChangeTokenArchive.self)
        archiver.encode(ChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: archiver.encodedData
        )
        return try #require(token)
    }
}

/// `CKServerChangeToken` has no public initializer, so a test token is decoded from an archive
/// that names its class.
@objc(IOSSyncCoordinatorTestsChangeTokenArchive)
private final class ChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
