import Foundation

// What an additional field holds, which decides whether it may arrive from outside or leave this device.
public enum ConnectionFieldTrust: Equatable, Sendable {
    case setting
    case destination
    case localFile
    // Any value outside `plainValues` (compared without case) signs in with something this device holds.
    case localCredential(plainValues: Set<String>)
    // Travels only in an encrypted bundle's credentials, never as a field.
    case secret
    // Moves between the person's own devices by sync, never arrives in a file or a link.
    case ownDevices
    // Set by the host at connect. A stored or imported value is never used.
    case hostInternal
}

public struct LocalCredentialUse: Hashable, Sendable {
    public let fieldId: String
    public let value: String

    public init(fieldId: String, value: String) {
        self.fieldId = fieldId
        self.value = value
    }
}

public enum ConnectionFieldCatalog {
    public static func trust(of key: String) -> ConnectionFieldTrust? {
        if let option = ConnectionSecretOptions.mongoOption(in: key) {
            return mongoOptionTrust[option] ?? .setting
        }
        return trustByKey[key]
    }

    // Import and export share this, so a saved row and the same row read back from its export compare equal.
    // A selector set to a plain value (`mssqlAuthMethod=sql`) is a setting, so only a value that uses a local credential drops.
    public static func portable(_ fields: [String: String], keepingLocalCredentials: Bool) -> [String: String] {
        fields.filter { key, value in
            if ConnectionSecretOptions.isSecret(key: key, value: value) { return false }
            switch trust(of: key) {
            case .setting, .destination, .localFile:
                return true
            case .localCredential(let plainValues):
                return keepingLocalCredentials || !usesLocalCredential(value, plainValues: plainValues)
            case .secret, .ownDevices, .hostInternal, nil:
                return false
            }
        }
    }

    // A key this build does not know still syncs, so a field a newer build added survives a round trip through an older one.
    public static func syncable(_ fields: [String: String]) -> [String: String] {
        ConnectionSecretOptions.removingSecrets(from: fields).filter { key, _ in
            switch trust(of: key) {
            case .secret, .hostInternal:
                return false
            default:
                return true
            }
        }
    }

