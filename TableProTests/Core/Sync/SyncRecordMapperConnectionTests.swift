import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

struct SyncRecordMapperConnectionTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private static let writtenToRecord: Set<String> = [
        "id",
        "name",
        "host",
        "port",
        "database",
        "username",
        "type",
        "sshConfig",
        "sslConfig",
        "color",
        "tagIds",
        "groupId",
        "sshProfileId",
        "preferredSafeModeLevel",
        "aiPolicy",
        "aiRules",
        "aiAlwaysAllowedTools",
        "additionalFields",
        "redisDatabase",
        "startupCommands",
        "sortOrder",
        "isFavorite"
    ]

    private static let rebuiltFromRecord: Set<String> = ["sshTunnelMode"]

    private static let keptFromThisMac: Set<String> = [
        "localOnly",
        "isSample",
        "passwordSource",
        "credentialMode",
        "externalAccess",
        "cloudflareTunnelMode",
        "cloudSQLProxyMode",
        "socksProxyMode",
        "tunnelCommandMode"
    ]

    private static func storedValues(of connection: DatabaseConnection) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Mirror(reflecting: connection).children.compactMap { child in
            child.label.map { ($0, String(describing: child.value)) }
        })
    }

    private func makeFullyPopulatedConnection() -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Production")
        connection.host = "db.example.com"
        connection.port = 5_432
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

    private func makeConnectionWithDeviceLocalState() -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Warehouse",
            host: "db.example.com",
            port: 5_432,
            database: "app",
            username: "admin",
            type: .postgresql
        )
        connection.localOnly = true
        connection.isSample = true
        connection.passwordSource = .env(variable: "WAREHOUSE_PASSWORD")
        connection.credentialMode = .profile(id: UUID())
        connection.externalAccess = .blocked
        connection.cloudflareTunnelMode = .inline(CloudflareConfiguration(accessHostname: "db.access.example.com"))
        connection.cloudSQLProxyMode = .inline(
            CloudSQLProxyConfiguration(instanceConnectionName: "project:region:instance")
        )
        connection.socksProxyMode = .inline(
            SOCKSProxyConfiguration(host: "proxy.internal", port: 1_080, username: "relay")
        )
        connection.tunnelCommandMode = .inline(
            TunnelCommandConfiguration(kubernetesNamespace: "data", kubernetesResource: "svc/postgres")
        )
        return connection
    }

    @Test("A connection back from the wire is its local copy again once it adopts that copy's device-local state")
    func deviceLocalStateCompletesTheRoundTrip() throws {
        let local = makeConnectionWithDeviceLocalState()
        let decoded = try SyncRecordMapper.toConnection(SyncRecordMapper.toCKRecord(local, in: zoneID))

        #expect(decoded.adoptingDeviceLocalState(from: local) == local)
    }

    @Test("Adopting device-local state keeps every synced value another device sent")
    func adoptingDeviceLocalStateKeepsSyncedValues() throws {
        let local = makeConnectionWithDeviceLocalState()
        var remote = local
        remote.name = "Renamed"
        remote.host = "replica.example.com"
        remote.safeModeLevel = .readOnly
        let decoded = try SyncRecordMapper.toConnection(SyncRecordMapper.toCKRecord(remote, in: zoneID))

        #expect(decoded.adoptingDeviceLocalState(from: local) == remote)
    }

    @Test("Every stored connection property is written to the record, rebuilt from it, or kept from this Mac")
    func everyStoredPropertyIsClassified() {
        let stored = Set(Self.storedValues(of: DatabaseConnection(name: "")).keys)
        let classified = Self.writtenToRecord.union(Self.rebuiltFromRecord).union(Self.keptFromThisMac)
        let unclassified = stored.subtracting(classified)

        #expect(
            unclassified.isEmpty,
            """
            DatabaseConnection gained \(unclassified.sorted().joined(separator: ", ")).
            Write each one to the connection record and add it to writtenToRecord,
            or add it to keptFromThisMac and to adoptingDeviceLocalState(from:).
            An unclassified property is reset to its default by every pull that carries the connection.
            """
        )
        #expect(classified.subtracting(stored).isEmpty)
    }

    @Test("No connection property is both synced and kept from this Mac")
    func classificationsDoNotOverlap() {
        #expect(Self.writtenToRecord.isDisjoint(with: Self.rebuiltFromRecord))
        #expect(Self.writtenToRecord.isDisjoint(with: Self.keptFromThisMac))
        #expect(Self.rebuiltFromRecord.isDisjoint(with: Self.keptFromThisMac))
    }

    @Test("The round-trip fixture sets every device-local property away from its default")
    func roundTripFixtureCoversEveryDeviceLocalProperty() {
        let defaults = Self.storedValues(of: DatabaseConnection(name: ""))
        let fixture = Self.storedValues(of: makeConnectionWithDeviceLocalState())

        let leftAtDefault = Self.keptFromThisMac.filter { fixture[$0] == defaults[$0] }

        #expect(
            leftAtDefault.isEmpty,
            "Set \(leftAtDefault.sorted().joined(separator: ", ")) in makeConnectionWithDeviceLocalState()."
        )
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
        #expect(record["port"] as? Int64 == 5_432)
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

    @Test("A connection the engine holds at Read-Only syncs the user's own level")
    func enforcedReadOnlyIsNotSynced() {
        let connection = DatabaseConnection(name: "Iceberg", type: .cloudflareR2SQL, safeModeLevel: .alert)

        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)

        #expect(record["safeModeLevel"] as? String == SafeModeLevel.alert.rawValue)
        #expect(record["isReadOnly"] as? Int64 == 0)
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
