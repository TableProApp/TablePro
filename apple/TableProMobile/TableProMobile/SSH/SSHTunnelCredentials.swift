import Foundation
import TableProDatabase

nonisolated struct SSHTunnelCredentials: Sendable, Equatable {
    nonisolated enum PrivateKeySource: Sendable, Equatable {
        case inMemory(String)
        case file(path: String)
        case missing
    }

    let password: String?
    let keyPassphrase: String?
    let privateKey: String?

    init(password: String? = nil, keyPassphrase: String? = nil, privateKey: String? = nil) {
        self.password = Self.nonEmpty(password)
        self.keyPassphrase = Self.nonEmpty(keyPassphrase)
        self.privateKey = Self.nonEmpty(privateKey)
    }

    // A tunnel that follows a Mac SSH profile signs in with the profile's password, which iCloud
    // Keychain brings under the profile's id. A passphrase belongs to the key, and the key here is
    // this device's copy, so its own passphrase comes first.
    init(connectionId: UUID, sshProfileId: UUID? = nil, secureStore: any SecureStore) {
        self.init(
            password: sshProfileId.flatMap { Self.secret(.password, ofProfile: $0, in: secureStore) }
                ?? Self.secret(.sshPassword, for: connectionId, in: secureStore),
            keyPassphrase: Self.secret(.keyPassphrase, for: connectionId, in: secureStore)
                ?? sshProfileId.flatMap { Self.secret(.keyPassphrase, ofProfile: $0, in: secureStore) },
            privateKey: Self.secret(.sshPrivateKey, for: connectionId, in: secureStore)
        )
    }

    func privateKeySource(keyPath: String?) -> PrivateKeySource {
        if let privateKey {
            return .inMemory(privateKey)
        }
        guard let keyPath, !keyPath.isEmpty else { return .missing }
        return .file(path: keyPath)
    }

    private static func secret(
        _ kind: ConnectionSecretKind,
        for connectionId: UUID,
        in secureStore: any SecureStore
    ) -> String? {
        nonEmpty(try? secureStore.retrieve(forKey: kind.account(for: connectionId)))
    }

    private static func secret(
        _ kind: SSHProfileSecretKind,
        ofProfile profileId: UUID,
        in secureStore: any SecureStore
    ) -> String? {
        nonEmpty(try? secureStore.retrieve(forKey: kind.account(for: profileId)))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
