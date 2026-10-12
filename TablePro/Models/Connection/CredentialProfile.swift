//
//  CredentialProfile.swift
//  TablePro
//

import Foundation

/// Where a profile's password comes from, which is the same vocabulary a connection already has.
///
/// The payload of `.source` never leaves this Mac. It can name a shell command, and a command that
/// arrived over iCloud or inside a shared export file would be one this Mac never agreed to run.
enum CredentialPasswordMode: Hashable, Sendable {
    /// In the Keychain, under the profile's own id.
    case stored
    /// Asked for on every connect.
    case prompt
    case source(PasswordSource)
    /// Looked up in `~/.pgpass` by host, port, database and username.
    case pgpass
}

extension CredentialPasswordMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, source
    }

    private enum Kind: String, Codable {
        case stored, prompt, source, pgpass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stored:
            self = .stored
        case .prompt:
            self = .prompt
        case .pgpass:
            self = .pgpass
        case .source:
            /// A malformed payload becomes a prompt rather than failing the whole store: one
            /// unreadable profile must not take every other profile down with it.
            guard let source = PasswordSource.resilientlyDecoded(from: container, forKey: .source) else {
                self = .prompt
                return
            }
            self = .source(source)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stored:
            try container.encode(Kind.stored, forKey: .kind)
        case .prompt:
            try container.encode(Kind.prompt, forKey: .kind)
        case .pgpass:
            try container.encode(Kind.pgpass, forKey: .kind)
        case .source(let source):
            try container.encode(Kind.source, forKey: .kind)
            try container.encode(source, forKey: .source)
        }
    }
}

/// One set of database credentials, named, that any number of connections point at.
///
/// The point of the type is that the secret exists once. A connection linked to a profile holds no
/// Keychain item of its own, so rotating the password is one edit rather than one edit per
/// connection, which is what issue #2853 asked for.
struct CredentialProfile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var username: String
    var passwordMode: CredentialPasswordMode

    /// Plugin-declared secure fields this profile carries, such as an AWS secret access key. The
    /// values are in the Keychain under the profile's id; only the ids are stored here.
    ///
    /// There is no database type on the profile, because a connection only ever reads the fields
    /// its own type declares: `DatabaseDriverFactory.buildAdditionalFields` loops over
    /// `secureConnectionFieldIds(for: connection.type)`, so a field another engine's profile
    /// carries is never looked at.
    var secureFieldIds: [String]
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        username: String = "",
        passwordMode: CredentialPasswordMode = .stored,
        secureFieldIds: [String] = [],
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.passwordMode = passwordMode
        self.secureFieldIds = secureFieldIds
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, username, passwordMode, secureFieldIds, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        passwordMode = try container.decodeIfPresent(CredentialPasswordMode.self, forKey: .passwordMode) ?? .stored
        secureFieldIds = try container.decodeIfPresent([String].self, forKey: .secureFieldIds) ?? []
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    /// What the picker and the profile list show beside the name.
    var summary: String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return passwordMode.displayName }
        return "\(trimmed), \(passwordMode.displayName)"
    }
}

extension CredentialPasswordMode {
    var displayName: String {
        switch self {
        case .stored: String(localized: "Saved password")
        case .prompt: String(localized: "Ask every time")
        case .pgpass: String(localized: "~/.pgpass")
        case .source: String(localized: "Password source")
        }
    }

    /// Whether this mode keeps a secret in the Keychain under the profile's id.
    var usesStoredSecret: Bool {
        if case .stored = self { return true }
        return false
    }
}
