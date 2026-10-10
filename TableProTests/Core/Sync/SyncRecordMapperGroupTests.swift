import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncRecordMapperGroupTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeNestedGroup() -> ConnectionGroup {
        ConnectionGroup(name: "Prod", color: .red, iconName: "server.rack", parentId: UUID(), sortOrder: 3)
    }

    @Test("A group's icon, color, parent and order round-trip through the wire")
    func roundTrip() throws {
        let group = makeNestedGroup()

        let decoded = try #require(SyncRecordMapper.toGroup(SyncRecordMapper.toCKRecord(group, in: zoneID)))

        #expect(decoded == group)
    }

    @Test("Resetting a group to the folder names the icon key on a record built with no server copy")
    func resetIconNamesTheKeyOnAFreshRecord() {
        var group = makeNestedGroup()
        group.iconName = nil

        let record = SyncRecordMapper.toCKRecord(group, in: zoneID)

        #expect(record[ConnectionGroupSyncField.iconName.key] == nil)
        #expect(record.changedKeys().contains(ConnectionGroupSyncField.iconName.key))
        #expect(!record.allKeys().contains(ConnectionGroupSyncField.iconName.key))
    }

    @Test("Resetting a group to the folder clears the icon on the server's copy")
    func resetIconClearsTheBasedRecord() {
        var group = makeNestedGroup()
        let base = SyncRecordMapper.toCKRecord(group, in: zoneID)
        group.iconName = nil

        let updated = SyncRecordMapper.toCKRecord(group, in: zoneID, base: base)

        #expect(updated === base)
        #expect(updated[ConnectionGroupSyncField.iconName.key] == nil)
    }

    @Test("A group moved to the top level clears its parent on a fresh record and on the server's copy")
    func movingToTopLevelClearsParent() throws {
        var group = makeNestedGroup()
        let base = SyncRecordMapper.toCKRecord(group, in: zoneID)
        group.parentId = nil

        let fresh = SyncRecordMapper.toCKRecord(group, in: zoneID)
        let based = SyncRecordMapper.toCKRecord(group, in: zoneID, base: base)
        let decoded = try #require(SyncRecordMapper.toGroup(based))

        #expect(fresh.changedKeys().contains(ConnectionGroupSyncField.parentId.key))
        #expect(fresh[ConnectionGroupSyncField.parentId.key] == nil)
        #expect(based[ConnectionGroupSyncField.parentId.key] == nil)
        #expect(decoded.parentId == nil)
    }

    @Test("An icon this Mac cannot draw is kept, and a malformed one reads as the folder")
    func iconNamesAreNormalizedNotFiltered() throws {
        let record = SyncRecordMapper.toCKRecord(makeNestedGroup(), in: zoneID)

        record[ConnectionGroupSyncField.iconName.key] = "made.up.symbol" as CKRecordValue
        let undrawable = try #require(SyncRecordMapper.toGroup(record))

        record[ConnectionGroupSyncField.iconName.key] = "Folder Icon" as CKRecordValue
        let malformed = try #require(SyncRecordMapper.toGroup(record))

        #expect(undrawable.iconName == "made.up.symbol")
        #expect(malformed.iconName == nil)
    }

    @Test("A connection moved out of its group, or stripped of its tags, clears both on the server's copy")
    func leavingAGroupClearsMembershipOnTheBasedRecord() throws {
        var connection = DatabaseConnection(name: "Orders", type: .postgresql)
        connection.groupId = UUID()
        connection.tagIds = [UUID()]
        let base = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        connection.groupId = nil
        connection.tagIds = []

        let updated = SyncRecordMapper.toCKRecord(connection, in: zoneID, base: base)
        let decoded = try SyncRecordMapper.toConnection(updated)

        #expect(updated[ConnectionSyncField.groupId.key] == nil)
        #expect(updated[ConnectionSyncField.tagIds.key] == nil)
        #expect(updated[ConnectionSyncField.tagId.key] == nil)
        #expect(decoded.groupId == nil)
        #expect(decoded.tagIds.isEmpty)
    }
}

/// The group push merges into the server copy this Mac last saw, the way a connection push does,
/// so a field this Mac did not change is not restated over another device's newer value.
@MainActor
struct SyncGroupPushTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-group-push")
    }

    /// Shaped like a record the server returned: it holds only the keys that have values.
    private func cacheServerCopy(of group: ConnectionGroup) {
        var fields = [
            ConnectionGroupSyncField.groupId.key: group.id.uuidString,
            ConnectionGroupSyncField.name.key: group.name,
            ConnectionGroupSyncField.color.key: group.color.rawValue
        ]
        fields[ConnectionGroupSyncField.parentId.key] = group.parentId?.uuidString
        environment.recordCache.store([
            CloudKitRecordFixtures.serverRecord(type: .group, id: group.id.uuidString, in: Self.zoneID, fields: fields)
        ])
    }

    private func pushedGroupRecord(for group: ConnectionGroup) async throws -> CKRecord {
        let snapshot = SyncEditSnapshot(
            dirty: [SyncRecordIdentity(type: .group, id: group.id.uuidString)],
            generations: [:]
        )
        let boundary = SyncBoundary(
            settings: .default,
            connections: environment.connections.loadConnections(),
            writableTypes: Set(SyncRecordType.allCases)
        )
        let batch = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .collectPushBatch(snapshot: snapshot, boundary: boundary, zoneID: Self.zoneID)
        return try #require(batch.records.first { $0.recordType == SyncRecordType.group.rawValue })
    }

    @Test("A renamed group does not name the icon key the server copy never held")
    func renameLeavesUntouchedIconAlone() async throws {
        let original = ConnectionGroup(name: "Clients")
        cacheServerCopy(of: original)
        var renamed = original
        renamed.name = "Customers"
        try environment.groups.addGroup(renamed)

        let pushed = try await pushedGroupRecord(for: renamed)

        #expect(pushed[ConnectionGroupSyncField.name.key] as? String == "Customers")
        #expect(!pushed.changedKeys().contains(ConnectionGroupSyncField.iconName.key))
    }

    @Test("A group dragged to the top level pushes a cleared parent over the server copy")
    func topLevelMoveClearsCachedParent() async throws {
        let nested = ConnectionGroup(name: "Prod", parentId: UUID())
        cacheServerCopy(of: nested)
        var moved = nested
        moved.parentId = nil
        try environment.groups.addGroup(moved)

        let pushed = try await pushedGroupRecord(for: moved)

        #expect(pushed[ConnectionGroupSyncField.parentId.key] == nil)
        #expect(pushed.changedKeys().contains(ConnectionGroupSyncField.parentId.key))
    }
}