    public static func localCredentialUses(in fields: [String: String]) -> [LocalCredentialUse] {
        fields.compactMap { key, value -> LocalCredentialUse? in
            guard case .localCredential(let plainValues) = trust(of: key),
                  usesLocalCredential(value, plainValues: plainValues)
            else { return nil }
            return LocalCredentialUse(fieldId: key, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .sorted { ($0.fieldId.lowercased(), $0.value) < ($1.fieldId.lowercased(), $1.value) }
    }

    // A driver reads a key document from these fields and treats any text that is not the document itself as the path of
    // a file on this device.
    public static let keyDocumentFieldIds: Set<String> = [
        "bqServiceAccountJson",
        "btServiceAccountJson",
        "fbServiceAccountJson",
        "gcpServiceAccountKey",
        "spServiceAccountJson",
    ]

    public static func isInlineKeyDocument(_ value: String) -> Bool {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"])).hasPrefix("{")
    }

    // What a replace keeps from the saved row, because a saved import never carries it.
    public static func survivesReplace(_ key: String) -> Bool {
        switch trust(of: key) {
        case .localCredential, .ownDevices, nil:
            return true
        default:
            return false
        }
    }

    private static func usesLocalCredential(_ value: String, plainValues: Set<String>) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !plainValues.contains(trimmed.lowercased())
    }

    // An emulator signs in with nothing, and libmongoc reads no device credential for these mechanisms.
    static let googleAuthPlainValues: Set<String> = ["serviceaccount", "emulator"]
    static let mongoMechanismPlainValues: Set<String> = ["scram-sha-1", "scram-sha-256", "mongodb-x509", "plain"]

    // Lowercased option names after `mongoParam_`. Every other option is a setting.
    static let mongoOptionTrust: [String: ConnectionFieldTrust] = {
        var table: [String: ConnectionFieldTrust] = [
            "authmechanism": .localCredential(plainValues: mongoMechanismPlainValues),
            "proxyhost": .destination,
            "proxyport": .destination,
            "sslcertificateauthorityfile": .localFile,
            "sslclientcertificatekeyfile": .localFile,
            "tlscafile": .localFile,
            "tlscertificatekeyfile": .localFile,
        ]
        for option in ConnectionSecretOptions.mongoSecretOptions {
            table[option] = .secret
        }
        return table
    }()

    // Field ids as the drivers read them, case and all. apple/scripts/ci/check-connection-field-trust.py
    // fails on a declared field missing here.
    static let trustByKey: [String: ConnectionFieldTrust] = [
        "awsAccessKeyId": .setting,
        "binaryInlineLimitKB": .setting,
        "bqLocation": .setting,
        "bqMaxBytesBilled": .setting,
        "cassandraConsistency": .setting,
        "cassandraSerialConsistency": .setting,
        "completionIdentifierCase": .setting,
        "connectionOptions": .setting,
        "connectTimeoutSeconds": .setting,
        "duckdbAlias": .setting,
        "duckdbCertificateFingerprint": .setting,
        "duckdbIdleReleaseMinutes": .setting,
        "duckdbMode": .setting,
        "duckdbReadOnly": .setting,
        "duckdbSSLMode": .setting,
        "esAuthMethod": .setting,
        "esSkipTLSVerify": .setting,
        "etcdKeyPrefix": .setting,
        "etcdTlsMode": .setting,
        "gssEncryptionMode": .setting,
        "influxOrg": .setting,
        "influxSkipTLSVerify": .setting,
        "kafkaBrokerRouting": .setting,
        "kafkaConnectTimeout": .setting,
        "kafkaSaslMechanism": .setting,
        "kafkaSecurityProtocol": .setting,
        "kerberosPrincipal": .setting,
        "libsqlMode": .setting,
        "maskingRules": .setting,
        "mongoAuthSource": .setting,
        "mongoReadPreference": .setting,
        "mongoReplicaSet": .setting,
        "mongoUseSrv": .setting,
        "mongoUuidRepresentation": .setting,
        "mongoWriteConcern": .setting,
        "mssqlKerberosPrincipal": .setting,
        "mssqlLoginTimeout": .setting,
        "mssqlSchema": .setting,
        "mysqlConnectionEncoding": .setting,
        "mysqlIdleReleaseMinutes": .setting,
        "oracleConnectionType": .setting,
        "oracleDebugProtocol": .setting,
        "oracleDebuggerPorts": .setting,
        "oracleNetworkEncryption": .setting,
        "oracleRole": .setting,
        "oracleSID": .setting,
        "queryTimeoutSeconds": .setting,
        "redisDatabase": .setting,
        "redisMode": .setting,
        "redisSentinelMasterName": .setting,
        "redisSentinelUsername": .setting,
        "redisSeparator": .setting,
        "schemaRegistryUsername": .setting,
        "scriptTimeoutSeconds": .setting,
        "sdbAccess": .setting,
        "sdbAuthLevel": .setting,
        "sdbDatabase": .setting,
        "sdbSkipTLSVerify": .setting,
        "snowflakeDatabase": .setting,
        "snowflakeRole": .setting,
        "snowflakeSchema": .setting,
        "snowflakeUser": .setting,
        "snowflakeWarehouse": .setting,
        "teradataLogMech": .setting,
        "teradataTMode": .setting,
        "trinoAuthMethod": .setting,
        "trinoSchema": .setting,
        "trinoTimeZone": .setting,
        "typesenseSkipTLSVerify": .setting,
        "wvAuthMethod": .setting,
        "wvSkipTLSVerify": .setting,

        "awsEndpointUrl": .destination,
        "awsRDSEndpoint": .destination,
        "awsRedshiftEndpoint": .destination,
        "awsRegion": .destination,
        "awsReplicationGroupId": .destination,
        "bqProjectId": .destination,
        "btAppProfileId": .destination,
        "btInstanceId": .destination,
        "btProjectId": .destination,
        "cfAccountId": .destination,
        "databaseUrl": .destination,
        "duckdbHost": .destination,
        "duckdbPort": .destination,
        "esHosts": .destination,
        "fbDatabaseId": .destination,
        "fbDatabaseURL": .destination,
        "fbEmulatorHost": .destination,
        "fbProjectId": .destination,
        "hanaTLSServerName": .destination,
        "kafkaBootstrapServers": .destination,
        "mongoHosts": .destination,
        "oracleDebuggerHost": .destination,
        "oracleServiceName": .destination,
        "r2AccountId": .destination,
        "r2Bucket": .destination,
        "redisClusterHosts": .destination,
        "redisSentinelHosts": .destination,
        "schemaRegistryUrl": .destination,
        "snowflakeAccount": .destination,
        "spDatabaseId": .destination,
        "spEndpoint": .destination,
        "spInstanceId": .destination,
        "spProjectId": .destination,
        "sshForwardUnixSocketPath": .destination,

        "attachedDatabases": .localFile,
        "duckdbCACertificateFilePath": .localFile,
        "duckdbFilePath": .localFile,
        "etcdCaCertPath": .localFile,
        "etcdClientCertPath": .localFile,
        "etcdClientKeyPath": .localFile,
        "libsqlFilePath": .localFile,
        "localSocketPath": .localFile,
        "snowflakePrivateKeyPath": .localFile,
        "sqliteExtensions": .localFile,
        "sslCaCertPath": .localFile,

        "awsAuth": .localCredential(plainValues: ["off", "accesskey"]),
        // DynamoDB Local signs with fixed placeholder keys.
        "awsAuthMethod": .localCredential(plainValues: ["credentials", "local"]),
        "awsProfileName": .localCredential(plainValues: []),
        "bqAuthMethod": .localCredential(plainValues: ["serviceaccount"]),
        // Google refresh tokens are cached by client id alone.
        "bqOAuthClientId": .localCredential(plainValues: []),
        "btAuthMethod": .localCredential(plainValues: ["serviceaccount"]),
        "entraAccount": .localCredential(plainValues: []),
        "entraClientId": .localCredential(plainValues: []),
        "entraTenantId": .localCredential(plainValues: []),
        "fbAuthMethod": .localCredential(plainValues: googleAuthPlainValues),
        "mongoAuthMechanism": .localCredential(plainValues: mongoMechanismPlainValues),
        "mssqlAuthMethod": .localCredential(plainValues: ["sql"]),
        // externalBrowser reuses the cached SSO token for the account and user.
        "snowflakeAuthMethod": .localCredential(plainValues: ["password", "keypair", "oauth"]),
        "snowflakeConnectionName": .localCredential(plainValues: []),
        "spAuthMethod": .localCredential(plainValues: googleAuthPlainValues),
        "spOAuthClientId": .localCredential(plainValues: []),
        "usePgpass": .localCredential(plainValues: ["false"]),

        "awsSecretAccessKey": .secret,
        "awsSessionToken": .secret,
        "bqOAuthClientSecret": .secret,
        "bqOAuthRefreshToken": .secret,
        "bqServiceAccountJson": .secret,
        "btServiceAccountJson": .secret,
        "duckdbToken": .secret,
        "esApiKey": .secret,
        "fbServiceAccountJson": .secret,
        "gcpServiceAccountKey": .secret,
        "influxToken": .secret,
        "kerberosPassword": .secret,
        "mongoAWSSessionToken": .secret,
        "mssqlKerberosPassword": .secret,
        "qdApiKey": .secret,
        "redisSentinelPassword": .secret,
        "schemaRegistryPassword": .secret,
        "sdbToken": .secret,
        "snowflakeMFAPasscode": .secret,
        "snowflakeOAuthToken": .secret,
        "snowflakePassword": .secret,
        "snowflakePrivateKeyPassphrase": .secret,
        "spOAuthClientSecret": .secret,
        "spOAuthRefreshToken": .secret,
        "spServiceAccountJson": .secret,
        "sslClientKeyPassphrase": .secret,
        "trinoJwtToken": .secret,
        "typesenseApiKey": .secret,
        "wvApiKey": .secret,

        "beancountRunLedgerPlugins": .ownDevices,
        "postDisconnectScript": .ownDevices,
        "preConnectScript": .ownDevices,
        "promptForPassword": .ownDevices,

        "connectionId": .hostInternal,
        "connectionPurpose": .hostInternal,
        "connectTimeoutMilliseconds": .hostInternal,
        "driverVariant": .hostInternal,
        "enableCleartextPlugin": .hostInternal,
        "preTunnelHost": .hostInternal,
        "preTunnelPort": .hostInternal,
        "sqliteAgentToken": .hostInternal,
        "sqliteBackend": .hostInternal,
        "tunnelSecuresTransport": .hostInternal,
    ]
}
