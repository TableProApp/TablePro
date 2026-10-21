import CloudKit
import Foundation
@testable import TablePro
@testable import TableProSSHConfig
import TableProSSHTransport
import TableProSyncTransport
import Testing

struct SSHRouteSyncRecordTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func route() -> PublishedSSHRoute {
        PublishedSSHRoute(
            publisher: UUID(),
            input: .init(host: "db", port: nil, username: "", jumpHosts: []),
            hops: [.init(id: UUID(), alias: "bastion", host: "b.example", port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )
    }

    // CloudKit refuses a whole record that names a field Production lacks, and the Connection record has no route yet.
    @Test("The route stays on this Mac, off the record")
    func routeStaysOffTheRecord() {
        var connection = DatabaseConnection(name: "Alias")
        connection.sshRoute = route()

        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        #expect(!Set(record.allKeys()).contains("sshRouteJson"))
        #expect(ConnectionSyncField(rawValue: "sshRouteJson") == nil)
    }

    @Test("A profile's emptied port and jump hosts are cleared on the server")
    func profileClearsEmptiedFields() {
        let record = SyncRecordMapper.toCKRecord(SSHProfile(name: "Bastion", host: "b.example"), in: zoneID)
        let changed = Set(record.changedKeys())

        #expect(changed.contains(SSHProfileSyncField.port.key))
        #expect(changed.contains(SSHProfileSyncField.jumpHostsJson.key))
        #expect(record[SSHProfileSyncField.port.key] == nil)
        #expect(record[SSHProfileSyncField.jumpHostsJson.key] == nil)
    }

    @Test("A credential profile's emptied secure field list is cleared on the server")
    func credentialProfileClearsSecureFields() {
        let record = SyncRecordMapper.toCKRecord(CredentialProfile(name: "Shared", username: "app"), in: zoneID)

        #expect(Set(record.changedKeys()).contains(CredentialProfileSyncField.secureFieldIdsJson.key))
    }
}
