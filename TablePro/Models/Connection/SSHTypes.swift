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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .privateKey: return String(localized: "Private Key")
        case .sshAgent: return String(localized: "SSH Agent")
        case .keyboardInteractive: return String(localized: "Keyboard Interactive")
        }
    }

    var iconName: String {
        switch self {
        case .password: return "key.fill"
        case .privateKey: return "doc.text.fill"
        case .sshAgent: return "person.badge.key.fill"
        case .keyboardInteractive: return "keyboard"
        }
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(SSHAuthMethod.self, forKey: .authMethod)
        privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        agentSocketPath = try container.decode(String.self, forKey: .agentSocketPath)
        jumpHosts = try container.decodeIfPresent([SSHJumpHost].self, forKey: .jumpHosts) ?? []
        totpMode = try container.decodeIfPresent(TOTPMode.self, forKey: .totpMode) ?? .none
        totpAlgorithm = try container.decodeIfPresent(TOTPAlgorithm.self, forKey: .totpAlgorithm) ?? .sha1
        totpDigits = try container.decodeIfPresent(Int.self, forKey: .totpDigits) ?? 6
        totpPeriod = try container.decodeIfPresent(Int.self, forKey: .totpPeriod) ?? 30
    }
}

// MARK: - SSL Configuration
