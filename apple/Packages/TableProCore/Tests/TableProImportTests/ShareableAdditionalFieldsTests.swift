import Foundation
import TableProImport
import Testing

struct ShareableAdditionalFieldsTests {
    @Test func testLeavesOutEveryImportBlockedKeyInAnyCase() {
        let fields = [
            "preConnectScript": "export PGTOKEN=secret-token",
            "postDisconnectScript": "networksetup -disconnectpppoeservice corp",
            "usePgpass": "true",
            "PROMPTFORPASSWORD": "true",
            "awsRegion": "us-east-1",
            "sslClientKeyPassphrase": "hunter2",
            "connectionOptions": "-c search_path=app"
        ]

        let shareable = ExportableConnection.shareableAdditionalFields(fields)

        #expect(shareable == ["connectionOptions": "-c search_path=app"])
    }

    @Test("Fields that pick a credential kept on this Mac are never shared")
    func leavesOutLocalCredentialSelectors() {
        let fields = [
            "entraTenantId": "tenant",
            "EntraClientId": "client",
            "snowflakeConnectionName": "default",
            "beancountRunLedgerPlugins": "true",
            "mongoAuthMechanism": "mongodb-aws",
            "mongoAuthSource": "admin"
        ]

        #expect(ExportableConnection.shareableAdditionalFields(fields) == ["mongoAuthSource": "admin"])
    }

    @Test("Secrets a MongoDB connection string carried as options are never shared")
    func leavesOutMongoURISecrets() {
        let fields = [
            "mongoParam_tlsCertificateKeyFilePassword": "hunter2",
            "mongoParam_SSLCLIENTCERTIFICATEKEYPASSWORD": "hunter2",
            "mongoParam_proxyPassword": "proxy-secret",
            "mongoParam_proxyHost": "proxy.example.com",
            "mongoParam_authMechanismProperties": "aws_session_token:FQoGZXIvYXdz",
            "mongoParam_retryWrites": "true"
        ]

        #expect(ExportableConnection.shareableAdditionalFields(fields) == [
            "mongoParam_proxyHost": "proxy.example.com",
            "mongoParam_retryWrites": "true"
        ])
    }

    @Test("Mechanism properties without a session token are shared")
    func keepsMechanismPropertiesWithoutAToken() {
        let fields = ["mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb"]

        #expect(ExportableConnection.shareableAdditionalFields(fields) == fields)
    }

    @Test func testLeavesOutTheExcludedKeys() {
        let fields = ["mssqlKerberosPassword": "secret", "mssqlAuthMethod": "kerberos"]

        let shareable = ExportableConnection.shareableAdditionalFields(
            fields,
            excluding: ["mssqlKerberosPassword"]
        )

        #expect(shareable == ["mssqlAuthMethod": "kerberos"])
    }

    @Test func testReturnsNilWhenNothingIsLeftToShare() {
        let fields = ["preConnectScript": "echo hi", "usePgpass": "true"]

        #expect(ExportableConnection.shareableAdditionalFields(fields) == nil)
        #expect(ExportableConnection.shareableAdditionalFields([:]) == nil)
    }
}
