//
//  CoreStoreSecrets.swift
//  TablePro
//

import Foundation
import os
import TableProFFI

// The secret store of the core over `TablePro/Core`: the account's items where `KeychainHostSecrets` keeps them, and each
// connection's secrets in the items earlier builds read (core ADR 0010).
nonisolated internal final class CoreStoreSecrets: HostSecrets, @unchecked Sendable {
    private let items: (any HostSecrets)?
    private let connections: ConnectionKeychainSecrets
    private let profiles: ProfileKeychainSecrets?

    init(items: (any HostSecrets)?, connections: ConnectionKeychainSecrets, profiles: ProfileKeychainSecrets? = nil) {
        self.items = items
        self.connections = connections
        self.profiles = profiles
    }

    func load(connectionId: String, kind: SecretKindTag) throws -> SecretString? {
        try connections.load(connectionId: connectionId, kind: kind)
    }

    func store(connectionId: String, kind: SecretKindTag, secret: SecretString, label: String) throws {
        try connections.store(connectionId: connectionId, kind: kind, secret: secret, label: label)
    }

    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {
        try connections.relabel(connectionId: connectionId, kind: kind, label: label)
    }

    func delete(connectionId: String, kind: SecretKindTag) throws {
        try connections.delete(connectionId: connectionId, kind: kind)
    }

    func deleteConnection(connectionId: String) throws {
        try connections.deleteConnection(connectionId: connectionId)
    }

    func deleteProfile(profileId: String, kind: ProfileKindTag) throws -> SecretDeletionTag {
        profiles?.delete(profileId: profileId, kind: kind) ?? .notOwned
    }

    func loadItem(item: SecretItemTag) throws -> SecretString? {
        try itemStore().loadItem(item: item)
    }

    func storeItem(item: SecretItemTag, secret: SecretString) throws {
        try itemStore().storeItem(item: item, secret: secret)
    }

    func deleteItem(item: SecretItemTag) throws {
        try itemStore().deleteItem(item: item)
    }

    private func itemStore() throws -> any HostSecrets {
        guard let items else {
            throw HostSecretError.Unavailable(detail: "this core keeps no account items")
        }
        return items
    }
}

// The Local only connections by id, set by the library on every read and write and read by the Keychain calls the core
// makes on its own threads, so their secrets stay on this Mac. Nil until the library first reads: no scope is known.
nonisolated internal final class LocalOnlyConnections: Sendable {
    static let shared = LocalOnlyConnections()

    private let ids = OSAllocatedUnfairLock<Set<UUID>?>(initialState: nil)

    func isLocalOnly(_ id: UUID) -> Bool? {
        ids.withLock { $0.map { $0.contains(id) } }
    }

    func set(_ local: Set<UUID>) {
        ids.withLock { $0 = local }
    }
}

// The Keychain items each SSH and credential profile writes, for the core's deletions of the profiles a library write
// takes out. It runs under the library's lock, so it reads only what the library last handed it.
nonisolated internal final class ProfileKeychainSecrets: Sendable {
    static let shared = ProfileKeychainSecrets(keychain: AppStorageEnvironment.shared.keychain)

    private let keychain: any KeychainStoring
    // A credential profile's secure fields, which its record no longer names once the write that took it out landed.
    private let secureFields = OSAllocatedUnfairLock<[UUID: Set<String>]>(initialState: [:])

    init(keychain: any KeychainStoring) {
        self.keychain = keychain
    }

    func remember(_ profiles: [CredentialProfile]) {
        secureFields.withLock { fields in
            for profile in profiles {
                fields[profile.id, default: []].formUnion(profile.secureFieldIds)
            }
        }
    }

    func delete(profileId: String, kind: ProfileKindTag) -> SecretDeletionTag {
        guard let id = UUID(uuidString: profileId) else { return .notOwned }
        switch kind {
        case .ssh:
            for secret in SSHSecret.allCases {
                keychain.delete(forKey: SSHProfileStorage.key(secret, id))
            }
        case .credential:
            keychain.delete(forKey: CredentialProfileStorage.passwordKey(id))
            let fields = secureFields.withLock { $0.removeValue(forKey: id) ?? [] }
            for field in fields {
                keychain.delete(forKey: CredentialProfileStorage.fieldKey(field, id))
            }
        }
        return .deleted
    }
}
