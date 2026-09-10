import Foundation
import UniformTypeIdentifiers

// MARK: - UTType

public extension UTType {
    static let tableproConnectionShare = UTType(exportedAs: "com.tablepro.connection-share")
}

// MARK: - Export Error

public enum ConnectionExportError: LocalizedError {
    case encodingFailed
    case fileWriteFailed(String)
    case fileReadFailed(String)
    case invalidFormat
    case unsupportedVersion(Int)
    case decodingFailed(String)
    case requiresPassphrase
    case decryptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return String(localized: "Failed to encode connection data")
        case .fileWriteFailed(let path):
            return String(format: String(localized: "Failed to write file: %@"), path)
        case .fileReadFailed(let path):
            return String(format: String(localized: "Failed to read file: %@"), path)
        case .invalidFormat:
            return String(localized: "This file is not a valid TablePro export")
        case .unsupportedVersion(let version):
            return String(format: String(localized: "This file requires a newer version of TablePro (format version %d)"), version)
        case .decodingFailed(let detail):
            return String(format: String(localized: "Failed to parse connection file: %@"), detail)
        case .requiresPassphrase:
            return String(localized: "This file is encrypted and requires a passphrase")
        case .decryptionFailed(let detail):
            return String(format: String(localized: "Decryption failed: %@"), detail)
        }
    }
}

// MARK: - Export Envelope

public struct ConnectionExportEnvelope: Codable, Sendable {
    public let formatVersion: Int
    public let exportedAt: Date
    public let appVersion: String
    public let connections: [ExportableConnection]
    public let groups: [ExportableGroup]?
    public let tags: [ExportableTag]?
    public let credentials: [String: ExportableCredentials]?

    public init(
        formatVersion: Int,
        exportedAt: Date,
        appVersion: String,
        connections: [ExportableConnection],
        groups: [ExportableGroup]?,
        tags: [ExportableTag]?,
        credentials: [String: ExportableCredentials]?
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.credentials = credentials
    }
}

// MARK: - Exportable Connection

public struct ExportableConnection: Codable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let database: String
    public let username: String
    public let type: String
    public let sshConfig: ExportableSSHConfig?
    public let sslConfig: ExportableSSLConfig?
    public let color: String?
    public let tagName: String?
    public let tagNames: [String]?
    public let groupName: String?
    public let sshProfileId: String?
    public let safeModeLevel: String?
    public let aiPolicy: String?
    public let additionalFields: [String: String]?
    public let redisDatabase: Int?
    public let startupCommands: String?
    public let localOnly: Bool?
    public let tunnelCommand: ExportableTunnelCommand?

    public init(
        name: String,
        host: String,
        port: Int,
        database: String,
        username: String,
        type: String,
        sshConfig: ExportableSSHConfig?,
        sslConfig: ExportableSSLConfig?,
        color: String?,
        tagName: String?,
        tagNames: [String]? = nil,
        groupName: String?,
        sshProfileId: String?,
        safeModeLevel: String?,
        aiPolicy: String?,
        additionalFields: [String: String]?,
        redisDatabase: Int?,
        startupCommands: String?,
        localOnly: Bool?,
        tunnelCommand: ExportableTunnelCommand? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.type = type
        self.sshConfig = sshConfig
        self.sslConfig = sslConfig
        self.color = color
        self.tagName = tagName
        self.tagNames = tagNames
        self.groupName = groupName
        self.sshProfileId = sshProfileId
        self.safeModeLevel = safeModeLevel
        self.aiPolicy = aiPolicy
        self.additionalFields = additionalFields
        self.redisDatabase = redisDatabase
        self.startupCommands = startupCommands
        self.localOnly = localOnly
        self.tunnelCommand = tunnelCommand
    }

    public func renamed(to newName: String) -> ExportableConnection {
        ExportableConnection(
            name: newName, host: host, port: port, database: database,
            username: username, type: type, sshConfig: sshConfig,
            sslConfig: sslConfig, color: color, tagName: tagName, tagNames: tagNames,
            groupName: groupName, sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel, aiPolicy: aiPolicy,
            additionalFields: additionalFields, redisDatabase: redisDatabase,
            startupCommands: startupCommands, localOnly: localOnly,
            tunnelCommand: tunnelCommand
        )
    }
}

/// A forwarding command carried by an exported connection.
///
/// It holds no secret, which is why it can travel at all, and it is the only exported field that
/// describes a process TablePro would start. Import keeps it only behind an explicit confirmation,
/// and the routes that are a click rather than a decision, a deeplink and the team library, drop it
/// before anyone is asked.
public struct ExportableTunnelCommand: Codable, Sendable, Equatable {
    public let method: String
    public let command: String?
    public let executablePath: String?
    public let kubernetesNamespace: String?
    public let kubernetesResource: String?
    public let kubernetesContext: String?
    public let awsTarget: String?
    public let awsProfile: String?
    public let awsRegion: String?

    public init(
        method: String,
        command: String?,
        executablePath: String?,
        kubernetesNamespace: String?,
        kubernetesResource: String?,
        kubernetesContext: String?,
        awsTarget: String?,
        awsProfile: String?,
        awsRegion: String?
    ) {
        self.method = method
        self.command = command
        self.executablePath = executablePath
        self.kubernetesNamespace = kubernetesNamespace
        self.kubernetesResource = kubernetesResource
        self.kubernetesContext = kubernetesContext
        self.awsTarget = awsTarget
        self.awsProfile = awsProfile
        self.awsRegion = awsRegion
    }
}

