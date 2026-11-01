import Foundation
import TableProModels
import Testing

@testable import TableProMobile

struct MongoURISecretKeychainMoveTests {
    @Test("A synced MongoDB row's connection-string secrets move to the Keychain under the Mac's names")
    func secretsMoveToTheKeychain() throws {
        let connection = DatabaseConnection(
            name: "Docs",
            type: .mongodb,
            host: "db.example.com",
            port: 27_017,
            additionalFields: [
                "mongoParam_tlsCertificateKeyFilePassword": "hunter2",
                "mongoParam_proxyPassword": "proxy-secret",
                "mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:FQoG",
                "mongoParam_retryWrites": "true"
            ]
        )
        let store = EphemeralSecureStore()

        let kept = MongoURISecretMigration.keepingSecretsInKeychain(connection, in: store)

        #expect(kept.additionalFields == [
            "mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb",
            "mongoParam_retryWrites": "true"
        ])
        #expect(try store.retrieve(forKey: ConnectionSecretKind.sslKeyPassphrase.account(for: connection.id)) == "hunter2")
        #expect(try store.retrieve(forKey: ConnectionSecretKind.mongoAWSSessionToken.account(for: connection.id)) == "FQoG")
    }

    @Test("A row with no connection-string secret is left as it is")
    func ordinaryRowIsUntouched() {
        let connection = DatabaseConnection(
            name: "Docs", type: .mongodb, host: "db.example.com", port: 27_017,
            additionalFields: ["mongoParam_retryWrites": "true"]
        )

        #expect(MongoURISecretMigration.keepingSecretsInKeychain(connection, in: EphemeralSecureStore()) == connection)
    }

    @Test("A stale copy a legacy record carries never replaces the Keychain's own")
    func keychainValueWins() throws {
        let connection = DatabaseConnection(
            name: "Docs", type: .mongodb, host: "db.example.com", port: 27_017,
            additionalFields: ["mongoParam_sslClientCertificateKeyPassword": "stale"]
        )
        let account = ConnectionSecretKind.sslKeyPassphrase.account(for: connection.id)
        let store = EphemeralSecureStore([account: "current"])

        let kept = MongoURISecretMigration.keepingSecretsInKeychain(connection, in: store)

        #expect(kept.additionalFields.isEmpty)
        #expect(try store.retrieve(forKey: account) == "current")
    }
}
