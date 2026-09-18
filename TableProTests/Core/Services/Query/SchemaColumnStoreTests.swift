import Foundation
import Testing

@testable import TablePro

@Suite("SchemaColumnStore")
@MainActor
struct SchemaColumnStoreTests {
    nonisolated private static func entry(_ columns: [String], primaryKeys: [String] = []) -> SchemaColumnStore.Entry {
        SchemaColumnStore.Entry(columns: columns, primaryKeys: primaryKeys, columnTypes: [:])
    }

    @Test("load fetches once and caches the entry")
    func loadFetchesOnceAndCaches() async {
        let store = SchemaColumnStore()
        var fetchCount = 0

        await store.load("k") {
            fetchCount += 1
            return Self.entry(["id"], primaryKeys: ["id"])
        }
        await store.load("k") {
            fetchCount += 1
            return Self.entry(["other"])
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
            return Self.entry(["id"], primaryKeys: ["id"])
        }
        async let second: Void = store.load("k") {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return Self.entry(["id"], primaryKeys: ["id"])
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
            return Self.entry(["id"])
        }

        #expect(fetchCount == 2)
        #expect(store.cached("k")?.columns == ["id"])
    }

    @Test("removeAll clears entries and allows a fresh fetch")
    func removeAllClearsAndRefetches() async {
        let store = SchemaColumnStore()
        await store.load("k") { Self.entry(["old"]) }

        store.removeAll()
        #expect(store.cached("k") == nil)

        await store.load("k") { Self.entry(["new"]) }
        #expect(store.cached("k")?.columns == ["new"])
    }

    @Test("store and cached round-trip")
    func storeAndCachedRoundTrip() {
        let store = SchemaColumnStore()
        store.store(Self.entry(["a", "b"], primaryKeys: ["a"]), for: "k")

        #expect(store.cached("k")?.columns == ["a", "b"])
        #expect(store.cached("k")?.primaryKeys == ["a"])
        #expect(store.cached("missing") == nil)
    }

    @Test("An entry built from fetched columns types each column from its declared type")
    func fetchedColumnsAreClassified() {
        let entry = SchemaColumnStore.Entry(fetchedColumns: [
            TestFixtures.makeColumnInfo(name: "id", dataType: "INT UNSIGNED", isPrimaryKey: true),
            TestFixtures.makeColumnInfo(name: "code", dataType: "character varying", isPrimaryKey: false),
            TestFixtures.makeColumnInfo(name: "active", dataType: "boolean", isPrimaryKey: false)
        ])

        #expect(entry.columns == ["id", "code", "active"])
        #expect(entry.primaryKeys == ["id"])
        #expect(entry.columnTypes["id"] == .integer(rawType: "INT UNSIGNED"))
        #expect(entry.columnTypes["code"] == .text(rawType: "character varying"))
        #expect(entry.columnTypes["active"] == .boolean(rawType: "boolean"))
    }

    @Test("Aligned types follow the order of the names asked for")
    func alignedTypesFollowTheRequestedOrder() {
        let entry = SchemaColumnStore.Entry(
            columns: ["id", "code"],
            primaryKeys: ["id"],
            columnTypes: ["id": .integer(rawType: "INT"), "code": .text(rawType: "TEXT")]
        )

        #expect(entry.columnTypes(aligningWith: ["code", "id"]) == [.text(rawType: "TEXT"), .integer(rawType: "INT")])
    }

    @Test("A name the table does not have yields no types rather than a shifted list")
    func unknownNameYieldsNoTypes() {
        let entry = SchemaColumnStore.Entry(
            columns: ["id", "code"],
            primaryKeys: ["id"],
            columnTypes: ["id": .integer(rawType: "INT"), "code": .text(rawType: "TEXT")]
        )

        #expect(entry.columnTypes(aligningWith: ["missing", "code"]).isEmpty)
    }
}

private actor FetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
