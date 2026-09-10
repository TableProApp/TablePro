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
            color: .red,
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

    @Test("every declared field is deployed, so nothing is silently dropped")
    func everyDeclaredFieldIsWritable() {
        let gated = ConnectionSyncField.allCases.filter { !$0.isWritable }

        #expect(gated.isEmpty, "Gated Connection fields: \(gated.map(\.key).sorted())")
    }

    @Test("a colour is written to the field macOS also reads")
    func colourIsWrittenToTheSharedField() {
        var connection = makeFullyPopulatedConnection()
        connection.color = .green

        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        let fields = record.fields(ConnectionSyncField.self)

        #expect(fields[.color] as? String == ConnectionColor.green.rawValue)
    }

    /// The two platforms used to sync a connection's colour on separate fields, macOS writing this
    /// enum's name to `color` and iOS writing hex to `colorTag`, so neither device ever showed the
    /// other's colour. A record written by macOS has to decode here now.
    @Test("a macOS colour name decodes")
    func macColorNameDecodes() {
        let connection = makeFullyPopulatedConnection()
        let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)
        let fields = record.fields(ConnectionSyncField.self)
        fields[.connectionId] = connection.id.uuidString
        fields[.name] = "From Mac"
        fields[.type] = "PostgreSQL"
        fields[.color] = "Blue"

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(decoded?.color == .blue)
    }

    /// Whatever an older iOS build already wrote as hex still has to come back as a colour.
    @Test("a legacy hex colour tag decodes to the nearest colour")
    func legacyColourTagDecodes() {
        let connection = makeFullyPopulatedConnection()
        let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)
        let fields = record.fields(ConnectionSyncField.self)
        fields[.connectionId] = connection.id.uuidString
        fields[.name] = "From an older iPhone"
        fields[.type] = "PostgreSQL"
        fields[.colorTag] = "#FF0000"

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(decoded?.color == .red)
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
        #expect(decoded?.color == connection.color)
    }

    @Test("a query timeout survives the round trip now that the field is deployed")
    func queryTimeoutRoundTrips() {
        let connection = makeFullyPopulatedConnection()
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(connection.queryTimeoutSeconds != nil)
        #expect(decoded?.queryTimeoutSeconds == connection.queryTimeoutSeconds)
    }

    @Test("every tag survives the round trip instead of collapsing to the first")
    func everyTagRoundTrips() {
        let connection = makeFullyPopulatedConnection()
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)

        let decoded = SyncRecordMapper.toConnection(record)

        #expect(connection.tagIds.count == 2)
        #expect(decoded?.tagIds == connection.tagIds)
    }
}
