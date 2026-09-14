//
//  SecretManagerSettings.swift
//  TablePro
//

import Foundation

/// How long a password fetched from a secret manager stays in memory before the command runs again.
///
/// A secret manager that asks for a fingerprint or a 2FA code turns every reconnect into a prompt,
/// and the health monitor reconnects on its own. The cache is what keeps an unattended reconnect
/// from putting a dialog in front of the user.
enum SecretCacheLifetime: Int, Codable, CaseIterable, Identifiable {
    case never = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case oneHour = 60
    case eightHours = 480

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .never: return String(localized: "Don't cache")
        case .fiveMinutes: return String(localized: "5 minutes")
        case .fifteenMinutes: return String(localized: "15 minutes")
        case .oneHour: return String(localized: "1 hour")
        case .eightHours: return String(localized: "8 hours")
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue) * 60
    }
}

/// Device-local, and deliberately so. A command names a CLI tool, a vault address and a login
/// session that belong to one machine, for the same reason a connection's own `PasswordSource`
/// is left out of sync.
struct SecretManagerSettings: Codable, Equatable {
    /// What a connection set to `.sharedTemplate` runs, with its placeholders filled in.
    var defaultCommand: String
    var cacheLifetime: SecretCacheLifetime

    static let `default` = SecretManagerSettings(defaultCommand: "", cacheLifetime: .fifteenMinutes)

    init(defaultCommand: String = "", cacheLifetime: SecretCacheLifetime = .fifteenMinutes) {
        self.defaultCommand = defaultCommand
        self.cacheLifetime = cacheLifetime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultCommand = try container.decodeIfPresent(String.self, forKey: .defaultCommand) ?? ""
        cacheLifetime = try container.decodeIfPresent(SecretCacheLifetime.self, forKey: .cacheLifetime)
            ?? .fifteenMinutes
    }

    var trimmedDefaultCommand: String {
        defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasDefaultCommand: Bool {
        !trimmedDefaultCommand.isEmpty
    }
}
