import Foundation
import TableProSSHTransport

public enum SSHAuthMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case password = "Password"
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"
    case keyboardInteractive = "Keyboard Interactive"
    case none = "None"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .privateKey: return String(localized: "Private Key")
        case .sshAgent: return String(localized: "SSH Agent")
        case .keyboardInteractive: return String(localized: "Keyboard Interactive")
        case .none: return String(localized: "None")
        }
    }

    public var iconName: String {
        switch self {
        case .password: return "key.fill"
        case .privateKey: return "doc.text.fill"
        case .sshAgent: return "person.badge.key.fill"
        case .keyboardInteractive: return "keyboard"
        case .none: return "key.slash"
        }
    }

    public var supportsTwoFactorAuthentication: Bool {
        self != .none
    }
}

public extension SSHAuthMethod {
    // Shipped iOS builds wrote the case name ("sshAgent"), which a strict decode read back as Password.
    init(carrying raw: String) {
        switch raw {
        case Self.password.rawValue, "password": self = .password
        case Self.privateKey.rawValue, "privateKey", "publicKey": self = .privateKey
        case Self.sshAgent.rawValue, "sshAgent", "agent": self = .sshAgent
        case Self.keyboardInteractive.rawValue, "keyboardInteractive": self = .keyboardInteractive
        case Self.none.rawValue, "none": self = .none
        default: self = .password
        }
    }

    init(from decoder: Decoder) throws {
        self.init(carrying: try decoder.singleValueContainer().decode(String.self))
    }
}

public enum SSHAgentSocketOption: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case onePassword
    case custom

    public static let onePasswordSocketPath = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    private static let onePasswordAliasPath = "~/.1password/agent.sock"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemDefault:
            return "SSH_AUTH_SOCK"
        case .onePassword:
            return "1Password"
        case .custom:
            return String(localized: "Custom Path")
        }
    }

    // SSH_AUTH_SOCK is the login session's ssh-agent, which never reaches 1Password however the shell is set up (#2583).
    public var explanation: String {
        switch self {
        case .systemDefault:
            return String(
                localized: "The ssh-agent macOS runs, from SSH_AUTH_SOCK. 1Password and Secretive listen elsewhere."
            )
        case .onePassword:
            return String(localized: "1Password's own socket. 1Password has to be running and unlocked.")
        case .custom:
            return String(localized: "The socket of another agent, such as Secretive or an ssh-agent you started.")
        }
    }

    public init(socketPath: String) {
        let trimmedPath = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmedPath {
        case "":
            self = .systemDefault
        case Self.onePasswordSocketPath, Self.onePasswordAliasPath:
            self = .onePassword
        default:
            self = .custom
        }
    }

    public func resolvedPath(customPath: String) -> String {
        switch self {
        case .systemDefault:
            return ""
        case .onePassword:
            return Self.onePasswordSocketPath
        case .custom:
            return customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

public enum SSHJumpAuthMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .privateKey: return String(localized: "Private Key")
        case .sshAgent: return String(localized: "SSH Agent")
        }
    }

    // A hop an iOS build wrote names its case; a strict decode threw inside jumpHosts and lost the connection.
    public init(carrying raw: String) {
        switch raw {
        case Self.privateKey.rawValue, "privateKey", "publicKey": self = .privateKey
        default: self = .sshAgent
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(carrying: try decoder.singleValueContainer().decode(String.self))
    }
}

public struct SSHJumpHost: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var host: String = ""
    public var port: Int?
    public var username: String = ""
    public var authMethod: SSHJumpAuthMethod = .sshAgent
    public var privateKeyPath: String = ""

    public init(
        id: UUID = UUID(),
        host: String = "",
        port: Int? = nil,
        username: String = "",
        authMethod: SSHJumpAuthMethod = .sshAgent,
        privateKeyPath: String = ""
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
    }

    public var isValid: Bool {
        // Username and port may be empty: ~/.ssh/config fills them when the host is an alias.
        !host.isEmpty && (authMethod == .sshAgent || !privateKeyPath.isEmpty)
    }

    public var proxyJumpString: String {
        "\(username)@\(host):\(port ?? 22)"
    }
}

