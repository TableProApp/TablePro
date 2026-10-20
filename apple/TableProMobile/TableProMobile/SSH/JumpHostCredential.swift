import Foundation
import TableProDatabase
import TableProModels

nonisolated enum JumpHostCredential: Codable, Equatable, Sendable {
    case sshServerKey
    case privateKey(key: String, passphrase: String?)
}

// One Keychain item per connection, a map from hop id to credential, so Duplicate, delete and the
// sync purge reach hop keys through the connection id alone.
nonisolated enum JumpHostCredentialStore {
    static func load(for connectionId: UUID, in secureStore: any SecureStore) throws -> [UUID: JumpHostCredential] {
        guard let stored = try secureStore.retrieve(forKey: account(for: connectionId)), !stored.isEmpty else {
            return [:]
        }
        return try decode(stored)
    }

    static func save(
        _ credentials: [UUID: JumpHostCredential],
        for connectionId: UUID,
        in secureStore: any SecureStore
    ) throws {
        guard !credentials.isEmpty else {
            try secureStore.delete(forKey: account(for: connectionId))
            return
        }
        try secureStore.store(encode(credentials), forKey: account(for: connectionId))
    }

    static func encode(_ credentials: [UUID: JumpHostCredential]) throws -> String {
        let keyed = Dictionary(uniqueKeysWithValues: credentials.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(keyed), as: UTF8.self)
    }

    // A .tablepro hop carries no id, so a replaced connection's hops would lose their keys. Each
    // incoming hop takes the id of the first unused stored hop with the same host, port and username.
    static func keepingHopIds(from stored: SSHConfiguration?, into incoming: SSHConfiguration?) -> SSHConfiguration? {
        guard let stored, var merged = incoming else { return incoming }
        var unused = stored.jumpHosts
        for index in merged.jumpHosts.indices {
            let hop = merged.jumpHosts[index]
            guard let match = unused.firstIndex(where: {
                $0.host == hop.host && $0.resolvedPort == hop.resolvedPort && $0.username == hop.username
            }) else { continue }
            merged.jumpHosts[index].id = unused.remove(at: match).id
        }
        return merged
    }

    private static func decode(_ stored: String) throws -> [UUID: JumpHostCredential] {
        let keyed = try JSONDecoder().decode([String: JumpHostCredential].self, from: Data(stored.utf8))
        var credentials: [UUID: JumpHostCredential] = [:]
        for (key, credential) in keyed {
            guard let hopId = UUID(uuidString: key) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "A jump host key is not stored under a hop id")
                )
            }
            credentials[hopId] = credential
        }
        return credentials
    }

    private static func account(for connectionId: UUID) -> String {
        ConnectionSecretKind.jumpHostKeys.account(for: connectionId)
    }
}
