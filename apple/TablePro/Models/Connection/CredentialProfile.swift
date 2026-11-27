import Foundation

// The .source payload never leaves this Mac: it can name a shell command this Mac never agreed to run.
enum CredentialPasswordMode: Hashable, Sendable {
    case stored
    case prompt
    case source(PasswordSource)
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
            // A malformed payload becomes a prompt, so one bad profile does not fail the whole store.
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

// The secret exists once: a linked connection holds no Keychain item of its own (#2853).
struct CredentialProfile: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var username: String
    var passwordMode: CredentialPasswordMode

    // No database type here: a connection reads only the secure fields its own type declares.
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

    var summary: String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return passwordMode.displayName }
        return "\(trimmed), \(passwordMode.displayName)"
    }
}

// One vocabulary for the editor's picker, the profile list and the connection form.
enum CredentialPasswordKind: String, CaseIterable, Identifiable, Sendable {
    case stored, prompt, pgpass, source

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stored: String(localized: "Saved in Keychain")
        case .prompt: String(localized: "Ask Every Time")
        case .pgpass: String(localized: "~/.pgpass")
        case .source: String(localized: "Password Source")
        }
    }

    var help: String {
        switch self {
        case .stored:
            String(localized: "Saved in the Keychain once and used by every connection on this profile.")
        case .prompt:
            String(localized: "Every connection using this profile asks for the password once each time TablePro runs.")
        case .pgpass:
            String(localized: """
                Looked up in ~/.pgpass by the host, port, database and username of the PostgreSQL-family connection \
                that is opening. Other connections ask for the password.
                """)
        case .source:
            String(localized: "It stays on this Mac and never syncs, because it can name a command to run.")
        }
    }
}

extension CredentialPasswordMode {
    var kind: CredentialPasswordKind {
        switch self {
        case .stored: .stored
        case .prompt: .prompt
        case .pgpass: .pgpass
        case .source: .source
        }
    }

    // A Vault role also supplies the username, so the row and the connection form name it.
    var displayName: String {
        if case .source(.vaultDatabaseRole) = self { return String(localized: "Vault database role") }
        return kind.displayName
    }

    var usesStoredSecret: Bool {
        if case .stored = self { return true }
        return false
    }
}