extension SSHJumpHost {
    enum CodingKeys: String, CodingKey {
        case id, host, port, username, authMethod, privateKeyPath
    }

    // Every key decodes as optional: a hop an older iOS build wrote without authMethod threw keyNotFound.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = (try? container.decodeIfPresent(SSHJumpAuthMethod.self, forKey: .authMethod)) ?? .sshAgent
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
    }
}

public enum RemoteFileAccess: String, Codable, Hashable, Sendable {
    // A read-only SFTP snapshot; what a connection saved before the live mode existed decodes to.
    case readOnlyCopy
    // Statements run on the server against the live file, through the SQLite agent.
    case onServer
}

public struct SSHConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool = false
    public var host: String = ""
    public var port: Int?
    public var username: String = ""
    public var authMethod: SSHAuthMethod = .password
    public var privateKeyPath: String = ""
    public var agentSocketPath: String = ""
    public var jumpHosts: [SSHJumpHost] = []
    public var totpMode: TOTPMode = .none
    public var totpAlgorithm: TOTPAlgorithm = .sha1
    public var totpDigits: Int = 6
    public var totpPeriod: Int = 30

    // Empty forwards TCP. `~` and relative paths stay as typed and resolve at connect time: SFTP expands neither.
    public var remoteFilePath: String = ""

    // Defaults to the copy, so a configuration from before the live mode, or an older app, keeps the old behaviour.
    public var remoteFileAccess: RemoteFileAccess = .readOnlyCopy

    public init(
        enabled: Bool = false,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        authMethod: SSHAuthMethod = .password,
        privateKeyPath: String = "",
        agentSocketPath: String = "",
        jumpHosts: [SSHJumpHost] = [],
        totpMode: TOTPMode = .none,
        totpAlgorithm: TOTPAlgorithm = .sha1,
        totpDigits: Int = 6,
        totpPeriod: Int = 30,
        remoteFilePath: String = "",
        remoteFileAccess: RemoteFileAccess = .readOnlyCopy
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

    public var forwardsRemoteFile: Bool { enabled && !remoteFilePath.isEmpty }

    // Username may be empty: ~/.ssh/config supplies User when the host is an alias.
    public var isValid: Bool {
        guard enabled else { return true }
        guard !host.isEmpty else { return false }
        return jumpHosts.allSatisfy(\.isValid)
    }
}

extension SSHConfiguration {
    enum CodingKeys: String, CodingKey {
        case enabled, host, port, username, authMethod, privateKeyPath, agentSocketPath, jumpHosts
        case totpMode, totpAlgorithm, totpDigits, totpPeriod
        case remoteFilePath
        case remoteFileAccess
    }

    // Every key decodes as optional: a payload written before a field existed must not lose the connection.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = (try? container.decodeIfPresent(SSHAuthMethod.self, forKey: .authMethod)) ?? .password
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        agentSocketPath = try container.decodeIfPresent(String.self, forKey: .agentSocketPath) ?? ""
        jumpHosts = try container.decodeIfPresent([SSHJumpHost].self, forKey: .jumpHosts) ?? []
        totpMode = try container.decodeIfPresent(TOTPMode.self, forKey: .totpMode) ?? .none
        totpAlgorithm = try container.decodeIfPresent(TOTPAlgorithm.self, forKey: .totpAlgorithm) ?? .sha1
        totpDigits = try container.decodeIfPresent(Int.self, forKey: .totpDigits) ?? 6
        totpPeriod = try container.decodeIfPresent(Int.self, forKey: .totpPeriod) ?? 30
        remoteFilePath = try container.decodeIfPresent(String.self, forKey: .remoteFilePath) ?? ""
        remoteFileAccess = try container.decodeIfPresent(RemoteFileAccess.self, forKey: .remoteFileAccess) ?? .readOnlyCopy
    }
}
