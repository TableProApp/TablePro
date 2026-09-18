import Foundation

public struct SSHConfiguration: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    public var privateKeyPath: String?
    public var jumpHosts: [SSHJumpHost]

    /// Fields the macOS app stores inside `sshConfigJson` that this model does not use, kept only so
    /// they survive an iOS sync round trip. Without them, re-encoding a synced connection on iOS
    /// dropped the macOS `enabled`, remote file path, agent socket and TOTP settings, and the macOS
    /// app then read the connection back with SSH turned off. Each is optional so a connection this
    /// model creates omits it and the macOS side keeps inferring `enabled` from a non-empty host.
    public var macEnabled: Bool?
    public var macUseSSHConfig: Bool?
    public var macAgentSocketPath: String?
    public var macRemoteFilePath: String?
    public var macRemoteFileAccess: String?
    public var macTotpMode: String?
    public var macTotpAlgorithm: String?
    public var macTotpDigits: Int?
    public var macTotpPeriod: Int?

    public enum SSHAuthMethod: String, Codable, Sendable {
        case password
        case privateKey
        case sshAgent
        case keyboardInteractive
        case none

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "password", "Password":
                self = .password
            case "privateKey", "publicKey", "Private Key":
                self = .privateKey
            case "sshAgent", "agent", "SSH Agent":
                self = .sshAgent
            case "keyboardInteractive", "Keyboard Interactive":
                self = .keyboardInteractive
            case "none", "None":
                self = .none
            default:
                self = .password
            }
        }
    }

    public init(
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: SSHAuthMethod = .password,
        privateKeyPath: String? = nil,
        jumpHosts: [SSHJumpHost] = []
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.jumpHosts = jumpHosts
    }

    // Custom Codable to handle macOS extra fields gracefully
    private enum CodingKeys: String, CodingKey {
        case host, port, username, authMethod, privateKeyPath, jumpHosts
        // macOS fields this model does not use but must preserve through a sync round trip.
        case enabled, useSSHConfig, agentSocketPath, remoteFilePath, remoteFileAccess
        case totpMode, totpAlgorithm, totpDigits, totpPeriod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? container.decode(String.self, forKey: .host)) ?? ""
        port = (try? container.decode(Int.self, forKey: .port)) ?? 22
        username = (try? container.decode(String.self, forKey: .username)) ?? ""
        authMethod = (try? container.decode(SSHAuthMethod.self, forKey: .authMethod)) ?? .password
        privateKeyPath = try? container.decode(String.self, forKey: .privateKeyPath)
        jumpHosts = (try? container.decode([SSHJumpHost].self, forKey: .jumpHosts)) ?? []
        macEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        macUseSSHConfig = try container.decodeIfPresent(Bool.self, forKey: .useSSHConfig)
        macAgentSocketPath = try container.decodeIfPresent(String.self, forKey: .agentSocketPath)
        macRemoteFilePath = try container.decodeIfPresent(String.self, forKey: .remoteFilePath)
        macRemoteFileAccess = try container.decodeIfPresent(String.self, forKey: .remoteFileAccess)
        macTotpMode = try container.decodeIfPresent(String.self, forKey: .totpMode)
        macTotpAlgorithm = try container.decodeIfPresent(String.self, forKey: .totpAlgorithm)
        macTotpDigits = try container.decodeIfPresent(Int.self, forKey: .totpDigits)
        macTotpPeriod = try container.decodeIfPresent(Int.self, forKey: .totpPeriod)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try container.encode(jumpHosts, forKey: .jumpHosts)
        try container.encodeIfPresent(macEnabled, forKey: .enabled)
        try container.encodeIfPresent(macUseSSHConfig, forKey: .useSSHConfig)
        try container.encodeIfPresent(macAgentSocketPath, forKey: .agentSocketPath)
        try container.encodeIfPresent(macRemoteFilePath, forKey: .remoteFilePath)
        try container.encodeIfPresent(macRemoteFileAccess, forKey: .remoteFileAccess)
        try container.encodeIfPresent(macTotpMode, forKey: .totpMode)
        try container.encodeIfPresent(macTotpAlgorithm, forKey: .totpAlgorithm)
        try container.encodeIfPresent(macTotpDigits, forKey: .totpDigits)
        try container.encodeIfPresent(macTotpPeriod, forKey: .totpPeriod)
    }
}

public struct SSHJumpHost: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var host: String
    public var port: Int
    public var username: String

    public init(
        id: UUID = UUID(),
        host: String = "",
        port: Int = 22,
        username: String = ""
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
    }
}
