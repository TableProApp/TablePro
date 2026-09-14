//
//  ResolvedPasswordCacheTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ResolvedPasswordCache")
struct ResolvedPasswordCacheTests {
    @Test("Answers a second ask within the lifetime")
    func returnsCachedValue() async {
        let cache = ResolvedPasswordCache()
        let id = UUID()
        await cache.store("secret", for: id, fingerprint: "op read x", lifetime: 900)
        #expect(await cache.value(for: id, fingerprint: "op read x") == "secret")
    }

    @Test("Forgets an entry once its lifetime has run out")
    func expires() async {
        let cache = ResolvedPasswordCache()
        let id = UUID()
        let start = Date()
        await cache.store("secret", for: id, fingerprint: "cmd", lifetime: 60, now: start)
        #expect(await cache.value(for: id, fingerprint: "cmd", now: start.addingTimeInterval(59)) == "secret")
        #expect(await cache.value(for: id, fingerprint: "cmd", now: start.addingTimeInterval(61)) == nil)
    }

    @Test("A changed command is a different entry, not a stale hit")
    func fingerprintMismatchMisses() async {
        let cache = ResolvedPasswordCache()
        let id = UUID()
        await cache.store("old", for: id, fingerprint: "op read old", lifetime: 900)
        #expect(await cache.value(for: id, fingerprint: "op read new") == nil)
    }

    @Test("A mismatch drops the entry rather than leaving it to answer later")
    func fingerprintMismatchEvicts() async {
        let cache = ResolvedPasswordCache()
        let id = UUID()
        await cache.store("old", for: id, fingerprint: "a", lifetime: 900)
        _ = await cache.value(for: id, fingerprint: "b")
        #expect(await cache.count == 0)
    }

    @Test("Stores nothing when the user turned caching off")
    func zeroLifetimeStoresNothing() async {
        let cache = ResolvedPasswordCache()
        let id = UUID()
        await cache.store("secret", for: id, fingerprint: "cmd", lifetime: 0)
        #expect(await cache.value(for: id, fingerprint: "cmd") == nil)
        #expect(await cache.count == 0)
    }

    @Test("Invalidating one connection leaves the others alone")
    func invalidatesOne() async {
        let cache = ResolvedPasswordCache()
        let kept = UUID()
        let dropped = UUID()
        await cache.store("a", for: kept, fingerprint: "cmd", lifetime: 900)
        await cache.store("b", for: dropped, fingerprint: "cmd", lifetime: 900)
        await cache.invalidate(dropped)
        #expect(await cache.value(for: kept, fingerprint: "cmd") == "a")
        #expect(await cache.value(for: dropped, fingerprint: "cmd") == nil)
    }

    @Test("Invalidating everything empties the cache")
    func invalidatesAll() async {
        let cache = ResolvedPasswordCache()
        await cache.store("a", for: UUID(), fingerprint: "cmd", lifetime: 900)
        await cache.store("b", for: UUID(), fingerprint: "cmd", lifetime: 900)
        await cache.invalidateAll()
        #expect(await cache.count == 0)
    }

    @Test("A new entry sweeps out the ones that already expired")
    func purgesExpiredOnStore() async {
        let cache = ResolvedPasswordCache()
        let start = Date()
        await cache.store("a", for: UUID(), fingerprint: "cmd", lifetime: 60, now: start)
        await cache.store("b", for: UUID(), fingerprint: "cmd", lifetime: 60, now: start.addingTimeInterval(120))
        #expect(await cache.count == 1)
    }
}
