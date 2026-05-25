//
//  CloudflareConfiguration.swift
//  TablePro
//

import Foundation

/// How TablePro authenticates the cloudflared subprocess to Cloudflare Access.
enum CloudflareAuthMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case browserSSO
    case serviceToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .browserSSO: return String(localized: "Browser Sign-In")
        case .serviceToken: return String(localized: "Service Token")
        }
    }
}

/// Cloudflare Access TCP tunnel configuration for a database connection.
/// cloudflared opens the local listener itself via `--url`, so TablePro only
/// chooses the loopback port and supervises the process.
struct CloudflareConfiguration: Codable, Hashable, Sendable {
    var accessHostname: String = ""
    var localPort: Int?
    var authMethod: CloudflareAuthMethod = .browserSSO
    var exposeToLAN: Bool = false
    var binaryPath: String = ""

    var isValid: Bool {
        !accessHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension CloudflareConfiguration {
    private enum CodingKeys: String, CodingKey {
        case accessHostname, localPort, authMethod, exposeToLAN, binaryPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessHostname = try container.decodeIfPresent(String.self, forKey: .accessHostname) ?? ""
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort)
        authMethod = try container.decodeIfPresent(CloudflareAuthMethod.self, forKey: .authMethod) ?? .browserSSO
        exposeToLAN = try container.decodeIfPresent(Bool.self, forKey: .exposeToLAN) ?? false
        binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath) ?? ""
    }
}
