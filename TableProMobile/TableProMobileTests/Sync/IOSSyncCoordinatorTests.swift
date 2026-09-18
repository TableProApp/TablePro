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
    var syncEnabled = true

    func runDuringPull() {
        duringPull()
    }

    func runDuringPush() {
        duringPush()
    }
}

private actor FakeSyncTransport: IOSSyncTransport {
    let currentZoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let remoteRecords: [CKRecord]
    private let box: LibraryStateBox
    private(set) var pushedRecords: [CKRecord] = []
    private(set) var pullCount = 0

    init(remoteRecords: [CKRecord], box: LibraryStateBox) {
        self.remoteRecords = remoteRecords
        self.box = box
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        await box.runDuringPull()
        return PullResult(changedRecords: remoteRecords, deletedRecordIDs: [], newToken: nil)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        pushedRecords.append(contentsOf: records)
        await box.runDuringPush()
        return PushOutcome(
            savedRecords: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) }),
            deletedRecordIDs: Set(deletions)
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

    private func makeCoordinator(box: LibraryStateBox, transport: FakeSyncTransport) -> IOSSyncCoordinator {
        let coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: cacheDirectory, defaults: nil),
            makeTransport: { transport },
            isEnabled: { box.syncEnabled }
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
}
