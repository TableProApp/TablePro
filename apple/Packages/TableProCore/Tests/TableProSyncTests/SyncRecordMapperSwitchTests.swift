import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

struct SyncRecordMapperSwitchTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let macRequired = #"{"mode":"Required","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#

    private func tunnelled(sshEnabled: Bool, macEnabled: Bool? = nil) -> DatabaseConnection {
        var ssh = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        ssh.macEnabled = macEnabled
        return DatabaseConnection(
            name: "Tunnelled",
            type: .postgresql,
            host: "10.0.0.5",
            port: 5_432,
            sshEnabled: sshEnabled,
            sshConfiguration: ssh
        )
    }

    private func fields(_ record: CKRecord) -> SyncRecordFields<ConnectionSyncField> {
        record.fields(ConnectionSyncField.self)
    }

    private func sshJSONObject(in record: CKRecord) throws -> [String: Any] {
        let data = try #require(fields(record)[.sshConfigJson] as? Data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // The Mac writes `enabled` inside the configuration and never touches the top-level field iOS wrote.
    private func macEdit(_ record: CKRecord, enabled: Bool) throws {
        var json = try sshJSONObject(in: record)
        json["enabled"] = enabled
        fields(record)[.sshConfigJson] = try JSONSerialization.data(withJSONObject: json) as CKRecordValue
    }

    @Test("A tunnel the Mac switches after iOS wrote the top-level field reads as the Mac set it", arguments: [true, false])
    func macTunnelSwitchWins(_ macEnabled: Bool) throws {
        let record = SyncRecordMapper.toRecord(tunnelled(sshEnabled: !macEnabled), zoneID: zoneID)
        try macEdit(record, enabled: macEnabled)

        let connection = try #require(SyncRecordMapper.toConnection(record))

        #expect(connection.sshEnabled == macEnabled)
    }

    @Test("Every record iOS writes carries the tunnel switch for the Mac", arguments: [true, false])
    func recordCarriesTheSwitch(_ enabled: Bool) throws {
        let built = SyncRecordMapper.toRecord(tunnelled(sshEnabled: enabled), zoneID: zoneID)
        #expect(try sshJSONObject(in: built)["enabled"] as? Bool == enabled)
        #expect(fields(built)[.sshEnabled] as? Int64 == (enabled ? 1 : 0))

        let updated = SyncRecordMapper.toRecord(tunnelled(sshEnabled: !enabled, macEnabled: !enabled), zoneID: zoneID)
        SyncRecordMapper.updateRecord(updated, with: tunnelled(sshEnabled: enabled, macEnabled: !enabled))
        #expect(try sshJSONObject(in: updated)["enabled"] as? Bool == enabled)
    }

    @Test("A record an older iOS build wrote, with only the top-level switch, keeps it")
    func olderRecordKeepsTopLevelSwitch() throws {
        let record = SyncRecordMapper.toRecord(tunnelled(sshEnabled: false), zoneID: zoneID)
        var json = try sshJSONObject(in: record)
        json.removeValue(forKey: "enabled")
        fields(record)[.sshConfigJson] = try JSONSerialization.data(withJSONObject: json) as CKRecordValue

        #expect(try #require(SyncRecordMapper.toConnection(record)).sshEnabled == false)
    }

    @Test("A Mac SSL mode reads as on without the top-level field the Mac never writes")
    func macSSLModeReadsOn() throws {
        let record = SyncRecordMapper.toRecord(DatabaseConnection(name: "Orders", type: .mysql), zoneID: zoneID)
        fields(record)[.sslEnabled] = nil
        fields(record)[.sslConfigJson] = Data(macRequired.utf8) as CKRecordValue

        let connection = try #require(SyncRecordMapper.toConnection(record))

        #expect(connection.sslEnabled)
        #expect(connection.sslConfiguration?.mode == .require)
    }

    @Test("A Redis index the Mac keeps only in its own field opens the same database")
    func macRedisIndexIsRead() throws {
        let record = SyncRecordMapper.toRecord(DatabaseConnection(name: "Cache", type: .redis, port: 6_379), zoneID: zoneID)
        fields(record)[.redisDatabase] = Int64(3) as CKRecordValue

        let connection = try #require(SyncRecordMapper.toConnection(record))

        #expect(connection.additionalFields["redisDatabase"] == "3")
    }

    @Test("A Redis index in the additional fields wins over the Mac's own field")
    func additionalRedisIndexWins() throws {
        let stored = DatabaseConnection(name: "Cache", type: .redis, port: 6_379, additionalFields: ["redisDatabase": "5"])
        let record = SyncRecordMapper.toRecord(stored, zoneID: zoneID)
        fields(record)[.redisDatabase] = Int64(3) as CKRecordValue

        #expect(try #require(SyncRecordMapper.toConnection(record)).additionalFields["redisDatabase"] == "5")
    }
}
