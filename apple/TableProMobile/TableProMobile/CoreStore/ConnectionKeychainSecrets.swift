import Foundation
import Security
import TableProDatabase
import TableProFFI

// The items earlier builds read, under the same names, so the previous stable keeps every password.
nonisolated final class ConnectionKeychainSecrets: HostSecrets, @unchecked Sendable {
    private let secureStore: any SecureStore

    init(secureStore: any SecureStore) {
        self.secureStore = secureStore
    }

    func load(connectionId: String, kind: SecretKindTag) throws -> String? {
        let key = try Self.key(kind, connectionId)
        do {
            return try secureStore.retrieve(forKey: key)
        } catch {
            throw Self.hostError(error)
        }
    }

    func store(connectionId: String, kind: SecretKindTag, secret: String, label: String) throws {
        let key = try Self.key(kind, connectionId)
        do {
            try secureStore.store(secret, forKey: key)
        } catch {
            throw Self.hostError(error)
        }
    }

    // iOS names its items itself.
    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {}

    func delete(connectionId: String, kind: SecretKindTag) throws {
        let key = try Self.key(kind, connectionId)
        do {
            try secureStore.delete(forKey: key)
        } catch {
            throw Self.hostError(error)
        }
    }

    // The core deletes a connection for a deletion another device made; AppState then removes its secrets, certificates
    // and files with the rest of its local state, and never the iCloud Keychain copies here.
    func deleteConnection(connectionId: String) throws {}

    // iOS only reads a profile's secrets, the Mac's iCloud Keychain items, and owns no profile, so the Mac deletes them.
    func deleteProfile(profileId: String, kind: ProfileKindTag) throws -> SecretDeletionTag {
        .notOwned
    }

    func loadItem(item: SecretItemTag) throws -> String? {
        throw Self.notHere
    }

    func storeItem(item: SecretItemTag, secret: String) throws {
        throw Self.notHere
    }

    func deleteItem(item: SecretItemTag) throws {
        throw Self.notHere
    }

    private static let notHere = HostSecretError.Unavailable(detail: "the account's core keeps this item")

    static func key(_ kind: SecretKindTag, _ connectionId: String) throws -> String {
        // The core writes ids in lower case; the items carry them as uuidString does.
        guard let id = UUID(uuidString: connectionId) else {
            throw HostSecretError.Failed(detail: "not a connection id")
        }
        switch kind {
        case .databasePassword: return ConnectionSecretKind.password.account(for: id)
        case .sshPassword: return ConnectionSecretKind.sshPassword.account(for: id)
        case .sshPassphrase: return ConnectionSecretKind.keyPassphrase.account(for: id)
        }
    }

    private static func hostError(_ error: any Error) -> HostSecretError {
        let status: OSStatus? = switch error as? KeychainError {
        case .storeFailed(let status), .retrieveFailed(let status), .deleteFailed(let status): status
        case nil: nil
        }
        if status == errSecInteractionNotAllowed {
            return .Locked
        }
        return .Failed(detail: status.map { "keychain status \($0)" } ?? "the keychain refused the call")
    }
}
