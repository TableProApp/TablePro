import Foundation
import os
import TableProConnectionLibrary
import TableProDatabase
import TableProModels

// A Mac build before the fix kept a pasted MongoDB connection string's secrets as plain options, and sync brought them
// here. They move to the Keychain under the Mac's names, so the driver still finds them and sync never sends them.
nonisolated enum MongoURISecretMigration {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoURISecretMigration")

    // A field whose Keychain write fails stays in the record rather than being lost. A value already in the Keychain
    // wins, since a legacy record an older build syncs can carry a stale copy.
    static func keepingSecretsInKeychain(
        _ connection: DatabaseConnection,
        in secureStore: any SecureStore
    ) -> DatabaseConnection {
        var kept = connection
        for (key, value) in connection.additionalFields where ConnectionSecretOptions.isSecret(key: key, value: value) {
            guard let option = ConnectionSecretOptions.mongoOption(in: key) else {
                if store(value, as: .mongoAWSSessionToken, for: connection.id, in: secureStore) {
                    kept.additionalFields[key] = nil
                }
                continue
            }
            if ConnectionSecretOptions.isMongoKeyPassphrase(option: option) {
                if store(value, as: .sslKeyPassphrase, for: connection.id, in: secureStore) {
                    kept.additionalFields[key] = nil
                }
            } else if ConnectionSecretOptions.isMongoMechanismProperties(option: option) {
                let split = ConnectionSecretOptions.splitSessionToken(from: value)
                if let token = split.sessionToken, store(token, as: .mongoAWSSessionToken, for: connection.id, in: secureStore) {
                    kept.additionalFields[key] = split.remaining
                }
            } else {
                kept.additionalFields[key] = nil
            }
        }
        return kept
    }

    private static func store(
        _ value: String,
        as kind: ConnectionSecretKind,
        for connectionId: UUID,
        in secureStore: any SecureStore
    ) -> Bool {
        let account = kind.account(for: connectionId)
        if let held = try? secureStore.retrieve(forKey: account), !held.isEmpty { return true }
        do {
            try secureStore.store(value, forKey: account)
            return true
        } catch {
            logger.error("A MongoDB connection-string secret stayed in the record: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
