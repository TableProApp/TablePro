import Foundation
import os
import TableProSnowflakeCore
import Testing

private final class InMemoryTokenStorage: SnowflakeTokenStorage {
    private let items: OSAllocatedUnfairLock<[String: String]>

    init(_ initial: [String: String] = [:]) {
        items = OSAllocatedUnfairLock(initialState: initial)
    }

    var snapshot: [String: String] { items.withLock { $0 } }

    func read(key: String) -> String? { items.withLock { $0[key] } }

    func write(_ value: String, key: String) -> Bool {
        items.withLock { $0[key] = value }
        return true
    }

    func delete(key: String) { items.withLock { $0[key] = nil } }

    func set(_ value: String?, key: String) { items.withLock { $0[key] = value } }
}

struct SnowflakeTokenCacheTests {
    private let hostKey = "acme.snowflakecomputing.com|BOB"
    private let legacyKey = "ACME.BOB"

    @Test("A token under the old key is copied to the host key and the old item stays for the previous release")
    func legacyItemSurvivesTheCopy() throws {
        let storage = InMemoryTokenStorage([legacyKey: "old"])
        let cache = SnowflakeTokenCache(storage: storage)

        #expect(cache.token(for: try #require(SnowflakeAccount("acme")), user: "bob") == "old")
        #expect(storage.snapshot == [legacyKey: "old", hostKey: "old"])
    }

    @Test("Once copied, a token the previous release later writes under the old key is never read")
    func hostKeyWinsAfterTheCopy() throws {
        let account = try #require(SnowflakeAccount("acme"))
        let storage = InMemoryTokenStorage([legacyKey: "old"])
        _ = SnowflakeTokenCache(storage: storage).token(for: account, user: "bob")

        storage.set("written-for-acme.us-east-1", key: legacyKey)

        #expect(SnowflakeTokenCache(storage: storage).token(for: account, user: "bob") == "old")
    }

    @Test("An account other than a bare one on the default domain never reads the old key", arguments: [
        "acme.us-east-1",
        "acme.us-east-2.aws",
        "acme.snowflakecomputing.cn",
    ])
    func otherHostsNeverReadTheOldKey(text: String) throws {
        let storage = InMemoryTokenStorage([legacyKey: "old"])
        let cache = SnowflakeTokenCache(storage: storage)

        #expect(cache.token(for: try #require(SnowflakeAccount(text)), user: "bob") == nil)
        #expect(storage.snapshot == [legacyKey: "old"])
    }

    @Test("A token stored for one host is never returned for another host of the same name")
    func tokensStayOnTheirHost() throws {
        let cache = SnowflakeTokenCache(storage: InMemoryTokenStorage())
        cache.store("regional", for: try #require(SnowflakeAccount("acme.us-east-1")), user: "bob")

        #expect(cache.token(for: try #require(SnowflakeAccount("acme")), user: "bob") == nil)
    }

    @Test("Storing writes the host key only and leaves the old item as the previous release left it")
    func storeLeavesTheOldItem() throws {
        let storage = InMemoryTokenStorage([legacyKey: "old"])
        let cache = SnowflakeTokenCache(storage: storage)
        let account = try #require(SnowflakeAccount("acme"))

        cache.store("new", for: account, user: "bob")

        #expect(storage.snapshot == [legacyKey: "old", hostKey: "new"])
        #expect(cache.token(for: account, user: "bob") == "new")
    }

    @Test("Clearing a refused token removes the copy and the old item, so it never comes back")
    func clearRemovesBothItems() throws {
        let storage = InMemoryTokenStorage([legacyKey: "old"])
        let cache = SnowflakeTokenCache(storage: storage)
        let account = try #require(SnowflakeAccount("acme"))
        _ = cache.token(for: account, user: "bob")

        cache.clear(for: account, user: "bob")

        #expect(storage.snapshot.isEmpty)
        #expect(cache.token(for: account, user: "bob") == nil)
        #expect(SnowflakeTokenCache(storage: storage).token(for: account, user: "bob") == nil)
    }

    @Test("The Keychain storage round-trips when a Keychain is available")
    func keychainRoundTrip() {
        let storage = SnowflakeKeychainTokenStorage(service: "com.TablePro.tests.snowflake.\(UUID().uuidString)")
        let key = "acme.snowflakecomputing.com|BOB"
        defer { storage.delete(key: key) }

        guard storage.write("first", key: key) else { return }
        #expect(storage.read(key: key) == "first")
        #expect(storage.write("second", key: key))
        #expect(storage.read(key: key) == "second")
        storage.delete(key: key)
        #expect(storage.read(key: key) == nil)
    }
}
