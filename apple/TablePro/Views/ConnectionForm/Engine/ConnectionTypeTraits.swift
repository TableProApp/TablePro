//
//  ConnectionTypeTraits.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The only reader of plugin metadata for the editor: everything else in the engine takes this value.
struct ConnectionTypeTraits: Sendable {
    struct SSLTraits: Sendable, Equatable {
        var defaultMode: SSLMode = .disabled
        var supportsOpportunisticTLS = true
        var tlsImpliedPorts: [Int] = []
        var modeWhenTLSEnabled: SSLMode = .required
        var supportsPerConnectionCertificatePaths = true
        var verifiesServerWithSystemTrust = false
        var supportsClientKeyPassphrase = false
        var note = ""
        var supportedModes: [SSLMode] = SSLMode.allCases
        var modesThroughTunnel: [SSLMode] = SSLMode.allCases

        func impliedMode(forPort port: Int) -> SSLMode? {
            tlsImpliedPorts.contains(port) ? modeWhenTLSEnabled : nil
        }

        func resolution(forPort port: Int) -> SSLModeResolution {
            guard let implied = impliedMode(forPort: port) else {
                return SSLModeResolution(mode: defaultMode, origin: .typeDefault)
            }
            return SSLModeResolution(mode: implied, origin: .impliedByPort)
        }

        func requiresCACertificate(for mode: SSLMode) -> Bool {
            guard mode == .verifyCa || mode == .verifyIdentity, supportsPerConnectionCertificatePaths else { return false }
            return mode == .verifyCa || !verifiesServerWithSystemTrust
        }
    }

    var type: DatabaseType
    var pluginTypeId: String
    var displayName: String
    var connectionMode: ConnectionMode = .network
    var fields: [ConnectionField] = []
    var defaultPort: Int = 0
    var defaultHost: String?
    var hidesBuiltInPassword = false
    var showsBuiltInDatabaseField = true
    var containerEntityName = String(localized: "Database")
    var fileExtensions: [String] = []
    var newDatabaseFileExtensions: [String] = []
    var localFilePathField: LocalFilePathField?
    var defaultLocalSocketPath: String?
    var defaultUnixSocketPath: String?
    var localSocketIsDirectory = false
    var socketForwardApplies = true
    var supportsSSH = true
    var supportsSSL = true
    var supportsCloudflareTunnel = true
    var supportsSOCKSProxy = true
    var supportsTunnelCommand = true
    var supportsCloudSQLProxy = false
    var supportsRemoteDatabaseFile = false
    var supportsRemoteDatabaseSession = false
    var serverEndpointFields: ServerEndpointFields?
    var ssl = SSLTraits()
    var isEngineReadOnly = false
    var manualCommitAvailable = true
    var supportsBinaryInlineLimit = false
    var supportsIdentifierCase = false
    var storedSecureFieldIds: [String] = []

    init(type: DatabaseType) {
        self.type = type
        self.pluginTypeId = type.rawValue
        self.displayName = type.rawValue
    }

    var supportsLocalSocket: Bool { defaultLocalSocketPath != nil }

    var declaredSecureFieldIds: [String] {
        fields.filter(\.isSecure).map(\.id)
    }

    func field(_ id: String) -> ConnectionField? {
        fields.first { $0.id == id }
    }

