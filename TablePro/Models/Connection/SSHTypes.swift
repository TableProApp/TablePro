//
//  SSHTypes.swift
//  TablePro
//

import Foundation
/// SSH authentication method
enum SSHAuthMethod: String, CaseIterable, Identifiable, Codable {
    case password = "Password"
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"
    case keyboardInteractive = "Keyboard Interactive"
    case none = "None"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .privateKey: return String(localized: "Private Key")
        case .sshAgent: return String(localized: "SSH Agent")
        case .keyboardInteractive: return String(localized: "Keyboard Interactive")
        case .none: return String(localized: "None")
        }
    }

    var iconName: String {
        switch self {
        case .password: return "key.fill"
        case .privateKey: return "doc.text.fill"
        case .sshAgent: return "person.badge.key.fill"
        case .keyboardInteractive: return "keyboard"
        case .none: return "key.slash"
        }
    }

    var supportsTwoFactorAuthentication: Bool {
        self != .none
    }
}

extension SSHAuthMethod {
    /// iPhone and iPad wrote the case name ("sshAgent", "privateKey") into `sshConfigJson` and into
    /// `.tablepro` files before the two sides agreed on these raw values, and a strict decode read
    /// every one of them as Password: an agent or key tunnel that silently stopped authenticating,
    /// and that the next push from this Mac then wrote back as Password for good. Both spellings
    /// decode, so a connection synced from an already-shipped iOS build is read as it was meant.
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

enum SSHAgentSocketOption: String, CaseIterable, Identifiable {
    case systemDefault
    case onePassword
    case custom

    static let onePasswordSocketPath = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    private static let onePasswordAliasPath = "~/.1password/agent.sock"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault:
            return "SSH_AUTH_SOCK"
        case .onePassword:
            return "1Password"
        case .custom:
            return String(localized: "Custom Path")
        }
    }

    /// Says which agent the choice actually reaches. `SSH_AUTH_SOCK` is the ssh-agent macOS
    /// starts for the login session, so it never finds 1Password however the shell is set up,
    /// and the connect used to fail with a passphrase prompt for an unrelated key (#2583).
    var explanation: String {
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

    init(socketPath: String) {
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

    func resolvedPath(customPath: String) -> String {
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

enum SSHJumpAuthMethod: String, CaseIterable, Identifiable, Codable {
    case privateKey = "Private Key"
    case sshAgent = "SSH Agent"

    var id: String { rawValue }

    /// Same rule as `SSHAuthMethod` above: a hop an iOS build wrote names its case, not its raw
    /// value, and a strict decode threw `dataCorrupted` inside `jumpHosts`, which took the whole
    /// SSH configuration and with it the connection.
    init(carrying raw: String) {
        switch raw {
        case Self.privateKey.rawValue, "privateKey", "publicKey": self = .privateKey
        default: self = .sshAgent
        }
    }

    init(from decoder: Decoder) throws {
        self.init(carrying: try decoder.singleValueContainer().decode(String.self))
    }
}

struct SSHJumpHost: Codable, Hashable, Identifiable {
    var id = UUID()
    var host: String = ""
    var port: Int?
    var username: String = ""
    var authMethod: SSHJumpAuthMethod = .sshAgent
    var privateKeyPath: String = ""

    var isValid: Bool {
        // Username and port may be empty: the runtime resolver fills them
        // from ~/.ssh/config (User, Port directives) when the alias matches.
        !host.isEmpty && (authMethod == .sshAgent || !privateKeyPath.isEmpty)
    }

    var proxyJumpString: String {
        "\(username)@\(host):\(port ?? 22)"
    }
}

extension SSHJumpHost {
    enum CodingKeys: String, CodingKey {
        case id, host, port, username, authMethod, privateKeyPath
    }

    /// Same rule as `SSHConfiguration` below: every property has a default, so every key decodes as
    /// optional. A required decode threw `keyNotFound` on a hop an older iOS build wrote without
    /// `authMethod`, and that failure took the whole connection out of the sync pull.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = (try? container.decodeIfPresent(SSHJumpAuthMethod.self, forKey: .authMethod)) ?? .sshAgent
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
    }
}

/// How a file-backed connection reaches a database file that lives on an SSH server.
enum RemoteFileAccess: String, Codable, Hashable, Sendable {
    /// Fetch a snapshot over SFTP and open the copy on this Mac, read-only. The original is never
    /// written. This is what a connection saved before the live mode existed decodes to.
    case readOnlyCopy
    /// Run statements on the server against the live database through the SQLite agent, so reads
    /// and writes act on the file the server's own programs are using.
    case onServer
}

/// SSH tunnel configuration for database connections
struct SSHConfiguration: Codable, Hashable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int?
    var username: String = ""
    var authMethod: SSHAuthMethod = .password
    var privateKeyPath: String = ""
    var agentSocketPath: String = ""
    var jumpHosts: [SSHJumpHost] = []
    var totpMode: TOTPMode = .none
    var totpAlgorithm: TOTPAlgorithm = .sha1
    var totpDigits: Int = 6
    var totpPeriod: Int = 30

    /// The database file on the SSH server, for a connection whose driver opens a file rather than
    /// reaching a port. Empty means this configuration forwards TCP, which is what every
    /// server-backed connection does.
    ///
    /// A leading `~` and a relative path are both left as the user typed them and resolved against
    /// the account's home at connect time. SFTP performs no expansion of its own and rejects a
    /// literal `~/x` outright, so resolving early would only move the failure somewhere less
    /// explainable.
    var remoteFilePath: String = ""

    /// Whether the named file is opened as a read-only copy on this Mac or as a live session on the
    /// server. Defaults to the copy, so a configuration written before the live mode existed keeps
    /// its old behaviour, and an older app that cannot decode this key falls back the same way.
    var remoteFileAccess: RemoteFileAccess = .readOnlyCopy

    var forwardsRemoteFile: Bool { enabled && !remoteFilePath.isEmpty }

    /// Username may be empty: the runtime resolver supplies `User` from
    /// `~/.ssh/config` when the host is an alias.
    var isValid: Bool {
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

    /// Every property here declares a default, so every key decodes as optional. A required decode
    /// on a field that has a default cannot round-trip a payload written before that field existed:
    /// it throws `keyNotFound` and takes the whole connection with it, because a connection that
    /// fails to decode is a connection the user no longer has. `agentSocketPath` was the one still
    /// required, which is why a stored SSH config from before it existed could not be read back.
    init(from decoder: Decoder) throws {
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

// MARK: - SSL Configuration
