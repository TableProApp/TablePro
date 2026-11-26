//
//  ConnectionKeychainSecrets.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The items earlier builds read, under the same keys and scope, so the previous stable keeps every password.
nonisolated internal final class ConnectionKeychainSecrets: HostSecrets, @unchecked Sendable {
    private let keychain: any KeychainStoring
    private let keepsOnDevice: @Sendable (UUID) -> Bool

    init(keychain: any KeychainStoring, keepsOnDevice: @escaping @Sendable (UUID) -> Bool) {
        self.keychain = keychain
        self.keepsOnDevice = keepsOnDevice
    }

    func load(connectionId: String, kind: SecretKindTag) throws -> String? {
        let id = try Self.id(connectionId)
        switch keychain.readStringResult(forKey: Self.key(kind, id), deviceOnly: keepsOnDevice(id)) {
        case .found(let value):
            return value
        case .notFound:
            return nil
        case .locked:
            throw HostSecretError.Locked
        case .userCancelled:
            throw HostSecretError.Dismissed
        case .authFailed:
            throw HostSecretError.Failed(detail: "the keychain refused the read")
        case .error(let status):
            throw HostSecretError.Failed(detail: "keychain status \(status)")
        }
    }

    func store(connectionId: String, kind: SecretKindTag, secret: String, label: String) throws {
        let id = try Self.id(connectionId)
        guard keychain.writeString(secret, forKey: Self.key(kind, id), deviceOnly: keepsOnDevice(id)) else {
            throw HostSecretError.Failed(detail: "the keychain refused the write")
        }
    }

    // The Mac names its items itself.
    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {}

    func delete(connectionId: String, kind: SecretKindTag) throws {
        let id = try Self.id(connectionId)
        keychain.delete(forKey: Self.key(kind, id), deviceOnly: keepsOnDevice(id))
    }

    // The core deletes a connection for a deletion another device made, which leaves the iCloud Keychain items to it.
    func deleteConnection(connectionId: String) throws {
        let id = try Self.id(connectionId)
        let keys = keychain.deviceOnlyKeys(endingWith: ".\(id.uuidString)").filter { key in
            key.hasPrefix("com.TablePro.") && !key.hasPrefix(CredentialProfileStorage.secretKeyPrefix)
        }
        for key in keys {
            keychain.delete(forKey: key, deviceOnly: true)
        }
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

    static func key(_ kind: SecretKindTag, _ id: UUID) -> String {
        switch kind {
        case .databasePassword: "com.TablePro.password.\(id.uuidString)"
        case .sshPassword: "com.TablePro.sshpassword.\(id.uuidString)"
        case .sshPassphrase: "com.TablePro.keypassphrase.\(id.uuidString)"
        }
    }

    // The core writes ids in lower case; the Mac's keys carry them as uuidString does.
    private static func id(_ connectionId: String) throws -> UUID {
        guard let id = UUID(uuidString: connectionId) else {
            throw HostSecretError.Failed(detail: "not a connection id")
        }
        return id
    }
}
