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

private final class InMemoryCertificateStore: CertificateMaterialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    private func key(_ role: CertificateRole, _ id: UUID) -> String {
        "\(id.uuidString).\(role.rawValue)"
    }

    func store(_ pem: String, role: CertificateRole, for connectionId: UUID) throws {
        lock.withLock { values[key(role, connectionId)] = pem }
    }

    func pem(role: CertificateRole, for connectionId: UUID) -> String? {
        lock.withLock { values[key(role, connectionId)] }
    }

    func delete(role: CertificateRole, for connectionId: UUID) {
        _ = lock.withLock { values.removeValue(forKey: key(role, connectionId)) }
    }

    func deleteAll(for connectionId: UUID) {
        for role in CertificateRole.allCases {
            delete(role: role, for: connectionId)
        }
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