public extension ExportableConnection {
    static let importBlockedAdditionalFieldKeys: Set<String> = [
        "preconnectscript",
        "pretunnelhost",
        "pretunnelport",
        "promptforpassword",
        "sslclientkeypassphrase",
        "usepgpass",
    ]

    static let importBlockedAdditionalFieldPrefixes: Set<String> = ["aws"]

    static func isImportBlockedAdditionalFieldKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        if importBlockedAdditionalFieldKeys.contains(normalized) { return true }
        return importBlockedAdditionalFieldPrefixes.contains { normalized.hasPrefix($0) }
    }

    func withoutStartupCommands() -> ExportableConnection {
        guard startupCommands != nil else { return self }
        return ExportableConnection(
            name: name, host: host, port: port, database: database,
            username: username, type: type, sshConfig: sshConfig,
            sslConfig: sslConfig, color: color, tagName: tagName, tagNames: tagNames,
            groupName: groupName, sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel, aiPolicy: aiPolicy,
            additionalFields: additionalFields, redisDatabase: redisDatabase,
            startupCommands: nil, localOnly: localOnly,
            tunnelCommand: tunnelCommand
        )
    }

    var carriesTunnelCommand: Bool { tunnelCommand != nil }

    func withoutTunnelCommand() -> ExportableConnection {
        guard tunnelCommand != nil else { return self }
        return ExportableConnection(
            name: name, host: host, port: port, database: database,
            username: username, type: type, sshConfig: sshConfig,
            sslConfig: sslConfig, color: color, tagName: tagName, tagNames: tagNames,
            groupName: groupName, sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel, aiPolicy: aiPolicy,
            additionalFields: additionalFields, redisDatabase: redisDatabase,
            startupCommands: startupCommands, localOnly: localOnly,
            tunnelCommand: nil
        )
    }

    func sanitizedForImport() -> ExportableConnection {
        guard let additionalFields else { return self }
        let allowed = additionalFields.filter { !Self.isImportBlockedAdditionalFieldKey($0.key) }
        guard allowed.count != additionalFields.count else { return self }
        return ExportableConnection(
            name: name, host: host, port: port, database: database,
            username: username, type: type, sshConfig: sshConfig,
            sslConfig: sslConfig, color: color, tagName: tagName, tagNames: tagNames,
            groupName: groupName, sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel, aiPolicy: aiPolicy,
            additionalFields: allowed.isEmpty ? nil : allowed, redisDatabase: redisDatabase,
            startupCommands: startupCommands, localOnly: localOnly,
            tunnelCommand: tunnelCommand
        )
    }
}

// MARK: - SSH Config

public struct ExportableSSHConfig: Codable, Sendable {
    public let enabled: Bool
    public let host: String
    public let port: Int?
    public let username: String
    public let authMethod: String
    public let privateKeyPath: String
    public let agentSocketPath: String
    public let jumpHosts: [ExportableJumpHost]?
    public let totpMode: String?
    public let totpAlgorithm: String?
    public let totpDigits: Int?
    public let totpPeriod: Int?

    public init(
        enabled: Bool,
        host: String,
        port: Int?,
        username: String,
        authMethod: String,
        privateKeyPath: String,
        agentSocketPath: String,
        jumpHosts: [ExportableJumpHost]?,
        totpMode: String?,
        totpAlgorithm: String?,
        totpDigits: Int?,
        totpPeriod: Int?
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.agentSocketPath = agentSocketPath
        self.jumpHosts = jumpHosts
        self.totpMode = totpMode
        self.totpAlgorithm = totpAlgorithm
        self.totpDigits = totpDigits
        self.totpPeriod = totpPeriod
    }
}

public struct ExportableJumpHost: Codable, Sendable {
    public let host: String
    public let port: Int?
    public let username: String
    public let authMethod: String
    public let privateKeyPath: String

    public init(host: String, port: Int?, username: String, authMethod: String, privateKeyPath: String) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
    }
}

// MARK: - SSL Config

public struct ExportableSSLConfig: Codable, Sendable {
    public let mode: String
    public let caCertificatePath: String?
    public let clientCertificatePath: String?
    public let clientKeyPath: String?

    public init(mode: String, caCertificatePath: String?, clientCertificatePath: String?, clientKeyPath: String?) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }
}

// MARK: - Group & Tag

public struct ExportableGroup: Codable, Sendable {
    public let name: String
    public let color: String?

    public init(name: String, color: String?) {
        self.name = name
        self.color = color
    }
}

public struct ExportableTag: Codable, Sendable {
    public let name: String
    public let color: String?

    public init(name: String, color: String?) {
        self.name = name
        self.color = color
    }
}

// MARK: - Credentials

public struct ExportableCredentials: Codable, Sendable {
    public let password: String?
    public let sshPassword: String?
    public let keyPassphrase: String?
    public let sslClientKeyPassphrase: String?
    public let totpSecret: String?
    public let pluginSecureFields: [String: String]?

    public init(
        password: String?,
        sshPassword: String?,
        keyPassphrase: String?,
        sslClientKeyPassphrase: String?,
        totpSecret: String?,
        pluginSecureFields: [String: String]?
    ) {
        self.password = password
        self.sshPassword = sshPassword
        self.keyPassphrase = keyPassphrase
        self.sslClientKeyPassphrase = sslClientKeyPassphrase
        self.totpSecret = totpSecret
        self.pluginSecureFields = pluginSecureFields
    }
}

// MARK: - Path Portability

public enum PathPortability {
    public static func contractHome(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    public static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
}
