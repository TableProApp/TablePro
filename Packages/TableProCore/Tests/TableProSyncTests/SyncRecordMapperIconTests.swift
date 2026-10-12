import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("SyncRecordMapper icons and group placement")
struct SyncRecordMapperIconTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeConnection(iconName: String?) -> DatabaseConnection {
        DatabaseConnection(
            name: "Production",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            color: .red,
            iconName: iconName
        )
    }

    private func connectionIcon(in record: CKRecord) -> Any? {
        record.fields(ConnectionSyncField.self)[.iconName]
    }

    private func groupFields(_ record: CKRecord) -> SyncRecordFields<ConnectionGroupSyncField> {
        record.fields(ConnectionGroupSyncField.self)
    }

    // MARK: - Connection

    @Test("A connection icon survives a push and a pull")
    func connectionIconRoundTrips() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: "server.rack"), zoneID: zoneID)

        let decoded = try #require(SyncRecordMapper.toConnection(record))

        #expect(connectionIcon(in: record) as? String == "server.rack")
        #expect(decoded.iconName == "server.rack")
        #expect(decoded.color == .red)
    }

    /// A connection whose cached record is gone is pushed through `toRecord` too, so a field the
    /// user emptied has to be named there or the server keeps the old value.
    @Test("A new record names every emptied field so the server clears it")
    func newConnectionRecordNamesEmptiedFields() {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: nil), zoneID: zoneID)
        let changed = record.changedKeys()

        #expect(connectionIcon(in: record) == nil)
        for field in [ConnectionSyncField.iconName, .groupId, .tagIds, .tagId, .queryTimeoutSeconds, .additionalFieldsJson] {
            #expect(changed.contains(field.key), "\(field.key) should be named")
        }
    }

    @Test("An update writes a newly picked icon onto the cached record")
    func updateWritesIcon() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: nil), zoneID: zoneID)

        SyncRecordMapper.updateRecord(record, with: makeConnection(iconName: "flame"))

        #expect(connectionIcon(in: record) as? String == "flame")
        #expect(try #require(SyncRecordMapper.toConnection(record)).iconName == "flame")
    }

    @Test("Resetting a connection icon clears it on the cached record")
    func updateClearsIcon() {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: "flame"), zoneID: zoneID)

        SyncRecordMapper.updateRecord(record, with: makeConnection(iconName: nil))

        #expect(connectionIcon(in: record) == nil)
        #expect(record.changedKeys().contains(ConnectionSyncField.iconName.key))
    }

    /// A newer release can offer a symbol this one does not draw. Dropping it on read would have the
    /// next edit here clear it for every device.
    @Test("A well-formed icon this release does not know is kept through a pull and an edit")
    func unknownIconSurvivesAnEdit() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: "made.up.symbol"), zoneID: zoneID)
        var pulled = try #require(SyncRecordMapper.toConnection(record))
        pulled.name = "Renamed"

        SyncRecordMapper.updateRecord(record, with: pulled)

        #expect(pulled.iconName == "made.up.symbol")
        #expect(connectionIcon(in: record) as? String == "made.up.symbol")
    }

    @Test("An icon value that is not shaped like a symbol name reads as no icon")
    func junkIconReadsAsNil() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: nil), zoneID: zoneID)
        record.fields(ConnectionSyncField.self)[.iconName] = "../Server Rack"

        #expect(try #require(SyncRecordMapper.toConnection(record)).iconName == nil)
    }

    @Test("A connection pushed with a junk icon writes no icon")
    func junkIconIsNotPushed() {
        let record = SyncRecordMapper.toRecord(makeConnection(iconName: "  "), zoneID: zoneID)

        #expect(connectionIcon(in: record) == nil)
    }

    // MARK: - Group

    @Test("A group icon survives a push and a pull")
    func groupIconRoundTrips() throws {
        let parentId = UUID()
        let group = ConnectionGroup(name: "Clients", sortOrder: 2, color: .blue, iconName: "briefcase", parentId: parentId)

        let decoded = try #require(SyncRecordMapper.toGroup(SyncRecordMapper.toRecord(group, zoneID: zoneID)))

        #expect(decoded == group)
    }

    @Test("A group record written before icons existed reads with no icon")
    func olderGroupRecordReadsWithoutIcon() throws {
        let id = UUID()
        let recordID = SyncRecordMapper.recordID(type: .group, id: id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.group.rawValue, recordID: recordID)
        let fields = groupFields(record)
        fields[.groupId] = id.uuidString
        fields[.name] = "Clients"

        let decoded = try #require(SyncRecordMapper.toGroup(record))

        #expect(decoded.iconName == nil)
        #expect(decoded.color == .none)
    }

    /// A new group record is the whole group, and the server keeps any key a `.changedKeys` push
    /// does not name. So a group reset to the folder has to name the key, or the old icon returns.
    @Test("A group with no icon names the icon key on a new record so the server clears it")
    func newGroupRecordClearsIcon() {
        let record = SyncRecordMapper.toRecord(ConnectionGroup(name: "Clients"), zoneID: zoneID)

        #expect(record.changedKeys().contains(ConnectionGroupSyncField.iconName.key))
        #expect(record.allKeys().contains(ConnectionGroupSyncField.iconName.key) == false)
    }

    @Test("A group at the top level names the parent key on a new record so the server clears it")
    func newGroupRecordClearsParent() {
        let record = SyncRecordMapper.toRecord(ConnectionGroup(name: "Clients", parentId: nil), zoneID: zoneID)

        #expect(record.changedKeys().contains(ConnectionGroupSyncField.parentId.key))
        #expect(record.allKeys().contains(ConnectionGroupSyncField.parentId.key) == false)
    }

    @Test("A group update writes, then clears, its icon and parent on the cached record")
    func groupUpdateWritesAndClears() throws {
        let parentId = UUID()
        var group = ConnectionGroup(name: "Clients", iconName: nil, parentId: nil)
        let record = SyncRecordMapper.toRecord(group, zoneID: zoneID)

        group.iconName = "person.3"
        group.parentId = parentId
        SyncRecordMapper.updateRecord(record, with: group)
        #expect(groupFields(record)[.iconName] as? String == "person.3")
        #expect(try #require(SyncRecordMapper.toGroup(record)).parentId == parentId)

        group.iconName = nil
        group.parentId = nil
        SyncRecordMapper.updateRecord(record, with: group)
        #expect(groupFields(record)[.iconName] == nil)
        #expect(groupFields(record)[.parentId] == nil)
        #expect(try #require(SyncRecordMapper.toGroup(record)).iconName == nil)
    }

    @Test("A group icon value that is not shaped like a symbol name reads as no icon")
    func junkGroupIconReadsAsNil() throws {
        let record = SyncRecordMapper.toRecord(ConnectionGroup(name: "Clients"), zoneID: zoneID)
        groupFields(record)[.iconName] = "Folder Fill"

        #expect(try #require(SyncRecordMapper.toGroup(record)).iconName == nil)
    }
}
