import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit

nonisolated struct ConnectionIAMSecrets: Equatable, Sendable {
    var secretAccessKey = ""
    var sessionToken = ""
    var serviceAccountKey = ""
    var device = DeviceIAMCredentials()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionIAMSecrets")

    static func stored(for connectionId: UUID, in store: any SecureStore) -> ConnectionIAMSecrets {
        var secrets = ConnectionIAMSecrets()
        secrets.secretAccessKey = storedValue(.awsSecretAccessKey, for: connectionId, in: store)
        secrets.sessionToken = storedValue(.awsSessionToken, for: connectionId, in: store)
        secrets.serviceAccountKey = storedValue(.gcpServiceAccountKey, for: connectionId, in: store)
        do {
            secrets.device = try DeviceIAMCredentials.load(for: connectionId, from: store)
        } catch {
            logger.error("Reading the device sign-in settings failed: \(error.localizedDescription, privacy: .public)")
        }
        return secrets
    }

    // Keeps a value only once the Keychain took it, so a failed write stays a change.
    mutating func persist(_ writes: ConnectionIAMSecretWrites, for connectionId: UUID, in store: any SecureStore) -> Bool {
        var succeeded = true
        if let value = writes.secretAccessKey {
            if Self.write(value, as: .awsSecretAccessKey, for: connectionId, in: store) {
                secretAccessKey = value
            } else {
                succeeded = false
            }
        }
        if let value = writes.sessionToken {
            if Self.write(value, as: .awsSessionToken, for: connectionId, in: store) {
                sessionToken = value
            } else {
                succeeded = false
            }
        }
        if let value = writes.serviceAccountKey {
            if Self.write(value, as: .gcpServiceAccountKey, for: connectionId, in: store) {
                serviceAccountKey = value
            } else {
                succeeded = false
            }
        }
        if let value = writes.device {
            do {
                try value.save(for: connectionId, to: store)
                device = value
            } catch {
                Self.logger.error("Failed to store the device sign-in settings: \(error.localizedDescription, privacy: .public)")
                succeeded = false
            }
        }
        return succeeded
    }

    private static func storedValue(
        _ kind: ConnectionSecretKind,
        for connectionId: UUID,
        in store: any SecureStore
    ) -> String {
        do {
            return try store.retrieve(forKey: kind.account(for: connectionId)) ?? ""
        } catch {
            logger.error("Reading a sign-in secret failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    private static func write(
        _ value: String,
        as kind: ConnectionSecretKind,
        for connectionId: UUID,
        in store: any SecureStore
    ) -> Bool {
        let account = kind.account(for: connectionId)
        do {
            if value.isEmpty {
                try store.delete(forKey: account)
            } else {
                try store.store(value, forKey: account)
            }
            return true
        } catch {
            logger.error("Failed to store a sign-in secret: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

// An empty string deletes the item.
nonisolated struct ConnectionIAMSecretWrites: Equatable, Sendable {
    var secretAccessKey: String?
    var sessionToken: String?
    var serviceAccountKey: String?
    var device: DeviceIAMCredentials?
}

nonisolated struct IdentityCenterSetupState: Equatable, Sendable {
    nonisolated enum Activity: Equatable, Sendable {
        case idle
        case signingIn
        case loadingRoles
    }

    nonisolated struct Request: Equatable, Sendable {
        nonisolated enum Kind: Equatable, Sendable {
            case signIn
            case roles(accountId: String)
        }

        let kind: Kind
        let id = UUID()
    }

    var activity = Activity.idle
    var accounts: [AWSSSOAccount] = []
    var roles: [AWSSSOAccountRole] = []
    var error: String?
    var request: Request?
}

nonisolated struct ConnectionIAMFormState: Equatable, Sendable {
    var method: IAMSignIn?
    var region = ""
    var accessKeyId = ""
    var profileName = ""
    var rdsEndpoint = ""
    var replicationGroupId = ""
    var secrets = ConnectionIAMSecrets()
    var identityCenter = IdentityCenterSetupState()
    var serviceAccountKeyFileError: String?

    init() {}

    init(connection: DatabaseConnection) {
        typealias Field = IAMSignIn.Field
        let fields = connection.additionalFields
        method = connection.iamSignIn
        region = fields[Field.region] ?? ""
        accessKeyId = fields[Field.accessKeyId] ?? ""
        profileName = fields[Field.profileName] ?? ""
        rdsEndpoint = fields[Field.rdsEndpoint] ?? ""
        replicationGroupId = fields[Field.replicationGroupId] ?? ""
    }

    var options: ConnectionFormEdits.IAMOptions {
        ConnectionFormEdits.IAMOptions(
            method: method,
            region: region,
            accessKeyId: accessKeyId,
            profileName: profileName,
            rdsEndpoint: rdsEndpoint,
            replicationGroupId: replicationGroupId
        )
    }

    mutating func keepMethodOffered(for type: DatabaseType) {
        guard let method, !IAMSignIn.methods(for: type).contains(method) else { return }
        self.method = nil
    }
}
