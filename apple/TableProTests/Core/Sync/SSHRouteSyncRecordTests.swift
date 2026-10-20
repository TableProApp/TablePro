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

    @Test("A pulled record brings the route another Mac published")
    func pullReadsRoute() throws {
        let published = route()
        let record = SyncRecordMapper.toCKRecord(DatabaseConnection(name: "Alias"), in: zoneID)
        record[ConnectionSyncField.sshRouteJson.key] = try #require(published.encoded()) as CKRecordValue

        #expect(try SyncRecordMapper.toConnection(record).sshRoute == published)
    }

    @Test("The route stays off the wire until Production has the field")
    func routeIsWithheldUntilDeployed() {
        var connection = DatabaseConnection(name: "Alias")
        connection.sshRoute = route()

        let record = SyncRecordMapper.toCKRecord(connection, in: zoneID)
        #expect(!ConnectionSyncField.sshRouteJson.isWritable)
        #expect(record[ConnectionSyncField.sshRouteJson.key] == nil)
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
