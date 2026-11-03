import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProPluginKit
import Testing

private let hostOwnedKeys: [String] = [
    DatabaseConnection.connectTimeoutSecondsKey,
    DatabaseConnection.queryTimeoutSecondsKey,
    DatabaseConnection.postDisconnectScriptKey,
    DatabaseConnection.scriptTimeoutSecondsKey,
    DatabaseConnection.completionIdentifierCaseKey,
    DatabaseConnection.binaryInlineLimitKilobytesKey,
    DatabaseConnection.maskingRulesKey,
    DatabaseConnection.sshForwardUnixSocketPathKey,
    DatabaseConnection.preTunnelHostKey,
    DatabaseConnection.preTunnelPortKey,
    DatabaseConnection.tunnelSecuresTransportKey,
    DatabaseConnection.iamSignInFieldId,
    MySQLLocalSocket.fieldKey,
    EtcdTLSModeField.fieldId,
    DuckDBSSLModeField.fieldId,
    RemoteSQLiteWire.backendFieldKey,
    RemoteSQLiteWire.tokenFieldKey,
    ConnectionSecretOptions.mongoSessionTokenFieldId,
    LoadableExtensionList.fieldId,
    AttachedDatabaseList.fieldId,
    "promptForPassword",
    "usePgpass",
    "preConnectScript",
    "kafkaConnectTimeout",
    "redisDatabase",
    "redisMode",
    "kafkaBrokerRouting",
    "mongoAuthSource",
    "mongoReadPreference",
    "mongoWriteConcern",
    "mongoReplicaSet",
    "mongoUseSrv",
    "mongoUuidRepresentation",
    "mongoAuthMechanism",
    "mongoHosts",
    "mssqlSchema",
    "oracleServiceName",
    "sslClientKeyPassphrase",
    "beancountRunLedgerPlugins",
    "snowflakeDatabase",
    "trinoSchema",
    "driverVariant",
    "enableCleartextPlugin",
    "connectionId",
    "connectionPurpose",
    "connectTimeoutMilliseconds",
]

// The factory's own keys and the ones a tunnel sets on the effective connection.
private let setAtConnect: [String] = [
    "driverVariant",
    "enableCleartextPlugin",
    "connectionId",
    "connectionPurpose",
    "connectTimeoutMilliseconds",
    DatabaseConnection.preTunnelHostKey,
    DatabaseConnection.preTunnelPortKey,
    DatabaseConnection.tunnelSecuresTransportKey,
    RemoteSQLiteWire.backendFieldKey,
    RemoteSQLiteWire.tokenFieldKey,
]

// Plugins never load under XCTest, so `builtInDefaults()` is the curated table an import or export sees.
struct ConnectionFieldTrustCoverageTests {
    private static func isSecret(_ trust: ConnectionFieldTrust?) -> Bool {
        if case .secret = trust { return true }
        return false
    }

    @Test("Every field a curated engine declares has a trust class")
    func everyCuratedFieldIsClassified() {
        for entry in PluginMetadataRegistry.shared.builtInDefaults() {
            for field in entry.snapshot.connection.additionalConnectionFields {
                #expect(ConnectionFieldCatalog.trust(of: field.id) != nil, "\(entry.typeId).\(field.id)")
            }
        }
    }

    @Test("The catalog calls a curated field a secret exactly when the engine declares it secure")
    func secretMatchesSecureFields() {
        for entry in PluginMetadataRegistry.shared.builtInDefaults() {
            for field in entry.snapshot.connection.additionalConnectionFields {
                let trust = ConnectionFieldCatalog.trust(of: field.id)
                #expect(Self.isSecret(trust) == field.isSecure, "\(entry.typeId).\(field.id)")
            }
        }
    }

    @Test("Every key the host writes into a connection's fields has a trust class", arguments: hostOwnedKeys)
    func everyHostKeyIsClassified(_ key: String) {
        #expect(ConnectionFieldCatalog.trust(of: key) != nil)
    }

    @Test("Every key the host sets at connect is host-internal", arguments: setAtConnect)
    func connectKeysAreHostInternal(_ key: String) {
        #expect(ConnectionFieldCatalog.trust(of: key) == .hostInternal)
    }
}
