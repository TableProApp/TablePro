import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncRemoteConnectionSecretsTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-remote-connection-secrets")
    }

    private var storage: ConnectionStorage { environment.connections }

    private func secretKeys(of id: UUID) -> [String] {
        [
            "password", "sshpassword", "keypassphrase", "totpsecret", "cloudflaretokensecret",
            "cloudsqlproxyserviceaccountkey", "socksproxypassword", "plugin.mongoAWSSessionToken"
        ].map { "com.TablePro.\($0).\(id.uuidString)" }
    }

    private func addConnectionWithSecrets(localOnly: Bool = false) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(type: .mongodb)
        connection.localOnly = localOnly
        #expect(storage.addConnection(connection, password: "hunter2"))
        storage.saveSSHPassword("ssh", for: connection.id)
        storage.saveKeyPassphrase("passphrase", for: connection.id)
        storage.saveTOTPSecret("JBSWY3DP", for: connection.id)
        storage.saveCloudflareTokenSecret("cf", for: connection.id)
        storage.saveCloudSQLProxyServiceAccountKey("{}", for: connection.id)
        storage.saveSOCKSProxyPassword("proxy", for: connection.id)
        storage.savePluginSecureField("FQoG", fieldId: "mongoAWSSessionToken", for: connection.id)
        return connection
    }

    private func deletion(of connection: DatabaseConnection) -> PullResult {
        PullResult(
            changedRecords: [],
            deletedRecordIDs: [SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: Self.zoneID)],
            newToken: nil
        )
    }

    @Test("A connection deleted on another device takes its secrets out of this Mac's Keychain")
    func remoteDeletionRemovesTheSecrets() async {
        let connection = addConnectionWithSecrets()

        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(deletion(of: connection))

        #expect(acknowledged)
        #expect(storage.loadConnection(id: connection.id) == nil)
        for key in secretKeys(of: connection.id) {
            #expect(environment.keychain.readStringResult(forKey: key) == .notFound, "\(key)")
        }
    }

    @Test("A Local only connection named by a deletion from another device keeps its row and its secrets")
    func localOnlyConnectionKeepsItsSecrets() async {
        let connection = addConnectionWithSecrets(localOnly: true)

        let acknowledged = await environment.makeCoordinator(transport: ScriptedSyncTransport(zoneID: Self.zoneID))
            .applyPullResult(deletion(of: connection))

        #expect(acknowledged)
        #expect(storage.loadConnection(id: connection.id) != nil)
        for key in secretKeys(of: connection.id) {
            #expect(environment.keychain.readStringResult(forKey: key) != .notFound, "\(key)")
        }
    }
}
