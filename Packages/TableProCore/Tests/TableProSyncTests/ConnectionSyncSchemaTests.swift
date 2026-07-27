import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("Connection sync schema")
struct ConnectionSyncSchemaTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeFullyPopulatedConnection() -> DatabaseConnection {
        DatabaseConnection(
            id: UUID(),
            name: "Production",
            type: DatabaseType(rawValue: "PostgreSQL"),
            host: "db.example.com",
            port: 5432,
            username: "admin",
            database: "app",
            colorTag: "#FF0000",
            isReadOnly: true,
            safeModeLevel: .readOnly,
            queryTimeoutSeconds: 30,
            additionalFields: ["schema": "public"],
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.example.com"),
            sslEnabled: true,
            sslConfiguration: SSLConfiguration(),
            groupId: UUID(),
            tagIds: [UUID(), UUID()],
            sortOrder: 3
        )
    }

    @Test("an unverified field is never written to a record")
    func unverifiedFieldsAreNeverWritten() {
        let record = SyncRecordMapper.toRecord(makeFullyPopulatedConnection(), zoneID: zoneID)
        let written = Set(record.allKeys())
        let unverified = Set(ConnectionSyncField.allCases.filter { !$0.isWritable }.map(\.key))

        #expect(written.isDisjoint(with: unverified))
    }

    @Test("updateRecord never writes an unverified field either")
    func updateRecordSkipsUnverifiedFields() {
        let connection = makeFullyPopulatedConnection()
        let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)

        SyncRecordMapper.updateRecord(record, with: connection)

        let written = Set(record.allKeys())
        let unverified = Set(ConnectionSyncField.allCases.filter { !$0.isWritable }.map(\.key))

        #expect(written.isDisjoint(with: unverified))
    }

    @Test("every written key is declared in the schema")
    func everyWrittenKeyIsDeclared() {
        let record = SyncRecordMapper.toRecord(makeFullyPopulatedConnection(), zoneID: zoneID)

        #expect(Set(record.allKeys()).isSubset(of: ConnectionSyncField.declaredKeys))
    }

    @Test("isFavorite stays out of the wire until the production schema is verified")
    func isFavoriteIsNotWritten() {
        #expect(ConnectionSyncField.isFavorite.isWritable == false)
    }

    @Test("a colour tag is written to colorTag and never to the macOS color field")
    func colourTagDoesNotCollideWithMacColor() {
        var connection = makeFullyPopulatedConnection()
        connection.colorTag = "#00FF00"

        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)

        #expect(record[ConnectionSyncField.colorTag] as? String == "#00FF00")
        #expect(record[ConnectionSyncField.color] == nil)
    }

    @Test("a macOS colour name is not adopted as an iOS colour tag")
    func macColorNameIsNotDecodedAsColourTag() {
        let connection = makeFullyPopulatedConnection()
        let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)
        record[ConnectionSyncField.connectionId] = connection.id.uuidString as CKRecordValue
        record[ConnectionSyncField.name] = "From Mac" as CKRecordValue
        record[ConnectionSyncField.type] = "PostgreSQL" as CKRecordValue
        record[ConnectionSyncField.color] = "Blue" as CKRecordValue

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(decoded?.colorTag == nil)
    }

    @Test("a fully populated connection round-trips through the wire")
    func roundTripPreservesVerifiedFields() {
        let connection = makeFullyPopulatedConnection()
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(decoded?.id == connection.id)
        #expect(decoded?.name == connection.name)
        #expect(decoded?.host == connection.host)
        #expect(decoded?.port == connection.port)
        #expect(decoded?.database == connection.database)
        #expect(decoded?.username == connection.username)
        #expect(decoded?.sortOrder == connection.sortOrder)
        #expect(decoded?.isReadOnly == connection.isReadOnly)
        #expect(decoded?.safeModeLevel == connection.safeModeLevel)
        #expect(decoded?.groupId == connection.groupId)
        #expect(decoded?.colorTag == connection.colorTag)
    }

    @Test("A gated field does not survive the round trip")
    func gatedFieldsDoNotRoundTrip() {
        let connection = makeFullyPopulatedConnection()
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(connection.queryTimeoutSeconds != nil)
        #expect(ConnectionSyncField.queryTimeoutSeconds.isWritable == false)
        #expect(decoded?.queryTimeoutSeconds == nil)
    }
}
