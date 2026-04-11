//
//  SSHTunnelMode.swift
//  TablePro
//

import Foundation

/// Single source of truth for how a connection handles SSH tunneling.
enum SSHTunnelMode: Hashable, Sendable {
    case disabled
    case inline(SSHConfiguration)
    case profile(id: UUID, snapshot: SSHConfiguration)
}

// MARK: - Codable

extension SSHTunnelMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case profileId
        case config
    }

    private enum Mode: String, Codable {
        case disabled
        case inline
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .disabled:
            self = .disabled
        case .inline:
            let config = try container.decode(SSHConfiguration.self, forKey: .config)
            self = .inline(config)
        case .profile:
            let profileId = try container.decode(UUID.self, forKey: .profileId)
            let config = try container.decode(SSHConfiguration.self, forKey: .config)
            self = .profile(id: profileId, snapshot: config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled:
            try container.encode(Mode.disabled, forKey: .mode)
        case .inline(let config):
            try container.encode(Mode.inline, forKey: .mode)
            try container.encode(config, forKey: .config)
        case .profile(let profileId, let snapshot):
            try container.encode(Mode.profile, forKey: .mode)
            try container.encode(profileId, forKey: .profileId)
            try container.encode(snapshot, forKey: .config)
        }
    }
}
