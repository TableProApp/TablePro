import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@MainActor
struct MongoURISecretMigrationTests {
    private let pool = EphemeralDefaultsPool()
    private let storage: ConnectionStorage
    private let keychain: InMemoryKeychain

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keychain = InMemoryKeychain()
        storage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: try pool.make().defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: try pool.make().defaults)),
            keychain: keychain,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
    }

    @Test("Saved connection-string secrets move to the Keychain and leave the record")
    func secretsMoveToTheKeychain() throws {
        var connection = TestFixtures.makeConnection(type: .mongodb)
        connection.additionalFields = [
            "mongoParam_tlsCertificateKeyFilePassword": "hunter2",
            "mongoParam_proxyPassword": "proxy-secret",
            "mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:FQoG",
            "mongoParam_retryWrites": "true"
        ]
        try #require(storage.addConnection(connection))

        storage.moveMongoURISecretsToKeychain()

        let stored = try #require(storage.loadConnections().first { $0.id == connection.id })
        #expect(stored.additionalFields == [
            "mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb",
            "mongoParam_retryWrites": "true"
        ])
        #expect(storage.loadSSLClientKeyPassphrase(for: connection.id) == "hunter2")
        #expect(storage.loadPluginSecureField(fieldId: "mongoAWSSessionToken", for: connection.id) == "FQoG")
    }

    @Test("A connection with no connection-string secret is left as it is")
    func ordinaryConnectionIsUntouched() throws {
        var connection = TestFixtures.makeConnection(type: .mongodb)
        connection.additionalFields = ["mongoParam_retryWrites": "true"]
        try #require(storage.addConnection(connection))

        storage.moveMongoURISecretsToKeychain()

        #expect(storage.loadConnections().first { $0.id == connection.id }?.additionalFields == connection.additionalFields)
        #expect(storage.loadSSLClientKeyPassphrase(for: connection.id) == nil)
    }

    @Test("A connection a sync brings in keeps its secrets in the Keychain, not in the record")
    func incomingConnectionKeepsSecretsInTheKeychain() {
        var incoming = TestFixtures.makeConnection(type: .mongodb)
        incoming.additionalFields = [
            "mongoParam_sslClientCertificateKeyPassword": "hunter2",
            "mongoAWSSessionToken": "FQoG",
            "mongoAuthSource": "admin"
        ]

        let kept = storage.keepingMongoURISecretsInKeychain(incoming)

        #expect(kept.additionalFields == ["mongoAuthSource": "admin"])
        #expect(storage.loadSSLClientKeyPassphrase(for: incoming.id) == "hunter2")
        #expect(storage.loadPluginSecureField(fieldId: "mongoAWSSessionToken", for: incoming.id) == "FQoG")
    }

    @Test("A stale copy a legacy record carries never replaces the Keychain's own")
    func keychainValueWins() {
        var incoming = TestFixtures.makeConnection(type: .mongodb)
        incoming.additionalFields = ["mongoParam_authMechanismProperties": "AWS_SESSION_TOKEN:stale"]
        storage.savePluginSecureField("current", fieldId: "mongoAWSSessionToken", for: incoming.id)

        let kept = storage.keepingMongoURISecretsInKeychain(incoming)

        #expect(kept.additionalFields.isEmpty)
        #expect(storage.loadPluginSecureField(fieldId: "mongoAWSSessionToken", for: incoming.id) == "current")
    }
}
