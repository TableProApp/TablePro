import Foundation
import TableProConnectionLibrary
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
    public let credentialProfiles: [ExportableCredentialProfile]?

    public init(
        formatVersion: Int,
        exportedAt: Date,
        appVersion: String,
        connections: [ExportableConnection],
        groups: [ExportableGroup]?,
        tags: [ExportableTag]?,
        credentials: [String: ExportableCredentials]?,
        credentialProfiles: [ExportableCredentialProfile]? = nil
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.connections = connections
        self.groups = groups
        self.tags = tags
        self.credentials = credentials
        self.credentialProfiles = credentialProfiles
    }
}

/// A credential profile in an export bundle: enough to re-create it by name on the importing Mac,
/// and nothing that executes.
///
/// `passwordMode` is one of `stored`, `prompt` or `pgpass`. A profile reading its password from a
/// file or a command exports as `prompt`, because a shared bundle that carried a shell command
/// would run it on a Mac that never agreed to it.
public struct ExportableCredentialProfile: Codable, Sendable {
    public let name: String
    public let username: String
    public let passwordMode: String
    public let secureFieldIds: [String]?

    public init(name: String, username: String, passwordMode: String, secureFieldIds: [String]? = nil) {
        self.name = name
        self.username = username
        self.passwordMode = passwordMode
        self.secureFieldIds = secureFieldIds
    }
}

// MARK: - Exportable Connection

public struct ExportableConnection: Codable, Sendable {
    private static let queryTimeoutSecondsRange = 0 ... Int(Int32.max) / 1_000
    public private(set) var name: String
    public private(set) var host: String
    public private(set) var port: Int
    public private(set) var database: String
    public private(set) var username: String
    public private(set) var type: String
    public private(set) var sshConfig: ExportableSSHConfig?
    public private(set) var sslConfig: ExportableSSLConfig?
    public private(set) var color: String?
    public private(set) var iconName: String?
    public private(set) var tagName: String?
    public private(set) var tagNames: [String]?
    public private(set) var groupName: String?
    public private(set) var sshProfileId: String?
    public private(set) var sshProfileName: String?
    public private(set) var credentialProfileName: String?
    public private(set) var safeModeLevel: String?
    public private(set) var aiPolicy: String?
    public private(set) var connectTimeoutSeconds: Int?
    public private(set) var queryTimeoutSeconds: Int?
    public private(set) var additionalFields: [String: String]?
    public private(set) var redisDatabase: Int?
    public private(set) var startupCommands: String?
    public private(set) var localOnly: Bool?
    public private(set) var tunnelCommand: ExportableTunnelCommand?

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
        iconName: String? = nil,
        tagName: String?,
        tagNames: [String]? = nil,
        groupName: String?,
        sshProfileId: String?,
        sshProfileName: String? = nil,
        credentialProfileName: String? = nil,
        safeModeLevel: String?,
        aiPolicy: String?,
        connectTimeoutSeconds: Int? = nil,
        queryTimeoutSeconds: Int? = nil,
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
        self.iconName = iconName
        self.tagName = tagName
        self.tagNames = tagNames
        self.groupName = groupName
        self.sshProfileId = sshProfileId
        self.sshProfileName = sshProfileName
        self.credentialProfileName = credentialProfileName
        self.safeModeLevel = safeModeLevel
        self.aiPolicy = aiPolicy
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.additionalFields = additionalFields
        self.redisDatabase = redisDatabase
        self.startupCommands = startupCommands
        self.localOnly = localOnly
        self.tunnelCommand = tunnelCommand
    }

    public func retyped(to newType: String) -> ExportableConnection {
        var copy = self
        copy.type = newType
        return copy
    }

    public func renamed(to newName: String) -> ExportableConnection {
        var copy = self
        copy.name = newName
        return copy
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
    private static let connectTimeoutSecondsKey = "connectTimeoutSeconds"
    private static let queryTimeoutSecondsKey = "queryTimeoutSeconds"

    static let importBlockedAdditionalFieldKeys: Set<String> = [
        "preconnectscript",
        "pretunnelhost",
        "pretunnelport",
        "promptforpassword",
        "spendpoint",
        "sslclientkeypassphrase",
        "usepgpass",
    ]

    static let importBlockedAdditionalFieldPrefixes: Set<String> = ["aws"]

    static func isImportBlockedAdditionalFieldKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        if importBlockedAdditionalFieldKeys.contains(normalized) { return true }
        return importBlockedAdditionalFieldPrefixes.contains { normalized.hasPrefix($0) }
    }

    static func shareableAdditionalFields(
        _ fields: [String: String],
        excluding excludedKeys: Set<String> = []
    ) -> [String: String]? {
        let shareable = fields.filter { key, _ in
            !excludedKeys.contains(key) && !isImportBlockedAdditionalFieldKey(key)
        }
        return shareable.isEmpty ? nil : shareable
    }

    func withoutStartupCommands() -> ExportableConnection {
        var copy = self
        copy.startupCommands = nil
        return copy
    }

    var carriesTunnelCommand: Bool { tunnelCommand != nil }

    func withoutTunnelCommand() -> ExportableConnection {
        var copy = self
        copy.tunnelCommand = nil
        return copy
    }

    func sanitizedForImport() -> ExportableConnection {
        var allowed = (additionalFields ?? [:]).filter { !Self.isImportBlockedAdditionalFieldKey($0.key) }
        let legacyConnectTimeout = allowed.removeValue(forKey: Self.connectTimeoutSecondsKey).flatMap(Int.init)
        let legacyQueryTimeout = allowed.removeValue(forKey: Self.queryTimeoutSecondsKey).flatMap(Int.init)
        var copy = self
        copy.connectTimeoutSeconds = (connectTimeoutSeconds ?? legacyConnectTimeout).flatMap {
            (1 ... 600).contains($0) ? $0 : nil
        }
        copy.queryTimeoutSeconds = (queryTimeoutSeconds ?? legacyQueryTimeout).flatMap {
            Self.queryTimeoutSecondsRange.contains($0) ? $0 : nil
        }
        copy.additionalFields = allowed.isEmpty ? nil : allowed
        copy.iconName = LibrarySymbolCatalog.normalizedName(iconName)
        return copy
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

    /// The database file on the SSH server, for a file-backed connection reached as a Remote
    /// Database File. Optional and defaulted so the many importers that never see one keep compiling
    /// and an export written before this field existed decodes with nil.
    public let remoteFilePath: String?

    /// How that file is opened, `onServer` or `readOnlyCopy`, as the raw value. Nil means the copy.
    public let remoteFileAccess: String?

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
        totpPeriod: Int?,
        remoteFilePath: String? = nil,
        remoteFileAccess: String? = nil
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
        self.remoteFilePath = remoteFilePath
        self.remoteFileAccess = remoteFileAccess
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
    public let iconName: String?

    public init(name: String, color: String?, iconName: String? = nil) {
        self.name = name
        self.color = color
        self.iconName = iconName
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
