import Foundation
import TableProModels

nonisolated struct ConnectionFormSecrets: Equatable, Sendable {
    var password = ""
    var sshPassword = ""
    var sshKeyPassphrase = ""
    var privateKey: String?
}

nonisolated struct ConnectionFormSecretWrites: Equatable, Sendable {
    var password: String?
    var sshPassword: String?
    var sshKeyPassphrase: String?
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

    var secretWrites: ConnectionFormSecretWrites {
        ConnectionFormSecretWrites(
            password: Self.changedSecret(password, loaded: storedSecrets.password),
            sshPassword: sshEnabled ? Self.changedSecret(sshPassword, loaded: storedSecrets.sshPassword) : nil,
            sshKeyPassphrase: sshEnabled
                ? Self.changedSecret(sshKeyPassphrase, loaded: storedSecrets.sshKeyPassphrase)
                : nil
        )
    }

    private var secretsAfterSave: ConnectionFormSecrets {
        ConnectionFormSecrets(
            password: password.isEmpty ? storedSecrets.password : password,
            sshPassword: sshEnabled && !sshPassword.isEmpty ? sshPassword : storedSecrets.sshPassword,
            sshKeyPassphrase: sshEnabled && !sshKeyPassphrase.isEmpty ? sshKeyPassphrase : storedSecrets.sshKeyPassphrase,
            privateKey: pastedPrivateKey
        )
    }

    private static func changedSecret(_ value: String, loaded: String) -> String? {
        value.isEmpty || value == loaded ? nil : value
    }
}
