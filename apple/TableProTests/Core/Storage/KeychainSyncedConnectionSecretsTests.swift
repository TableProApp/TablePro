//
//  KeychainSyncedConnectionSecretsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

// The core sends every kind the app names to the app (core ADR 0077), a connection's password, SSH password and key
// passphrase included, so those reach the items the connection itself reads.
struct KeychainSyncedConnectionSecretsTests {
    private let store = ScopedKeychainItemStore()
    private let suite: EphemeralDefaults
    private let record: DefaultsKeychainProviderRecord
    private let connection = UUID()

    init() throws {
        let suite = try EphemeralDefaults()
        self.suite = suite
        record = DefaultsKeychainProviderRecord { [defaults = suite.defaults] in defaults }
    }

    private func secrets() -> KeychainSyncedSecrets {
        KeychainSyncedSecrets(keychain: KeychainHelper(
            service: "com.TablePro.tests.syncedConnections",
            passwordSyncSetting: { false },
            provider: record,
            items: store
        ))
    }

    private func reference(_ kind: String) -> SyncedSecretRef {
        SyncedSecretRef(parent: .connection, parentId: connection.uuidString.lowercased(), kind: kind)
    }

    @Test("Each connection secret the core now sends here is the item the connection's own secrets read")
    func connectionKindsShareTheConnectionsItems() throws {
        let pairs: [(String, SecretKindTag)] = [
            ("password", .databasePassword), ("ssh_password", .sshPassword), ("ssh_key_passphrase", .sshPassphrase),
        ]
        for (kind, tag) in pairs {
            #expect(try KeychainSyncedSecrets.key(reference(kind)) == ConnectionKeychainSecrets.key(tag, connection), "\(kind)")
        }
        #expect(Set(secrets().kinds(parent: .connection)).isSuperset(of: pairs.map(\.0)))
    }

    @Test("A connection's password still only in iCloud Keychain, right after a move to TablePro Sync, goes up")
    func passwordInICloudKeychainIsRead() throws {
        record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: false))
        store.seed("hunter2", account: ConnectionKeychainSecrets.key(.databasePassword, connection), synchronizable: true)

        #expect(try secrets().load(secret: reference("password")) == "hunter2")
    }
}
