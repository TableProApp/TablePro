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

    init(remoteRecords: [CKRecord], box: LibraryStateBox) {
        self.remoteRecords = remoteRecords
        self.box = box
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
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
            makeTransport: { transport }
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
}
