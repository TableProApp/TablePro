import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

private final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func store(_ value: String, forKey key: String) throws {
        lock.withLock { values[key] = value }
    }

    func retrieve(forKey key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    func delete(forKey key: String) throws {
        lock.withLock { values[key] = nil }
    }

    var keys: Set<String> {
        lock.withLock { Set(values.keys) }
    }
}

@Suite("Connection secrets")
struct ConnectionSecretsTests {
    private let secureStore = InMemorySecureStore()
    private let certificates = InMemoryCertificateStore()
    private let bookmarks = FileBookmarkStore(suiteName: "com.TablePro.tests.ConnectionSecrets.\(UUID().uuidString)")

    private var secrets: ConnectionSecrets {
        ConnectionSecrets(secureStore: secureStore, certificateStore: certificates, bookmarkStore: bookmarks)
    }

    private func seed(_ id: UUID) throws {
        for prefix in ConnectionSecrets.secureStoreKeyPrefixes {
            try secureStore.store("secret-\(prefix)", forKey: prefix + id.uuidString)
        }
        for role in CertificateRole.allCases {
            try certificates.store("pem-\(role.rawValue)", role: role, for: id)
        }
        bookmarks.save(Data([1, 2, 3]), for: id)
    }

    @Test("A duplicate gets its own copy of every saved secret")
    func copiesEverything() throws {
        let source = UUID()
        let copy = UUID()
        try seed(source)

        #expect(secrets.copy(from: source, to: copy))

        for prefix in ConnectionSecrets.secureStoreKeyPrefixes {
            #expect(try secureStore.retrieve(forKey: prefix + copy.uuidString) == "secret-\(prefix)")
        }
        for role in CertificateRole.allCases {
            #expect(certificates.pem(role: role, for: copy) == "pem-\(role.rawValue)")
        }
        #expect(bookmarks.bookmark(for: copy) == Data([1, 2, 3]))
    }

    @Test("Every secret a connection owns is covered, under the account names the Keychain already holds")
    func prefixesMatchStoredAccounts() {
        #expect(ConnectionSecrets.secureStoreKeyPrefixes == [
            "com.TablePro.password.",
            "com.TablePro.sshpassword.",
            "com.TablePro.keypassphrase.",
            "com.TablePro.sshkeydata."
        ])
        let id = UUID()
        #expect(ConnectionSecretKind.sshPrivateKey.account(for: id) == "com.TablePro.sshkeydata.\(id.uuidString)")
    }

    @Test("The orphan sweep takes the passwords of a connection that is gone and nothing else")
    func sweepTakesOrphanedPasswordsOnly() {
        let kept = UUID()
        let removed = UUID()
        let owned = ConnectionSecretKind.allCases.flatMap { [$0.account(for: kept), $0.account(for: removed)] }
        let foreign = ["com.TablePro.credprofile.\(removed.uuidString)", "com.TablePro.password.not-a-uuid"]

        let orphaned = ConnectionSecretKind.orphanedAccounts(owned + foreign, keeping: [kept])

        #expect(Set(orphaned) == [
            ConnectionSecretKind.password.account(for: removed),
            ConnectionSecretKind.sshPassword.account(for: removed),
            ConnectionSecretKind.keyPassphrase.account(for: removed)
        ])
    }

    @Test("The orphan sweep never takes a pasted private key, which may be the only copy")
    func sweepSparesPastedKeys() {
        let account = ConnectionSecretKind.sshPrivateKey.account(for: UUID())

        #expect(ConnectionSecretKind.orphanedAccounts([account], keeping: [UUID()]).isEmpty)
    }

    @Test("The orphan sweep takes nothing before the connections have loaded")
    func sweepWaitsForTheLibrary() {
        let account = ConnectionSecretKind.password.account(for: UUID())

        #expect(ConnectionSecretKind.orphanedAccounts([account], keeping: []).isEmpty)
    }

    @Test("Moving keys out of the file stores each one the store does not hold yet")
    func storesMissingKeys() throws {
        let first = UUID()
        let second = UUID()

        #expect(secrets.storeMissingPrivateKeys([first: "KEY A", second: "KEY B"]).isEmpty)

        #expect(try secureStore.retrieve(forKey: ConnectionSecretKind.sshPrivateKey.account(for: first)) == "KEY A")
        #expect(try secureStore.retrieve(forKey: ConnectionSecretKind.sshPrivateKey.account(for: second)) == "KEY B")
    }

    @Test("A key the store already holds is never replaced by the file's copy")
    func keepsExistingKey() throws {
        let id = UUID()
        let account = ConnectionSecretKind.sshPrivateKey.account(for: id)
        try secureStore.store("SYNCED KEY", forKey: account)

        #expect(secrets.storeMissingPrivateKeys([id: "FILE KEY"]).isEmpty)

        #expect(try secureStore.retrieve(forKey: account) == "SYNCED KEY")
    }

    @Test("An empty stored key is filled from the file")
    func fillsEmptyKey() throws {
        let id = UUID()
        let account = ConnectionSecretKind.sshPrivateKey.account(for: id)
        try secureStore.store("", forKey: account)

        #expect(secrets.storeMissingPrivateKeys([id: "FILE KEY"]).isEmpty)

        #expect(try secureStore.retrieve(forKey: account) == "FILE KEY")
    }

    @Test("A refused write hands that key back and the other keys still move")
    func refusedWriteReturnsKey() throws {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let refusing = MockSecureStore()
        refusing.failNextStore = true
        let secrets = ConnectionSecrets(secureStore: refusing, certificateStore: certificates, bookmarkStore: bookmarks)

        let unstored = secrets.storeMissingPrivateKeys([ids[0]: "KEY A", ids[1]: "KEY B"])

        #expect(unstored == [ids[0]: "KEY A"])
        #expect(try refusing.retrieve(forKey: ConnectionSecretKind.sshPrivateKey.account(for: ids[0])) == nil)
        #expect(try refusing.retrieve(forKey: ConnectionSecretKind.sshPrivateKey.account(for: ids[1])) == "KEY B")
    }

    @Test("Deleting one connection's secrets leaves its duplicate's alone")
    func deleteIsScoped() throws {
        let source = UUID()
        let copy = UUID()
        try seed(source)
        secrets.copy(from: source, to: copy)

        secrets.delete(for: source)

        #expect(!secureStore.keys.contains { $0.hasSuffix(source.uuidString) })
        #expect(certificates.pem(role: .clientKey, for: source) == nil)
        #expect(bookmarks.bookmark(for: source) == nil)
        #expect(certificates.pem(role: .clientKey, for: copy) == "pem-clientKey")
        #expect(bookmarks.bookmark(for: copy) != nil)
    }
}
