import Foundation

public struct SSHConfiguration: Codable, Hashable, Sendable {
    public static let defaultPort = 22

    public var host: String

    /// Nil where the macOS form left the port unset, which is its default: the tunnel then takes
    /// `Port` from `~/.ssh/config`, or 22. Writing 22 back instead pins it and stops that lookup.
    public var port: Int?

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

    /// The raw values are the spellings the macOS app writes, because they are the only ones it
    /// reads back: its own `SSHAuthMethod(rawValue:)` is strict and falls back to Password, so a
    /// round trip that re-encoded the lowercase case name silently downgraded an agent or key
    /// tunnel. Decoding stays lenient so a connection an older iOS build stored still reads.
    public enum SSHAuthMethod: String, Codable, Sendable {
        case password = "Password"
        case privateKey = "Private Key"
        case sshAgent = "SSH Agent"
        case keyboardInteractive = "Keyboard Interactive"
        case none = "None"

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

    /// The port to dial. iOS reads no `~/.ssh/config`, so an unset port is the SSH default here.
    public var resolvedPort: Int { port ?? Self.defaultPort }

    public init(
        host: String = "",
        port: Int? = nil,
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
        port = try? container.decodeIfPresent(Int.self, forKey: .port)
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
        try container.encodeIfPresent(port, forKey: .port)
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

/// How a hop authenticates, in the two spellings the macOS app writes. A hop is never dialled from
/// iOS, so the value is carried rather than used, and the risk is carrying one macOS cannot read: an
/// already-shipped build decodes this raw value strictly, and a `dataCorrupted` thrown inside
/// `jumpHosts` takes the whole SSH configuration with it, and with that the connection. Every
/// shipped iOS build wrote the case name `sshAgent`, which is exactly such a value, so anything but
/// the two spellings normalizes here instead of being carried back out.
public enum SSHJumpAuthMethod: String, Codable, Sendable, CaseIterable {
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"

    public init(carrying raw: String) {
        switch raw {
        case "Private Key", "privateKey", "publicKey":
            self = .privateKey
        default:
            self = .sshAgent
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(carrying: try decoder.singleValueContainer().decode(String.self))
    }
}

public struct SSHJumpHost: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var host: String

    /// Nil where the macOS form left the port unset, which is its default: the hop then takes `Port`
    /// from `~/.ssh/config`, or 22. Writing 22 back instead pins the hop and stops that lookup.
    public var port: Int?
    public var username: String

    /// The hop's macOS credential, carried so a sync round trip gives it back. Both are always
    /// encoded: a hop without them fails the macOS decode and takes the whole connection with it.
    public var macAuthMethod: SSHJumpAuthMethod
    public var macPrivateKeyPath: String

    public init(
        id: UUID = UUID(),
        host: String = "",
        port: Int? = nil,
        username: String = "",
        macAuthMethod: SSHJumpAuthMethod = .sshAgent,
        macPrivateKeyPath: String = ""
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.macAuthMethod = macAuthMethod
        self.macPrivateKeyPath = macPrivateKeyPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, host, port, username, authMethod, privateKeyPath
    }

    /// Every key decodes as optional. The macOS app omits `port` whenever the hop has none, and a
    /// required decode there threw `keyNotFound` inside the `jumpHosts` array, which dropped every
    /// hop of that connection without a word.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        macAuthMethod = (try? container.decodeIfPresent(SSHJumpAuthMethod.self, forKey: .authMethod)) ?? .sshAgent
        macPrivateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(macAuthMethod, forKey: .authMethod)
        try container.encode(macPrivateKeyPath, forKey: .privateKeyPath)
    }
}
