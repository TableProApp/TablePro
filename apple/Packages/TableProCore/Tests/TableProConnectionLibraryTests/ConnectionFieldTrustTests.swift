@testable import TableProConnectionLibrary
import Testing

struct ConnectionFieldTrustTests {
    @Test("A field no build has classified is dropped from files and links but still syncs")
    func unknownFieldFailsClosedOnlyForPortability() {
        let fields = ["zzzFutureSelector": "ambient"]

        #expect(ConnectionFieldCatalog.trust(of: "zzzFutureSelector") == nil)
        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: true).isEmpty)
        #expect(ConnectionFieldCatalog.syncable(fields) == fields)
    }

    @Test("Keys compare in the case the drivers read them")
    func keysCompareExactly() {
        #expect(ConnectionFieldCatalog.trust(of: "mssqlAuthMethod") != nil)
        #expect(ConnectionFieldCatalog.trust(of: "MSSQLAUTHMETHOD") == nil)
        #expect(ConnectionFieldCatalog.portable(["MSSQLAUTHMETHOD": "windows"], keepingLocalCredentials: true).isEmpty)
    }

    @Test("A host-set field never leaves the device nor syncs", arguments: [
        "sqliteBackend", "sqliteAgentToken", "preTunnelHost", "preTunnelPort", "tunnelSecuresTransport",
        "driverVariant", "enableCleartextPlugin", "connectionId", "connectionPurpose", "connectTimeoutMilliseconds"
    ])
    func hostInternalStaysHome(key: String) {
        let fields = [key: "agent"]

        #expect(ConnectionFieldCatalog.trust(of: key) == .hostInternal)
        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: true).isEmpty)
        #expect(ConnectionFieldCatalog.syncable(fields).isEmpty)
    }

    @Test("A secure field carried as plain text never leaves the device nor syncs", arguments: [
        "esApiKey", "kerberosPassword", "bqServiceAccountJson", "gcpServiceAccountKey", "sslClientKeyPassphrase",
        "mongoAWSSessionToken", "mongoParam_proxyPassword"
    ])
    func secretsStayHome(key: String) {
        let fields = [key: "hunter2"]

        #expect(ConnectionFieldCatalog.trust(of: key) == .secret)
        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: true).isEmpty)
        #expect(ConnectionFieldCatalog.syncable(fields).isEmpty)
    }

    @Test("A script or a password prompt syncs to the person's devices but never travels in a file")
    func ownDevicesSyncOnly() {
        let fields = ["preConnectScript": "op signin", "promptForPassword": "true", "beancountRunLedgerPlugins": "true"]

        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: true).isEmpty)
        #expect(ConnectionFieldCatalog.syncable(fields) == fields)
    }

    @Test("Application default sign-in is a local credential use and the service account is not")
    func googleSignInUses() {
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["bqAuthMethod": "adc", "bqProjectId": "attacker-project"])
            == [LocalCredentialUse(fieldId: "bqAuthMethod", value: "adc")])
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["bqAuthMethod": "serviceAccount"]).isEmpty)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["spAuthMethod": "emulator", "fbAuthMethod": "emulator"]).isEmpty)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["spAuthMethod": "oauth", "spOAuthClientId": "client"]) == [
            LocalCredentialUse(fieldId: "spAuthMethod", value: "oauth"),
            LocalCredentialUse(fieldId: "spOAuthClientId", value: "client")
        ])
    }

    @Test("MongoDB AWS sign-in is a local credential use in the field and in a connection string option")
    func mongoAWSUses() {
        let fields = [
            "mongoParam_authMechanism": "MONGODB-AWS",
            "mongoAuthMechanism": "mongodb-aws",
            "mongoParam_retryWrites": "true"
        ]

        #expect(ConnectionFieldCatalog.localCredentialUses(in: fields) == [
            LocalCredentialUse(fieldId: "mongoAuthMechanism", value: "mongodb-aws"),
            LocalCredentialUse(fieldId: "mongoParam_authMechanism", value: "MONGODB-AWS")
        ])
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["mongoAuthMechanism": "SCRAM-SHA-256"]).isEmpty)
        #expect(ConnectionFieldCatalog.trust(of: "mongoParam_GSSAPIServiceName") == .setting)
        #expect(ConnectionFieldCatalog.trust(of: "mongoParam_tlsCAFile") == .localFile)
    }

    @Test("Windows and Entra sign-in ask, a SQL login does not")
    func sqlServerUses() {
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["mssqlAuthMethod": "windows"]).count == 1)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["mssqlAuthMethod": "entra", "entraTenantId": "t"]).count == 2)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["mssqlAuthMethod": "sql", "entraTenantId": " "]).isEmpty)
    }

    @Test("AWS profiles ask, access keys and the password do not")
    func awsUses() {
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["awsAuth": "accessKey"]).isEmpty)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["awsAuth": "off"]).isEmpty)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["awsAuth": "profile", "awsProfileName": "default"]).count == 2)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["awsAuthMethod": "local"]).isEmpty)
        #expect(ConnectionFieldCatalog.localCredentialUses(in: ["awsAuthMethod": "sso"]).count == 1)
    }

    @Test("A saved import keeps a selector set to a plain value and drops one that uses a local credential")
    func portableKeepsPlainSelectors() {
        let fields = [
            "mssqlAuthMethod": "windows",
            "awsAuth": "accessKey",
            "snowflakeAuthMethod": "externalBrowser",
            "usePgpass": "false",
            "awsRegion": "eu-west-1"
        ]

        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: false) == [
            "awsAuth": "accessKey",
            "usePgpass": "false",
            "awsRegion": "eu-west-1"
        ])
        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: true) == fields)
    }

    @Test("InfluxDB, Qdrant and Schema Registry keep their settings and endpoint and leave their tokens behind")
    func httpEngineFieldsTravelByClass() {
        let fields = [
            "influxOrg": "acme",
            "influxSkipTLSVerify": "false",
            "influxToken": "influx-token",
            "qdApiKey": "qdrant-key",
            "schemaRegistryUrl": "https://registry.example.com",
            "schemaRegistryUsername": "reader",
            "schemaRegistryPassword": "registry-password"
        ]
        let kept = [
            "influxOrg": "acme",
            "influxSkipTLSVerify": "false",
            "schemaRegistryUrl": "https://registry.example.com",
            "schemaRegistryUsername": "reader"
        ]

        #expect(ConnectionFieldCatalog.portable(fields, keepingLocalCredentials: true) == kept)
        #expect(ConnectionFieldCatalog.syncable(fields) == kept)
        #expect(ConnectionFieldCatalog.trust(of: "schemaRegistryUrl") == .destination)
    }

    @Test("Every plain value is lowercased, since a use compares the value lowercased")
    func plainValuesAreLowercased() {
        let tables = [ConnectionFieldCatalog.trustByKey, ConnectionFieldCatalog.mongoOptionTrust]
        for (key, trust) in tables.flatMap({ $0 }) {
            guard case .localCredential(let plainValues) = trust else { continue }
            #expect(plainValues.allSatisfy { $0 == $0.lowercased() }, "\(key)")
        }
    }

    @Test("Replace keeps a saved row's sign-in, scripts and unknown fields, never its host or secrets")
    func replaceKeepsWhatImportsNeverCarry() {
        #expect(ConnectionFieldCatalog.survivesReplace("awsProfileName"))
        #expect(ConnectionFieldCatalog.survivesReplace("preConnectScript"))
        #expect(ConnectionFieldCatalog.survivesReplace("zzzFutureSetting"))
        #expect(!ConnectionFieldCatalog.survivesReplace("awsRegion"))
        #expect(!ConnectionFieldCatalog.survivesReplace("esApiKey"))
        #expect(!ConnectionFieldCatalog.survivesReplace("sqliteBackend"))
    }

    @Test("A key document is inline JSON; anything else would be read as a file path", arguments: [
        ("{\"type\":\"service_account\"}", true),
        ("  \n{\"type\":\"service_account\"}", true),
        ("~/.config/gcloud/application_default_credentials.json", false),
        ("Users/me/key.json", false),
        ("", false),
    ])
    func keyDocumentMustBeInline(value: String, inline: Bool) {
        #expect(ConnectionFieldCatalog.isInlineKeyDocument(value) == inline)
    }

    @Test("Every key document field is a secret")
    func keyDocumentsAreSecrets() {
        for fieldId in ConnectionFieldCatalog.keyDocumentFieldIds {
            #expect(ConnectionFieldCatalog.trust(of: fieldId) == .secret, "\(fieldId)")
        }
    }
}
