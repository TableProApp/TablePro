import CloudKit
import Foundation
import TableProSSHTransport
import Testing

@testable import TableProModels
@testable import TableProSync
@testable import TableProSyncTransport

struct SyncRecordMapperSSHRouteTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func tunnelled(ssh: SSHConfiguration? = SSHConfiguration(host: "db", username: "")) -> DatabaseConnection {
        DatabaseConnection(name: "Alias", type: .postgresql, host: "127.0.0.1", port: 5_432, sshEnabled: ssh != nil, sshConfiguration: ssh)
    }

    private func route(for connection: DatabaseConnection) throws -> PublishedSSHRoute {
        PublishedSSHRoute(
            publisher: UUID(),
            input: try #require(connection.sshConfiguration).publishedRouteInput,
            hops: [.init(id: UUID(), alias: "bastion", host: "b.example", port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )
    }

    @Test("A pulled record brings the Mac's route and SSH profile link")
    func pullReadsRouteAndProfile() throws {
        let connection = tunnelled()
        let published = try route(for: connection)
        let profileId = UUID()
        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        record[ConnectionSyncField.sshRouteJson.key] = try #require(published.encoded()) as CKRecordValue
        record[ConnectionSyncField.sshProfileId.key] = profileId.uuidString as CKRecordValue

        let pulled = try #require(SyncRecordMapper.toConnection(record))
        #expect(pulled.sshRoute == published)
        #expect(pulled.sshProfileId == profileId)
    }

    @Test("This device never writes the route; only the Mac that dialed it does")
    func iosNeverWritesRoute() throws {
        var connection = tunnelled()
        connection.sshRoute = try route(for: connection)

        let fresh = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        #expect(fresh[ConnectionSyncField.sshRouteJson.key] == nil)
        #expect(!fresh.changedKeys().contains(ConnectionSyncField.sshRouteJson.key))
    }

    @Test("A record built from scratch keeps the SSH profile link this copy knows of")
    func freshRecordKeepsTheProfileLink() {
        var connection = tunnelled()
        connection.sshProfileId = UUID()

        let record = SyncRecordMapper.toRecord(connection, zoneID: zoneID)
        #expect(record[ConnectionSyncField.sshProfileId.key] as? String == connection.sshProfileId?.uuidString)
    }

    @Test("Turning the tunnel off here drops the Mac's SSH profile link")
    func tunnelOffClearsProfileLink() throws {
        let base = SyncRecordMapper.toRecord(tunnelled(), zoneID: zoneID)
        base[ConnectionSyncField.sshProfileId.key] = UUID().uuidString as CKRecordValue
        var off = try #require(SyncRecordMapper.toConnection(base))
        off.sshEnabled = false
        off.sshConfiguration = nil

        SyncRecordMapper.updateRecord(base, with: off)
        #expect(base[ConnectionSyncField.sshProfileId.key] == nil)
    }

    @Test("A tunnel kept but switched off drops the link as well")
    func switchedOffTunnelClearsProfileLink() throws {
        let base = SyncRecordMapper.toRecord(tunnelled(), zoneID: zoneID)
        base[ConnectionSyncField.sshProfileId.key] = UUID().uuidString as CKRecordValue
        var off = try #require(SyncRecordMapper.toConnection(base))
        off.sshEnabled = false
        off.sshConfiguration?.macEnabled = false

        SyncRecordMapper.updateRecord(base, with: off)
        #expect(base[ConnectionSyncField.sshProfileId.key] == nil)
    }

    @Test("A tunnel switched off and on again before it synced still drops the link")
    func unlinkSurvivesTurningTheTunnelBackOn() throws {
        let base = SyncRecordMapper.toRecord(tunnelled(), zoneID: zoneID)
        base[ConnectionSyncField.sshProfileId.key] = UUID().uuidString as CKRecordValue
        var relinked = try #require(SyncRecordMapper.toConnection(base))
        relinked.sshProfileId = nil
        relinked.clearsSSHProfileLink = true
        relinked.sshConfiguration?.host = "other.example"

        SyncRecordMapper.updateRecord(base, with: relinked)
        #expect(base[ConnectionSyncField.sshProfileId.key] == nil)
    }

    @Test("An edit with the tunnel on leaves a link this copy never read")
    func tunnelOnKeepsProfileLink() throws {
        let profileId = UUID().uuidString
        let base = SyncRecordMapper.toRecord(tunnelled(), zoneID: zoneID)
        base[ConnectionSyncField.sshProfileId.key] = profileId as CKRecordValue
        var renamed = tunnelled()
        renamed.id = try #require(SyncRecordMapper.toConnection(base)).id
        renamed.name = "Renamed"

        SyncRecordMapper.updateRecord(base, with: renamed)
        #expect(base[ConnectionSyncField.sshProfileId.key] as? String == profileId)
    }
}
