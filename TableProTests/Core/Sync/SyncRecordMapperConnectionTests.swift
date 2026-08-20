import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@Suite("SyncRecordMapper connection wire schema")
struct SyncRecordMapperConnectionTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeFullyPopulatedConnection() -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Production")
        connection.host = "db.example.com"
        connection.port = 5432
        connection.database = "app"
        connection.username = "admin"
        connection.type = .postgresql
        connection.color = .blue
        connection.tagIds = [UUID(), UUID()]
        connection.groupId = UUID()
        connection.sshProfileId = UUID()
        connection.safeModeLevel = .alertFull
        connection.aiPolicy = .askEachTime
        connection.aiRules = "Never drop tables"
        connection.aiAlwaysAllowedTools = ["listTables"]
        connection.redisDatabase = 3
        connection.startupCommands = "SET search_path TO public"
        connection.sortOrder = 7
        connection.isFavorite = true
        connection.additionalFields = ["schema": "public"]
        return connection
    }

    @Test("An unverified field is never written to a record")
    func unverifiedFieldsAreNeverWritten() {
        let record = SyncRecordMapper.toCKRecord(makeFullyPopulatedConnection(), in: zoneID)
        let unverified = Set(ConnectionSyncField.allCases.filter { !$0.isWritable }.map(\.key))

        #expect(Set(record.allKeys()).isDisjoint(with: unverified))
    }

    @Test("Every written key is declared in the shared schema")
    func everyWrittenKeyIsDeclared() {
        let record = SyncRecordMapper.toCKRecord(makeFullyPopulatedConnection(), in: zoneID)

        #expect(Set(record.allKeys()).isSubset(of: ConnectionSyncField.declaredKeys))
    }

    @Test("isFavorite reaches the wire and round-trips now that the field is deployed")
    func favoriteRoundTrips() throws {
        var connection = DatabaseConnection(name: "Local")
        connection.isFavorite = true

        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)

        #expect(record["isFavorite"] as? Int64 == 1)
        #expect(try SyncRecordMapper.toConnection(record).isFavorite)
    }

    @Test("A verified field still reaches the wire")
    func verifiedFieldsAreWritten() {
        let record = SyncRecordMapper.toCKRecord(makeFullyPopulatedConnection(), in: zoneID)

        #expect(record["name"] as? String == "Production")
        #expect(record["host"] as? String == "db.example.com")
        #expect(record["port"] as? Int64 == 5432)
        #expect(record["startupCommands"] as? String == "SET search_path TO public")
    }

    @Test("A fully populated connection round-trips through the wire")
    func roundTripPreservesVerifiedFields() throws {
        let connection = makeFullyPopulatedConnection()
        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)

        let decoded = try SyncRecordMapper.toConnection(record)

        #expect(decoded.id == connection.id)
        #expect(decoded.name == connection.name)
        #expect(decoded.host == connection.host)
        #expect(decoded.port == connection.port)
        #expect(decoded.database == connection.database)
        #expect(decoded.username == connection.username)
        #expect(decoded.type == connection.type)
        #expect(decoded.color == connection.color)
        #expect(decoded.groupId == connection.groupId)
        #expect(decoded.sshProfileId == connection.sshProfileId)
        #expect(decoded.safeModeLevel == connection.safeModeLevel)
        #expect(decoded.redisDatabase == connection.redisDatabase)
        #expect(decoded.startupCommands == connection.startupCommands)
        #expect(decoded.sortOrder == connection.sortOrder)
    }

    @Test(
        "iOS safe mode wire values map to the nearest macOS level",
        arguments: [
            ("off", SafeModeLevel.silent),
            ("confirmWrites", SafeModeLevel.alert),
            ("readOnly", SafeModeLevel.readOnly)
        ]
    )
    func decodesIOSWireValues(raw: String, expected: SafeModeLevel) {
        #expect(SyncRecordMapper.safeModeLevel(fromWire: raw, isReadOnly: false) == expected)
    }

    @Test("An unrecognised safe mode value requires confirmation instead of failing open")
    func unknownSafeModeFailsClosed() {
        #expect(SyncRecordMapper.safeModeLevel(fromWire: "someFutureLevel", isReadOnly: false) == .alert)
        #expect(SyncRecordMapper.safeModeLevel(fromWire: "someFutureLevel", isReadOnly: true) == .readOnly)
    }

    @Test("A record without a safe mode level honours the read-only flag")
    func missingSafeModeHonoursReadOnly() {
        #expect(SyncRecordMapper.safeModeLevel(fromWire: nil, isReadOnly: true) == .readOnly)
        #expect(SyncRecordMapper.safeModeLevel(fromWire: nil, isReadOnly: false) == .silent)
    }

    @Test("An iOS read-only connection stays read-only on macOS")
    func readOnlyConnectionFromIOSKeepsProtection() throws {
        let recordID = SyncRecordMapper.recordID(type: .connection, id: UUID().uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: recordID)
        record["connectionId"] = UUID().uuidString as CKRecordValue
        record["name"] = "From iPhone" as CKRecordValue
        record["type"] = "PostgreSQL" as CKRecordValue
        record["isReadOnly"] = Int64(1) as CKRecordValue

        let decoded = try SyncRecordMapper.toConnection(record)

        #expect(decoded.safeModeLevel == .readOnly)
    }
}
