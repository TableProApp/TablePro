import Foundation
import UniformTypeIdentifiers

public extension UTType {
    static let tableproConnectionShare = UTType(exportedAs: "com.tablepro.connection-share")
}

public enum PortableSSLMode: String, Sendable, CaseIterable {
    case disabled = "Disabled"
    case preferred = "Preferred"
    case required = "Required"
    case verifyCA = "Verify CA"
    case verifyIdentity = "Verify Identity"

    /// Reads the Mac raw values, the iOS ones (disable, prefer, require, verifyCa, verifyFull) and the libpq
    /// ones (verify-ca, verify-full), ignoring case, spaces, underscores and hyphens.
    public init?(carrying raw: String) {
        let key = raw.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        switch key {
        case "disabled", "disable":
            self = .disabled
        case "preferred", "prefer":
            self = .preferred
        case "required", "require":
            self = .required
        case "verifyca":
            self = .verifyCA
        case "verifyidentity", "verifyfull":
            self = .verifyIdentity
        default:
            return nil
        }
    }
}

public struct ExportableSSLConfig: Codable, Sendable, Equatable {
    public var mode: String
    public var caCertificatePath: String?
    public var clientCertificatePath: String?
    public var clientKeyPath: String?

    private enum CodingKeys: String, CodingKey {
        case mode, caCertificatePath, clientCertificatePath, clientKeyPath
    }

    public var portableMode: PortableSSLMode? { PortableSSLMode(carrying: mode) }

    public init(
        mode: String,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil
    ) {
        self.mode = PortableSSLMode(carrying: mode)?.rawValue ?? mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(String.self, forKey: .mode),
            caCertificatePath: try container.decodeIfPresent(String.self, forKey: .caCertificatePath),
            clientCertificatePath: try container.decodeIfPresent(String.self, forKey: .clientCertificatePath),
            clientKeyPath: try container.decodeIfPresent(String.self, forKey: .clientKeyPath)
        )
    }
}

public struct ExportableConnection: Codable, Sendable, Equatable {
    public var name: String
    public var host: String
    public var port: Int
    public var database: String
    public var username: String
    public var type: String
    public var sshConfig: ExportableSSHConfig?
    public var sslConfig: ExportableSSLConfig?
    public var color: String?
    public var sshProfileId: String?
    public var safeModeLevel: String?
    public var aiPolicy: String?
    public var connectTimeoutSeconds: Int?
    public var queryTimeoutSeconds: Int?
    public var additionalFields: [String: String]?
    public var redisDatabase: Int?
    public var startupCommands: String?
    public var localOnly: Bool?
    public var tunnelCommand: ExportableTunnelCommand?

    public init(
        name: String,
        host: String,
        port: Int,
        database: String,
        username: String,
        type: String,
        sshConfig: ExportableSSHConfig? = nil,
        sslConfig: ExportableSSLConfig? = nil,
        color: String? = nil,
        sshProfileId: String? = nil,
        safeModeLevel: String? = nil,
        aiPolicy: String? = nil,
        connectTimeoutSeconds: Int? = nil,
        queryTimeoutSeconds: Int? = nil,
        additionalFields: [String: String]? = nil,
        redisDatabase: Int? = nil,
        startupCommands: String? = nil,
        localOnly: Bool? = nil,
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
        self.sshProfileId = sshProfileId
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
}

public extension ExportableConnection {
    private static let connectTimeoutSecondsKey = "connectTimeoutSeconds"
    private static let queryTimeoutSecondsKey = "queryTimeoutSeconds"
    private static let connectTimeoutSecondsRange = 1 ... 600
    private static let queryTimeoutSecondsRange = 0 ... Int(Int32.max) / 1_000

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

    var carriesTunnelCommand: Bool { tunnelCommand != nil }

    var carriesStartupCommands: Bool {
        !(startupCommands?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func withoutStartupCommands() -> ExportableConnection {
        var copy = self
        copy.startupCommands = nil
        return copy
    }

    func withoutTunnelCommand() -> ExportableConnection {
        var copy = self
        copy.tunnelCommand = nil
        return copy
    }

    /// An explicit timeout that is out of range is dropped, not replaced by a legacy additional field.
    func sanitizedForImport() -> ExportableConnection {
        var allowed = (additionalFields ?? [:]).filter { !Self.isImportBlockedAdditionalFieldKey($0.key) }
        let legacyConnectTimeout = allowed.removeValue(forKey: Self.connectTimeoutSecondsKey).flatMap(Int.init)
        let legacyQueryTimeout = allowed.removeValue(forKey: Self.queryTimeoutSecondsKey).flatMap(Int.init)
        var copy = self
        copy.connectTimeoutSeconds = (connectTimeoutSeconds ?? legacyConnectTimeout).flatMap {
            Self.connectTimeoutSecondsRange.contains($0) ? $0 : nil
        }
        copy.queryTimeoutSeconds = (queryTimeoutSeconds ?? legacyQueryTimeout).flatMap {
            Self.queryTimeoutSecondsRange.contains($0) ? $0 : nil
        }
        copy.additionalFields = allowed.isEmpty ? nil : allowed
        return copy
    }
}

/// The only exported field that describes a process TablePro would start. Import keeps it only after the user
/// confirms; a deeplink and the team library drop it before anyone is asked.
public struct ExportableTunnelCommand: Codable, Sendable, Equatable {
    public var method: String
    public var command: String?
    public var executablePath: String?
    public var kubernetesNamespace: String?
    public var kubernetesResource: String?
    public var kubernetesContext: String?
    public var awsTarget: String?
    public var awsProfile: String?
    public var awsRegion: String?

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

public struct ExportableSSHConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int?
    public var username: String
    public var authMethod: String
    public var privateKeyPath: String
    public var agentSocketPath: String
    public var jumpHosts: [ExportableJumpHost]?
    public var totpMode: String?
    public var totpAlgorithm: String?
    public var totpDigits: Int?
    public var totpPeriod: Int?
    public var remoteFilePath: String?
    /// `onServer` or `readOnlyCopy`, as the raw value. Nil means the copy.
    public var remoteFileAccess: String?

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

public struct ExportableJumpHost: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int?
    public var username: String
    public var authMethod: String
    public var privateKeyPath: String

    public init(host: String, port: Int?, username: String, authMethod: String, privateKeyPath: String) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
    }
}

public struct ExportableCredentials: Codable, Sendable, Equatable {
    public var password: String?
    public var sshPassword: String?
    public var keyPassphrase: String?
    public var sslClientKeyPassphrase: String?
    public var totpSecret: String?
    public var pluginSecureFields: [String: String]?

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

extension ExportableCredentials {
    var isEmpty: Bool {
        password == nil && sshPassword == nil && keyPassphrase == nil && sslClientKeyPassphrase == nil
            && totpSecret == nil && (pluginSecureFields ?? [:]).isEmpty
    }
}

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
