import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ExternalConnectionTrustStore")
struct ExternalConnectionTrustStoreTests {
    private func makeStore() throws -> ExternalConnectionTrustStore {
        let suite = "ExternalConnectionTrustStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ExternalConnectionTrustStore(defaults: defaults)
    }

    private func loopbackKey(scopeName: String = "ddev-shop") -> ExternalConnectionTrustKey {
        ExternalConnectionTrustKey(
            databaseType: "MySQL",
            host: "127.0.0.1",
            database: "db",
            username: "db",
            scopeName: scopeName
        )
    }

    @Test("Nothing is trusted by default")
    func defaultsEmpty() throws {
        let store = try makeStore()
        #expect(store.entries().isEmpty)
        #expect(store.isTrusted(loopbackKey()) == false)
    }

    @Test("A loopback key round-trips")
    func loopbackRoundTrip() throws {
        let store = try makeStore()
        store.trust(loopbackKey())
        #expect(store.isTrusted(loopbackKey()))
        #expect(store.entries().count == 1)
    }

    @Test("A different port still matches, because DDEV reassigns the host port on every start")
    func portIsNotPartOfIdentity() throws {
        let store = try makeStore()
        let connection = DatabaseConnection(
            name: "ddev-shop", host: "127.0.0.1", port: 32_770,
            database: "db", username: "db", type: .mysql
        )
        let restarted = DatabaseConnection(
            name: "ddev-shop", host: "127.0.0.1", port: 49_153,
            database: "db", username: "db", type: .mysql
        )

        store.trust(ExternalConnectionTrustKey(connection: connection, scopeName: "ddev-shop"))

        #expect(store.isTrusted(ExternalConnectionTrustKey(connection: restarted, scopeName: "ddev-shop")))
    }

    @Test("Two DDEV projects sharing default credentials do not share trust")
    func scopeNameSeparatesProjects() throws {
        let store = try makeStore()
        store.trust(loopbackKey(scopeName: "ddev-shop"))

        #expect(store.isTrusted(loopbackKey(scopeName: "ddev-blog")) == false)
    }

    @Test("A remote host can never be trusted")
    func remoteHostIsRefused() throws {
        let store = try makeStore()
        let remote = ExternalConnectionTrustKey(
            databaseType: "MySQL",
            host: "db.evil.example.com",
            database: "db",
            username: "db",
            scopeName: "ddev-shop"
        )

        store.trust(remote)

        #expect(store.entries().isEmpty)
        #expect(store.isTrusted(remote) == false)
    }

    @Test("A poisoned defaults blob cannot make a remote host trusted")
    func poisonedDefaultsAreIgnored() throws {
        let suite = "ExternalConnectionTrustStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let remote = ExternalConnectionTrustKey(
            databaseType: "MySQL",
            host: "db.evil.example.com",
            database: "db",
            username: "db",
            scopeName: ""
        )
        let poisoned = [TrustedExternalConnection(key: remote, trustedAt: Date())]
        defaults.set(try JSONEncoder().encode(poisoned), forKey: "com.TablePro.externalConnectionTrust.entries")

        let store = ExternalConnectionTrustStore(defaults: defaults)

        #expect(store.isTrusted(remote) == false)
        #expect(store.entries().isEmpty)
    }

    @Test("Revoke removes a single entry")
    func revokeOne() throws {
        let store = try makeStore()
        store.trust(loopbackKey(scopeName: "ddev-shop"))
        store.trust(loopbackKey(scopeName: "ddev-blog"))

        store.revoke(loopbackKey(scopeName: "ddev-shop"))

        #expect(store.isTrusted(loopbackKey(scopeName: "ddev-shop")) == false)
        #expect(store.isTrusted(loopbackKey(scopeName: "ddev-blog")))
    }

    @Test("Revoke all clears the store")
    func revokeAll() throws {
        let store = try makeStore()
        store.trust(loopbackKey(scopeName: "ddev-shop"))
        store.trust(loopbackKey(scopeName: "ddev-blog"))

        store.revokeAll()

        #expect(store.entries().isEmpty)
    }

    @Test("Trusting the same key twice keeps one entry")
    func trustIsIdempotent() throws {
        let store = try makeStore()
        store.trust(loopbackKey())
        store.trust(loopbackKey())

        #expect(store.entries().count == 1)
    }

    @Test("localhost and ::1 count as loopback")
    func loopbackHostVariants() {
        let hosts = ["localhost", "127.0.0.1", "127.0.0.53", "::1", "[::1]", "LOCALHOST", "localhost.", "127.0.0.1."]
        for host in hosts {
            let key = ExternalConnectionTrustKey(
                databaseType: "MySQL", host: host, database: "db", username: "db", scopeName: ""
            )
            #expect(key.isLoopbackHost, "\(host) should be loopback")
        }
    }

    @Test("A domain that merely starts with 127. is not loopback")
    func lookalikeHostsAreNotLoopback() {
        let hosts = [
            "127.evil.com",
            "127.0.0.1.evil.com",
            "localhost.evil.com",
            "10.0.0.5",
            "0x7f.0.0.1",
            "db.example.com",
            "127.0.0.256",
            "1270.0.0.1"
        ]
        for host in hosts {
            let key = ExternalConnectionTrustKey(
                databaseType: "MySQL", host: host, database: "db", username: "db", scopeName: ""
            )
            #expect(key.isLoopbackHost == false, "\(host) must not be loopback")
        }
    }

    @Test("A host that only looks like loopback cannot be trusted")
    func lookalikeHostCannotBeTrusted() throws {
        let store = try makeStore()
        let lookalike = ExternalConnectionTrustKey(
            databaseType: "MySQL", host: "127.evil.com", database: "db", username: "db", scopeName: "ddev-shop"
        )

        store.trust(lookalike)

        #expect(store.entries().isEmpty)
        #expect(store.isTrusted(lookalike) == false)
    }
}
