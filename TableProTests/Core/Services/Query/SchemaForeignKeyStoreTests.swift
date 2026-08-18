//
//  SchemaForeignKeyStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Schema foreign key store")
@MainActor
struct SchemaForeignKeyStoreTests {
    private func makeScope(_ connectionId: UUID, database: String = "shop", schema: String? = "public") -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }

    private func makeForeignKey(column: String, referencedTable: String) -> ForeignKeyInfo {
        TestFixtures.makeForeignKeyInfo(column: column, referencedTable: referencedTable)
    }

    @Test("Stored foreign keys come back keyed by column, which is what the grid indexes by")
    func storedForeignKeysAreKeyedByColumn() {
        let store = SchemaForeignKeyStore()
        let scope = makeScope(UUID())
        store.store(
            ["orders": [makeForeignKey(column: "customer_id", referencedTable: "customers")]],
            for: scope
        )

        let byColumn = store.foreignKeysByColumn(for: scope, table: "orders")

        #expect(byColumn?.count == 1)
        #expect(byColumn?["customer_id"]?.referencedTable == "customers")
    }

    /// The distinction the first paint depends on. An empty dictionary is a fetched answer meaning
    /// "this table has none", and nil means "nothing fetched for this schema", which is what tells
    /// the grid it still has to wait for the table's own metadata.
    @Test("A table with no foreign keys answers empty, an unfetched schema answers nil")
    func absentTableAndAbsentScopeDiffer() {
        let store = SchemaForeignKeyStore()
        let fetched = makeScope(UUID())
        let neverFetched = makeScope(UUID())
        store.store(["orders": [makeForeignKey(column: "customer_id", referencedTable: "customers")]], for: fetched)

        #expect(store.foreignKeysByColumn(for: fetched, table: "customers")?.isEmpty == true)
        #expect(store.foreignKeysByColumn(for: neverFetched, table: "orders") == nil)
    }

    @Test("Schemas and databases inside one connection stay separate")
    func scopesDoNotCollide() {
        let store = SchemaForeignKeyStore()
        let connectionId = UUID()
        let publicScope = makeScope(connectionId, schema: "public")
        let salesScope = makeScope(connectionId, schema: "sales")
        let otherDatabase = makeScope(connectionId, database: "warehouse", schema: "public")
        store.store(["orders": [makeForeignKey(column: "customer_id", referencedTable: "customers")]], for: publicScope)

        #expect(store.foreignKeysByColumn(for: publicScope, table: "orders")?.isEmpty == false)
        #expect(store.foreignKeysByColumn(for: salesScope, table: "orders") == nil)
        #expect(store.foreignKeysByColumn(for: otherDatabase, table: "orders") == nil)
    }

    @Test("Invalidating one connection leaves every other connection intact")
    func invalidationIsScopedToOneConnection() {
        let store = SchemaForeignKeyStore()
        let doomed = makeScope(UUID())
        let survivor = makeScope(UUID())
        let foreignKeys = ["orders": [makeForeignKey(column: "customer_id", referencedTable: "customers")]]
        store.store(foreignKeys, for: doomed)
        store.store(foreignKeys, for: survivor)

        store.invalidate(connectionId: doomed.connectionId)

        #expect(store.foreignKeysByColumn(for: doomed, table: "orders") == nil)
        #expect(store.foreignKeysByColumn(for: survivor, table: "orders")?.isEmpty == false)
    }

    @Test("A scope already fetched is never fetched again")
    func prefetchRunsOncePerScope() async {
        let store = SchemaForeignKeyStore()
        let scope = makeScope(UUID())
        let counter = FetchCounter()

        await store.prefetch(scope: scope) {
            await counter.increment()
            return ["orders": [self.makeForeignKey(column: "customer_id", referencedTable: "customers")]]
        }?.value
        await store.prefetch(scope: scope) {
            await counter.increment()
            return [:]
        }?.value

        #expect(await counter.count == 1)
        #expect(store.foreignKeysByColumn(for: scope, table: "orders")?.isEmpty == false)
    }

    /// A driver that cannot answer in one query returns nil rather than paying a round trip per
    /// table, and that non-answer must not be cached as "this schema has no foreign keys".
    @Test("A declined prefetch caches nothing")
    func declinedPrefetchCachesNothing() async {
        let store = SchemaForeignKeyStore()
        let scope = makeScope(UUID())

        await store.prefetch(scope: scope) { nil }?.value

        #expect(store.foreignKeysByColumn(for: scope, table: "orders") == nil)
    }

    private actor FetchCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }
}
