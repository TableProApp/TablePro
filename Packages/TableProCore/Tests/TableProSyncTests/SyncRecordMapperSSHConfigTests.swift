import CloudKit
import Foundation
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

@Suite("SyncRecordMapper SSH configuration")
struct SyncRecordMapperSSHConfigTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private let keyMarker = "b3BlbnNzaC1rZXktdjE"

    private func makeConnection(host: String = "bastion.example.com") -> DatabaseConnection {
        DatabaseConnection(
            name: "Tunnelled",
            type: .postgresql,
            host: "10.0.0.5",
            port: 5_432,
            username: "app",
            database: "prod",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(
                host: host,
                port: 22,
                username: "deploy",
                authMethod: .privateKey,
                privateKeyPath: "/keys/id_ed25519"
            )
        )
    }

    private func sshJSONObject(in record: CKRecord) throws -> [String: Any] {
        let data = try #require(record.fields(ConnectionSyncField.self)[.sshConfigJson] as? Data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("toRecord writes SSH settings without a private key field")
    func toRecordOmitsPrivateKey() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(), zoneID: zoneID)
        let json = try sshJSONObject(in: record)
        #expect(json["privateKeyData"] == nil)
        #expect(json["host"] as? String == "bastion.example.com")
        #expect(json["privateKeyPath"] as? String == "/keys/id_ed25519")
    }

    @Test("updateRecord writes SSH settings without a private key field")
    func updateRecordOmitsPrivateKey() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(), zoneID: zoneID)
        SyncRecordMapper.updateRecord(record, with: makeConnection(host: "jump.example.com"))
        let json = try sshJSONObject(in: record)
        #expect(json["privateKeyData"] == nil)
        #expect(json["host"] as? String == "jump.example.com")
    }

    @Test("A record carrying a private key maps to a connection that never encodes it")
    func incomingPrivateKeyIsDropped() throws {
        let record = SyncRecordMapper.toRecord(makeConnection(), zoneID: zoneID)
        let legacySSH = """
        {"host":"bastion.example.com","port":22,"username":"deploy","authMethod":"privateKey",
         "privateKeyData":"-----BEGIN OPENSSH PRIVATE KEY-----\\n\(keyMarker)\\n-----END OPENSSH PRIVATE KEY-----",
         "jumpHosts":[]}
        """
        record.fields(ConnectionSyncField.self)[.sshConfigJson] = Data(legacySSH.utf8) as CKRecordValue

        let connection = try #require(SyncRecordMapper.toConnection(record))
        #expect(connection.sshConfiguration?.host == "bastion.example.com")

        let encoded = try #require(String(data: JSONEncoder().encode(connection), encoding: .utf8))
        #expect(!encoded.contains("privateKeyData"))
        #expect(!encoded.contains(keyMarker))
    }
}
