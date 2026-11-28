//
//  KeychainSyncedSecrets.swift
//  TablePro
//

import Foundation
import TableProFFI

// The secrets TablePro Sync seals that `HostSecrets` does not reach: each SSH and credential profile's, and a
// connection's TLS key passphrase and TOTP secret, in the items the Mac already reads (core ADR 0069). The Keychain
// follows the provider, so on TablePro Sync a pulled secret is this Mac's own item and never an iCloud Keychain one.
nonisolated internal final class KeychainSyncedSecrets: HostSyncedSecrets, @unchecked Sendable {
    private let keychain: any KeychainStoring

    init(keychain: any KeychainStoring) {
        self.keychain = keychain
    }

    func kinds(parent: SyncedSecretParentTag) -> [String] {
        switch parent {
        case .connection: [Self.sslKeyPassphrase, Self.totpSecret]
        case .sshProfile: [Self.sshPassword, Self.sshKeyPassphrase, Self.totpSecret]
        case .credentialProfile: [Self.password]
        }
    }

    func load(secret: SyncedSecretRef) throws -> String? {
        switch keychain.readStringResult(forKey: try Self.key(secret)) {
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

    func store(secret: SyncedSecretRef, value: String) throws {
        guard keychain.writeString(value, forKey: try Self.key(secret)) else {
            throw HostSecretError.Failed(detail: "the keychain refused the write")
        }
    }

    func delete(secret: SyncedSecretRef) throws {
        keychain.delete(forKey: try Self.key(secret))
    }

    private static let password = "password"
    private static let sshPassword = "ssh_password"
    private static let sshKeyPassphrase = "ssh_key_passphrase"
    private static let totpSecret = "ssh_totp_secret"
    private static let sslKeyPassphrase = "ssl_key_passphrase"

    static func key(_ secret: SyncedSecretRef) throws -> String {
        guard let id = UUID(uuidString: secret.parentId) else {
            throw HostSecretError.Failed(detail: "not a record id")
        }
        switch (secret.parent, secret.kind) {
        case (.connection, sslKeyPassphrase):
            return "com.TablePro.sslkeypassphrase.\(id.uuidString)"
        case (.connection, totpSecret):
            return "com.TablePro.totpsecret.\(id.uuidString)"
        case (.sshProfile, sshPassword):
            return SSHProfileStorage.key(.password, id)
        case (.sshProfile, sshKeyPassphrase):
            return SSHProfileStorage.key(.keyPassphrase, id)
        case (.sshProfile, totpSecret):
            return SSHProfileStorage.key(.totpSecret, id)
        case (.credentialProfile, password):
            return CredentialProfileStorage.passwordKey(id)
        default:
            throw HostSecretError.Unavailable(detail: "this Mac keeps no such secret")
        }
    }
}
