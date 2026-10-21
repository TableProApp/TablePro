import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("SyncRecordMapper safe mode")
struct SyncRecordMapperTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func makeConnection(safeModeLevel: SafeModeLevel, isReadOnly: Bool = false) -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "admin",
            database: "app",
            isReadOnly: isReadOnly,
            safeModeLevel: safeModeLevel
        )
    }

    private func makeRawRecord(safeModeLevelRaw: String?, isReadOnly: Bool? = nil) -> CKRecord {
        let id = SyncRecordMapper.recordID(type: .connection, id: UUID().uuidString, in: zoneID)
        let record = CKRecord(recordType: SyncRecordType.connection.rawValue, recordID: id)
        record["connectionId"] = UUID().uuidString as CKRecordValue
        record["name"] = "Test" as CKRecordValue
        record["type"] = DatabaseType.postgresql.rawValue as CKRecordValue
        if let safeModeLevelRaw {
            record["safeModeLevel"] = safeModeLevelRaw as CKRecordValue
        }
        if let isReadOnly {
            record["isReadOnly"] = Int64(isReadOnly ? 1 : 0) as CKRecordValue
        }
        return record
    }

    @Test("toRecord then toConnection preserves every safe mode level", arguments: SafeModeLevel.allCases)
    func roundTripsEachLevel(_ level: SafeModeLevel) throws {
        let record = SyncRecordMapper.toRecord(makeConnection(safeModeLevel: level), zoneID: zoneID)
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.safeModeLevel == level)
    }

    @Test("updateRecord carries the new safe mode level")
    func updateRecordPreservesLevel() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(safeModeLevel: .off), zoneID: zoneID)
        SyncRecordMapper.updateRecord(record, with: makeConnection(safeModeLevel: .confirmWrites))
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.safeModeLevel == .confirmWrites)
    }

    @Test("legacy record without safeModeLevel falls back to isReadOnly")
    func legacyFallback() throws {
        let readOnlyRecord = makeRawRecord(safeModeLevelRaw: nil, isReadOnly: true)
        let readOnly = try #require(SyncRecordMapper.toConnection(readOnlyRecord))
        #expect(readOnly.safeModeLevel == .readOnly)

        let writableRecord = makeRawRecord(safeModeLevelRaw: nil, isReadOnly: false)
        let writable = try #require(SyncRecordMapper.toConnection(writableRecord))
        #expect(writable.safeModeLevel == .off)
    }

    @Test(
        "macOS wire values map to the nearest iOS level",
        arguments: [
            ("silent", SafeModeLevel.off),
            ("alert", SafeModeLevel.confirmWrites),
            ("alertFull", SafeModeLevel.confirmWrites),
            ("safeMode", SafeModeLevel.confirmWrites),
            ("safeModeFull", SafeModeLevel.confirmWrites),
            ("readOnly", SafeModeLevel.readOnly)
        ]
    )
    func decodesMacOSWireValues(_ raw: String, _ expected: SafeModeLevel) throws {
        let decoded = try #require(SyncRecordMapper.toConnection(makeRawRecord(safeModeLevelRaw: raw)))
        #expect(decoded.safeModeLevel == expected)
    }

    @Test("An unrecognized wire value syncs as confirmWrites instead of off")
    func unknownWireValueFailsClosed() throws {
        let record = makeRawRecord(safeModeLevelRaw: "someFutureLevel")
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.safeModeLevel == .confirmWrites)
    }

    @Test("An unrecognized wire value keeps the legacy read-only restriction")
    func unknownWireValuePreservesReadOnly() throws {
        let record = makeRawRecord(safeModeLevelRaw: "someFutureLevel", isReadOnly: true)
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.safeModeLevel == .readOnly)
    }

    @Test("A rename preserves an unrecognized wire value and requires confirmation")
    func renamePreservesUnknownWireValue() throws {
        let record = makeRawRecord(safeModeLevelRaw: "someFutureLevel")
        var connection = try #require(SyncRecordMapper.toConnection(record))
        connection.name = "Renamed"

        SyncRecordMapper.updateRecord(record, with: connection)

        #expect(record["safeModeLevel"] as? String == "someFutureLevel")
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(decoded.name == "Renamed")
        #expect(decoded.safeModeLevel == .confirmWrites)
    }
}

struct SyncRecordMapperSSLTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let macPreferred = #"{"mode":"Preferred","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#

    private func makeRecord(sslJSON: String) -> CKRecord {
        let connection = DatabaseConnection(
            name: "Test",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "admin",
            database: "app",
            sslEnabled: true,
            sslConfiguration: SSLConfiguration(mode: .require)
        )
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        record.fields(ConnectionSyncField.self)[.sslConfigJson] = Data(sslJSON.utf8) as CKRecordValue
        return record
    }

    private func sslData(in record: CKRecord) throws -> Data {
        try #require(record.fields(ConnectionSyncField.self)[.sslConfigJson] as? Data)
    }

    private func sslJSONObject(in record: CKRecord) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: sslData(in: record)) as? [String: Any])
    }

    @Test("toRecord writes an SSL blob the Mac can decode")
    func toRecordWritesMacForm() throws {
        let connection = DatabaseConnection(
            name: "Test",
            type: .mysql,
            sslEnabled: true,
            sslConfiguration: SSLConfiguration(mode: .verifyFull)
        )
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        let data = try sslData(in: record)
        let json = try sslJSONObject(in: record)
        #expect(SSLConfiguration.isMacWireForm(data))
        #expect(json["mode"] as? String == "Verify Identity")
    }

    @Test("updateRecord keeps a Mac Preferred blob when SSL is unchanged")
    func keepsMacPreferredWhenUnchanged() throws {
        let record = makeRecord(sslJSON: macPreferred)
        var connection = try #require(SyncRecordMapper.toConnection(record))
        #expect(connection.sslConfiguration == SSLConfiguration(mode: .require, isMacPreferred: true))
        connection.name = "Renamed"

        SyncRecordMapper.updateRecord(record, with: connection)

        let data = try sslData(in: record)
        let decoded = try #require(SyncRecordMapper.toConnection(record))
        #expect(data == Data(macPreferred.utf8))
        #expect(decoded.name == "Renamed")
    }

    @Test("updateRecord keeps a Mac Preferred blob for a copy an older iOS build stored as require")
    func keepsMacPreferredForAnOlderLocalCopy() throws {
        let record = makeRecord(sslJSON: macPreferred)
        var connection = try #require(SyncRecordMapper.toConnection(record))
        connection.sslConfiguration = try JSONDecoder().decode(SSLConfiguration.self, from: Data(#"{"mode":"require"}"#.utf8))
        connection.name = "Renamed"

        SyncRecordMapper.updateRecord(record, with: connection)

        #expect(try sslData(in: record) == Data(macPreferred.utf8))
    }

    @Test("updateRecord writes an explicit Required over a server Preferred with the same paths")
    func explicitRequiredReplacesPreferred() throws {
        let record = makeRecord(sslJSON: macPreferred)
        var connection = try #require(SyncRecordMapper.toConnection(record))
        connection.sslConfiguration = SSLConfiguration(mode: .require)

        SyncRecordMapper.updateRecord(record, with: connection)

        #expect(try sslJSONObject(in: record)["mode"] as? String == "Required")
    }

    @Test("The server's SSL is read only from a blob the Mac can decode")
    func serverSSLNeedsMacForm() {
        #expect(SyncRecordMapper.serverSSL(in: makeRecord(sslJSON: macPreferred))?.isMacPreferred == true)
        #expect(SyncRecordMapper.serverSSL(in: makeRecord(sslJSON: #"{"mode":"require"}"#)) == nil)
    }

    @Test("updateRecord writes Preferred over a server Required")
    func writesPreferredOverRequired() throws {
        let record = makeRecord(sslJSON: #"{"mode":"Required","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#)
        var connection = try #require(SyncRecordMapper.toConnection(record))
        connection.sslConfiguration = SSLConfiguration(mode: .require, isMacPreferred: true)

        SyncRecordMapper.updateRecord(record, with: connection)

        #expect(try sslJSONObject(in: record)["mode"] as? String == "Preferred")
    }

    @Test("A Mac Preferred survives local storage and a rebuilt record")
    func macPreferredSurvivesRebuild() throws {
        let fetched = try #require(SyncRecordMapper.toConnection(makeRecord(sslJSON: macPreferred)))
        let stored = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(fetched))

        let rebuilt = SyncRecordMapper.toRecord(stored, zoneID: zoneID)

        #expect(stored.sslConfiguration?.mode == .require)
        #expect(try sslJSONObject(in: rebuilt)["mode"] as? String == "Preferred")
    }

    @Test("updateRecord writes Verify CA when SSL changed")
    func writesVerifyCaWhenChanged() throws {
        let record = makeRecord(sslJSON: macPreferred)
        var connection = try #require(SyncRecordMapper.toConnection(record))
        connection.sslConfiguration?.mode = .verifyCa

        SyncRecordMapper.updateRecord(record, with: connection)

        let data = try sslData(in: record)
        let json = try sslJSONObject(in: record)
        #expect(SSLConfiguration.isMacWireForm(data))
        #expect(json["mode"] as? String == "Verify CA")
    }

    @Test("updateRecord rewrites a blob an older iOS build wrote, even with SSL unchanged")
    func rewritesOlderIOSBlob() throws {
        let record = makeRecord(sslJSON: #"{"mode":"require"}"#)
        let connection = try #require(SyncRecordMapper.toConnection(record))
        #expect(connection.sslConfiguration?.mode == .require)
        #expect(connection.sslConfiguration?.isLegacyRequire == true)

        SyncRecordMapper.updateRecord(record, with: connection)

        let data = try sslData(in: record)
        let json = try sslJSONObject(in: record)
        #expect(json["mode"] as? String == "Required")
        #expect(Set(json.keys) == ["mode", "caCertificatePath", "clientCertificatePath", "clientKeyPath"])
        #expect(json["caCertificatePath"] as? String == "")
        #expect(SSLConfiguration.isMacWireForm(data))
    }
}
