import Foundation
@testable import TablePro
import TableProFFI
import Testing

struct KeychainSyncedSecretsTests {
    private let store = ScopedKeychainItemStore()
    private let suite: EphemeralDefaults
    private let record: DefaultsKeychainProviderRecord
    private let profile = UUID()

    init() throws {
        let suite = try EphemeralDefaults()
        self.suite = suite
        record = DefaultsKeychainProviderRecord { [defaults = suite.defaults] in defaults }
    }

    private func secrets(passwordSync: Bool) -> KeychainSyncedSecrets {
        KeychainSyncedSecrets(keychain: KeychainHelper(
            service: "com.TablePro.tests.synced",
            passwordSyncSetting: { passwordSync },
            provider: record,
            items: store
        ))
    }

    private func reference(_ parent: SyncedSecretParentTag, _ kind: String) -> SyncedSecretRef {
        SyncedSecretRef(parent: parent, parentId: profile.uuidString, kind: kind)
    }

    @Test("A profile's secret pulled on TablePro Sync lands in this Mac's own item, never in iCloud Keychain")
    func pulledSecretStaysOnThisMac() throws {
        record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
        let synced = secrets(passwordSync: true)

        try synced.store(secret: reference(.sshProfile, "ssh_password"), value: "tunnel")

        let key = SSHProfileStorage.key(.password, profile)
        #expect(store.value(account: key, synchronizable: false) == "tunnel")
        #expect(store.value(account: key, synchronizable: true) == nil)
        #expect(try synced.load(secret: reference(.sshProfile, "ssh_password")) == "tunnel")
    }

    @Test("Each secret goes to the item the Mac's own storage reads")
    func itemsTheMacReads() throws {
        let id = profile.uuidString
        #expect(try KeychainSyncedSecrets.key(reference(.sshProfile, "ssh_key_passphrase")) == SSHProfileStorage.key(.keyPassphrase, profile))
        #expect(try KeychainSyncedSecrets.key(reference(.sshProfile, "ssh_totp_secret")) == SSHProfileStorage.key(.totpSecret, profile))
        #expect(try KeychainSyncedSecrets.key(reference(.credentialProfile, "password")) == CredentialProfileStorage.passwordKey(profile))
        #expect(try KeychainSyncedSecrets.key(reference(.connection, "ssl_key_passphrase")) == "com.TablePro.sslkeypassphrase.\(id)")
        #expect(try KeychainSyncedSecrets.key(reference(.connection, "ssh_totp_secret")) == "com.TablePro.totpsecret.\(id)")
    }

    @Test("It names only the kinds it keeps, and a connection's password stays with the core's own calls")
    func kindsKept() {
        let synced = secrets(passwordSync: false)

        #expect(synced.kinds(parent: .connection) == ["ssl_key_passphrase", "ssh_totp_secret"])
        #expect(synced.kinds(parent: .sshProfile) == ["ssh_password", "ssh_key_passphrase", "ssh_totp_secret"])
        #expect(synced.kinds(parent: .credentialProfile) == ["password"])
        #expect(throws: HostSecretError.self) {
            try KeychainSyncedSecrets.key(reference(.connection, "password"))
        }
    }

    @Test("A deleted secret reads as none")
    func deleteRemoves() throws {
        record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
        let synced = secrets(passwordSync: false)
        try synced.store(secret: reference(.credentialProfile, "password"), value: "dba")

        try synced.delete(secret: reference(.credentialProfile, "password"))

        #expect(try synced.load(secret: reference(.credentialProfile, "password")) == nil)
    }
}
