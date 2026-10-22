import Foundation
import TableProModels

nonisolated struct ConnectionFormSecrets: Equatable, Sendable {
    var password = ""
    var sshPassword = ""
    var sshKeyPassphrase = ""
    var privateKey: String?
    var jumpHostCredentials: [UUID: JumpHostCredential] = [:]
    var totpSecret = ""
    var iam = ConnectionIAMSecrets()
}

nonisolated struct ConnectionFormSecretWrites: Equatable, Sendable {
    var password: String?
    var sshPassword: String?
    var sshKeyPassphrase: String?
    var totpSecret: String?
    var iam = ConnectionIAMSecretWrites()
}

nonisolated struct ConnectionFormSnapshot: Equatable, Sendable {
    var edits: ConnectionFormEdits
    var secrets: ConnectionFormSecrets
    var stagedCertificates: [CertificateRole: String]
    var removedStoredCertificates: Set<CertificateRole>
}

extension ConnectionFormViewModel {
    var snapshot: ConnectionFormSnapshot {
        ConnectionFormSnapshot(
            edits: edits,
            secrets: secretsAfterSave,
            stagedCertificates: pendingCertificates,
            removedStoredCertificates: removedCertificates.intersection(storedCertificateRoles)
        )
    }

    var openingEdits: ConnectionFormEdits? {
        guard isEditing else { return nil }
        return baseline?.edits
    }

    var hasChanges: Bool {
        guard let baseline else { return false }
        return snapshot != baseline
    }

    var changesSecrets: Bool {
        guard let baseline else { return false }
        let current = snapshot
        return current.secrets != baseline.secrets
            || current.stagedCertificates != baseline.stagedCertificates
            || current.removedStoredCertificates != baseline.removedStoredCertificates
    }

    var reconnectsAfterSave: Bool {
        isEditing && changesSecrets
    }

    // A changed secret reconnects the open screen, and a record that dials differently drops its session.
    func redialsAfterSave(over current: DatabaseConnection) -> Bool {
        guard isEditing else { return false }
        return reconnectsAfterSave || !applyingEdits(to: current).dialsTheSameWay(as: current)
    }

    var secretWrites: ConnectionFormSecretWrites {
        ConnectionFormSecretWrites(
            password: Self.changedSecret(password, loaded: storedSecrets.password),
            sshPassword: sshEnabled ? Self.changedSecret(sshPassword, loaded: storedSecrets.sshPassword) : nil,
            sshKeyPassphrase: sshEnabled
                ? Self.changedSecret(sshKeyPassphrase, loaded: storedSecrets.sshKeyPassphrase)
                : nil,
            totpSecret: sshEnabled ? Self.changedSecret(totpSecret, loaded: storedSecrets.totpSecret) : nil,
            iam: iamSecretWrites
        )
    }

    private var secretsAfterSave: ConnectionFormSecrets {
        ConnectionFormSecrets(
            password: password.isEmpty ? storedSecrets.password : password,
            sshPassword: sshEnabled && !sshPassword.isEmpty ? sshPassword : storedSecrets.sshPassword,
            sshKeyPassphrase: sshEnabled && !sshKeyPassphrase.isEmpty ? sshKeyPassphrase : storedSecrets.sshKeyPassphrase,
            privateKey: pastedPrivateKey,
            jumpHostCredentials: jumpHostCredentialsUnreadable ? storedSecrets.jumpHostCredentials : jumpHostCredentials,
            totpSecret: sshEnabled && !totpSecret.isEmpty ? totpSecret : storedSecrets.totpSecret,
            iam: iamSecretsAfterSave
        )
    }

    private static func changedSecret(_ value: String, loaded: String) -> String? {
        value.isEmpty || value == loaded ? nil : value
    }
}
