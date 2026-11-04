import Foundation
import TableProImport
import Testing

struct ShareableAdditionalFieldsTests {
    @Test("Scripts, prompts, secrets and host-set fields are never shared")
    func leavesOutWhatOnlyThisDeviceUses() {
        let fields = [
            "preConnectScript": "export PGTOKEN=secret-token",
            "postDisconnectScript": "networksetup -disconnectpppoeservice corp",
            "promptForPassword": "true",
            "sslClientKeyPassphrase": "hunter2",
            "preTunnelHost": "db.internal",
            "sqliteBackend": "agent",
            "connectionOptions": "-c search_path=app"
        ]

        let shareable = ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: true)

        #expect(shareable == ["connectionOptions": "-c search_path=app"])
    }

    @Test("A field no build has classified is never shared")
    func leavesOutUnknownFields() {
        let fields = ["zzzFutureSelector": "ambient", "PROMPTFORPASSWORD": "true", "awsRegion": "us-east-1"]

        let shareable = ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: true)

        #expect(shareable == ["awsRegion": "us-east-1"])
    }

    @Test("A secure field carried as plain text is never shared")
    func leavesOutPlainSecrets() {
        let fields = ["esApiKey": "c2VjcmV0", "kerberosPassword": "hunter2", "esHosts": "es.example.com:9200"]

        #expect(ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: true) == [
            "esHosts": "es.example.com:9200"
        ])
    }

    @Test("Fields that pick a credential kept on this device are shared only when asked")
    func localCredentialsOnlyWhenAsked() {
        let fields = [
            "mssqlAuthMethod": "windows",
            "entraTenantId": "tenant",
            "snowflakeConnectionName": "default",
            "mongoAuthMechanism": "MONGODB-AWS",
            "mongoAuthSource": "admin"
        ]

        #expect(ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: false) == [
            "mongoAuthSource": "admin"
        ])
        #expect(ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: true) == fields)
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

        #expect(ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: true) == [
            "mongoParam_proxyHost": "proxy.example.com",
            "mongoParam_retryWrites": "true"
        ])
    }

    @Test("Mechanism properties without a session token are shared")
    func keepsMechanismPropertiesWithoutAToken() {
        let fields = ["mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb"]

        #expect(ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: true) == fields)
    }

    @Test func testLeavesOutTheExcludedKeys() {
        let fields = ["mssqlSchema": "sales", "mssqlAuthMethod": "sql"]

        let shareable = ExportableConnection.shareableAdditionalFields(
            fields,
            excluding: ["mssqlSchema"],
            keepingLocalCredentials: true
        )

        #expect(shareable == ["mssqlAuthMethod": "sql"])
    }

    @Test func testReturnsNilWhenNothingIsLeftToShare() {
        let fields = ["preConnectScript": "echo hi", "usePgpass": "true"]

        #expect(ExportableConnection.shareableAdditionalFields(fields, keepingLocalCredentials: false) == nil)
        #expect(ExportableConnection.shareableAdditionalFields([:], keepingLocalCredentials: true) == nil)
    }

    @Test("A saved row exported without local credentials connects like the same row imported from a file")
    func exportAndImportAgreeForReplace() {
        let fields = ["mssqlAuthMethod": "windows", "mssqlSchema": "sales", "zzzFutureSelector": "x"]
        let saved = Self.connection(fields: ExportableConnection.shareableAdditionalFields(
            fields,
            keepingLocalCredentials: false
        ))
        let imported = Self.connection(fields: fields).sanitizedForImport()

        #expect(saved.connectsLike(imported))
        #expect(!Self.connection(fields: ExportableConnection.shareableAdditionalFields(
            fields,
            keepingLocalCredentials: true
        )).connectsLike(imported))
    }

    private static func connection(fields: [String: String]?) -> ExportableConnection {
        ExportableConnection(
            name: "Orders", host: "sql.example.com", port: 1_433, database: "orders", username: "app",
            type: "SQL Server", additionalFields: fields
        )
    }
}
