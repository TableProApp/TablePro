//
//  CredentialMode.swift
//  TablePro
//

import Foundation

/// Where a connection's credentials come from: its own fields, or a named profile shared with
/// every other connection pointing at the same one.
///
/// There is no snapshot here, unlike `SSHTunnelMode.profile(id:snapshot:)`. A snapshot in the
/// connection is what let an SSH profile edit reach a linked connection's password and nothing
/// else, so a credential profile's values are written through to `username` and resolved from the
/// profile at connect instead.
enum CredentialMode: Hashable, Sendable {
    case inline
    case profile(id: UUID)

    var profileId: UUID? {
        guard case .profile(let id) = self else { return nil }
        return id
    }
}

extension CredentialMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case profileId
    }

    private enum Mode: String, Codable {
        case inline
        case profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .inline:
            self = .inline
        case .profile:
            self = .profile(id: try container.decode(UUID.self, forKey: .profileId))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inline:
            try container.encode(Mode.inline, forKey: .mode)
        case .profile(let id):
            try container.encode(Mode.profile, forKey: .mode)
            try container.encode(id, forKey: .profileId)
        }
    }
}