    func defaultValues() -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            if let value = field.defaultValue {
                values[field.id] = value
            }
        }
        return values
    }

    var defaultPortText: String {
        defaultPort == 0 ? "" : String(defaultPort)
    }

    @MainActor
    static func live(for type: DatabaseType, pluginManager: PluginManager) -> ConnectionTypeTraits {
        var traits = ConnectionTypeTraits(type: type)
        let snapshot = PluginMetadataRegistry.shared.snapshot(for: type)
        traits.pluginTypeId = type.pluginTypeId
        traits.displayName = type.displayName
        traits.connectionMode = pluginManager.connectionMode(for: type)
        traits.fields = pluginManager.additionalConnectionFields(for: type)
        traits.defaultPort = type.defaultPort
        traits.defaultHost = type.defaultHost
        traits.hidesBuiltInPassword = snapshot?.connection.hidesBuiltInPassword ?? false
        traits.showsBuiltInDatabaseField = showsBuiltInDatabaseField(
            mode: traits.connectionMode,
            hidden: snapshot?.connection.hidesBuiltInDatabase ?? false,
            switchesDatabases: pluginManager.supportsDatabaseSwitching(for: type)
        )
        traits.containerEntityName = pluginManager.containerEntityName(for: type)
        traits.fileExtensions = pluginManager.fileExtensions(for: type)
        traits.newDatabaseFileExtensions = pluginManager.newDatabaseFileExtensions(for: type)
        traits.localFilePathField = pluginManager.localFilePathField(for: type)
        traits.defaultLocalSocketPath = pluginManager.defaultLocalSocketPath(for: type)
        traits.defaultUnixSocketPath = pluginManager.defaultUnixSocketPath(for: type)
        traits.localSocketIsDirectory = type.localSocketIsDirectory
        traits.socketForwardApplies = DatabaseConnection.socketForwardApplies(to: type)
        traits.supportsSSH = pluginManager.supportsSSH(for: type)
        traits.supportsSSL = pluginManager.supportsSSL(for: type)
        traits.supportsCloudflareTunnel = pluginManager.supportsCloudflareTunnel(for: type)
        traits.supportsSOCKSProxy = pluginManager.supportsSOCKSProxy(for: type)
        traits.supportsTunnelCommand = pluginManager.supportsTunnelCommand(for: type)
        traits.supportsCloudSQLProxy = type.supportsCloudSQLProxy
        traits.supportsRemoteDatabaseFile = pluginManager.supportsRemoteDatabaseFile(for: type)
        traits.supportsRemoteDatabaseSession = pluginManager.supportsRemoteDatabaseSession(for: type)
        traits.serverEndpointFields = snapshot?.capabilities.serverEndpointFields
        traits.ssl = sslTraits(for: type, pluginManager: pluginManager)
        traits.isEngineReadOnly = pluginManager.isEngineReadOnly(for: type)
        traits.manualCommitAvailable = ManualCommit.isAvailable(for: type)
        traits.supportsBinaryInlineLimit = pluginManager.largeValueFunctions(for: type) != nil
        traits.supportsIdentifierCase = type.identifierRules != nil
        traits.storedSecureFieldIds = pluginManager.secureConnectionFieldIds(for: type)
        return traits
    }

    private static func showsBuiltInDatabaseField(mode: ConnectionMode, hidden: Bool, switchesDatabases: Bool) -> Bool {
        switch mode {
        case .fileBased: return false
        case .apiOnly: return switchesDatabases && !hidden
        default: return !hidden
        }
    }

    @MainActor
    private static func sslTraits(for type: DatabaseType, pluginManager: PluginManager) -> SSLTraits {
        var ssl = SSLTraits()
        ssl.defaultMode = type.defaultSSLMode
        ssl.supportsOpportunisticTLS = type.supportsOpportunisticTLS
        ssl.tlsImpliedPorts = type.tlsImpliedPorts
        ssl.modeWhenTLSEnabled = type.sslModeWhenTLSEnabled
        ssl.supportsPerConnectionCertificatePaths = type.supportsPerConnectionCertificatePaths
        ssl.verifiesServerWithSystemTrust = type.verifiesServerWithSystemTrust
        ssl.supportsClientKeyPassphrase = type.supportsClientKeyPassphrase
        ssl.note = type.sslPaneTooltip
        // A registry plugin that is not installed has no type to ask, and the connect re-checks the mode anyway.
        if pluginManager.isDriverInstalled(for: type), let plugin = pluginManager.driverPlugin(for: type) {
            let pluginType = Swift.type(of: plugin)
            ssl.supportedModes = pluginType.supportedSSLModes
            ssl.modesThroughTunnel = pluginType.sslModesThroughTunnel
        }
        return ssl
    }
}
