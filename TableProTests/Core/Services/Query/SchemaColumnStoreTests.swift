import Foundation
import Testing

@testable import TablePro

@Suite("SchemaColumnStore")
@MainActor
struct SchemaColumnStoreTests {
    @Test("load fetches once and caches the entry")
    func loadFetchesOnceAndCaches() async {
        let store = SchemaColumnStore()
        var fetchCount = 0

        await store.load("k") {
            fetchCount += 1
            return (columns: ["id"], primaryKeys: ["id"])
        }
        await store.load("k") {
            fetchCount += 1
            return (columns: ["other"], primaryKeys: [])
        }

        #expect(fetchCount == 1)
        #expect(store.cached("k")?.columns == ["id"])
    }

    @Test("Concurrent loads for the same key share one fetch")
    func concurrentLoadsShareOneFetch() async {
        let store = SchemaColumnStore()
        let counter = FetchCounter()

        async let first: Void = store.load("k") {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return (columns: ["id"], primaryKeys: ["id"])
        }
        async let second: Void = store.load("k") {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return (columns: ["id"], primaryKeys: ["id"])
        }
        _ = await (first, second)

        #expect(await counter.count == 1)
        #expect(store.cached("k")?.columns == ["id"])
    }

    @Test("Failed fetch is not cached and the next load retries")
    func failedFetchRetries() async {
        let store = SchemaColumnStore()
        var fetchCount = 0

        await store.load("k") {
            fetchCount += 1
            return nil
        }
        #expect(store.cached("k") == nil)

        await store.load("k") {
            fetchCount += 1
            return (columns: ["id"], primaryKeys: [])
        }

        #expect(fetchCount == 2)
        #expect(store.cached("k")?.columns == ["id"])
    }

    @Test("removeAll clears entries and allows a fresh fetch")
    func removeAllClearsAndRefetches() async {
        let store = SchemaColumnStore()
        await store.load("k") { (columns: ["old"], primaryKeys: []) }

        store.removeAll()
        #expect(store.cached("k") == nil)

        await store.load("k") { (columns: ["new"], primaryKeys: []) }
        #expect(store.cached("k")?.columns == ["new"])
    }

    @Test("store and cached round-trip")
    func storeAndCachedRoundTrip() {
        let store = SchemaColumnStore()
        store.store((columns: ["a", "b"], primaryKeys: ["a"]), for: "k")

        #expect(store.cached("k")?.columns == ["a", "b"])
        #expect(store.cached("k")?.primaryKeys == ["a"])
        #expect(store.cached("missing") == nil)
    }
}

private actor FetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
