//
//  CatalogEditAdoptionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("LoadedBrowseCatalog")
struct LoadedBrowseCatalogTests {
    private func ref(_ name: String, database: String? = nil, schema: String? = nil) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: database, schema: schema, table: TestFixtures.makeTableInfo(name: name))
    }

    @Test("a queued object the loaded catalog no longer has is stale")
    func missingObjectIsStale() {
        let catalog = LoadedBrowseCatalog(
            database: "shop", schemas: [], tables: [TestFixtures.makeTableInfo(name: "orders")]
        )
        let gone = ref("sidebar_probe")
        let kept = ref("orders", database: "shop")

        #expect(catalog.staleRefs(in: [gone, kept]) == [gone])
    }

    @Test("an object queued in another database is never judged against this one")
    func anotherDatabaseIsLeftAlone() {
        let catalog = LoadedBrowseCatalog(database: "shop", schemas: [], tables: [])
        let archived = ref("orders_2019", database: "archive")

        #expect(catalog.staleRefs(in: [archived]).isEmpty)
    }

    @Test("a same-named table in another schema does not keep a dropped one alive")
    func schemaDisambiguatesSameName() {
        let catalog = LoadedBrowseCatalog(
            database: "shop",
            schemas: ["public", "analytics"],
            tables: [TestFixtures.makeTableInfo(name: "users", schema: "public")]
        )
        let dropped = ref("users", schema: "analytics")
        let alive = ref("users", schema: "public")

        #expect(catalog.staleRefs(in: [dropped, alive]) == [dropped])
    }

    @Test("an object in a schema the catalog has not loaded is left alone")
    func unloadedSchemaIsLeftAlone() {
        let catalog = LoadedBrowseCatalog(
            database: "shop", schemas: ["public"], tables: [TestFixtures.makeTableInfo(name: "orders", schema: "public")]
        )

        #expect(catalog.staleRefs(in: [ref("events", schema: "billing")]).isEmpty)
    }
}

@Suite("Restoring staged table operations")
struct RestoreStagedTableOperationsTests {
    private func ref(_ name: String) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: "shop", schema: nil, table: TestFixtures.makeTableInfo(name: name))
    }

    @Test("a failed save adds its operations back without erasing ones staged while it ran")
    func restoreKeepsWhatWasStagedMeanwhile() {
        var session = ConnectionSession(connection: TestFixtures.makeConnection())
        session.pendingDeletes = [ref("staged_during_save")]

        session.restoreStagedTableOperations(
            truncates: [ref("logs")],
            deletes: [ref("orders")],
            options: [ref("orders"): TableOperationOptions(ignoreForeignKeys: true, cascade: false)]
        )

        #expect(session.pendingDeletes == [ref("staged_during_save"), ref("orders")])
        #expect(session.pendingTruncates == [ref("logs")])
        #expect(session.tableOperationOptions[ref("orders")]?.ignoreForeignKeys == true)
    }

    @Test("an object staged again during the save keeps its newer choice")
    func restageWinsOverRestore() {
        var session = ConnectionSession(connection: TestFixtures.makeConnection())
        session.pendingTruncates = [ref("orders")]
        session.tableOperationOptions = [ref("orders"): TableOperationOptions(ignoreForeignKeys: false, cascade: true)]

        session.restoreStagedTableOperations(
            truncates: [],
            deletes: [ref("orders")],
            options: [ref("orders"): TableOperationOptions(ignoreForeignKeys: true, cascade: false)]
        )

        #expect(session.pendingTruncates == [ref("orders")])
        #expect(session.pendingDeletes.isEmpty)
        #expect(session.tableOperationOptions[ref("orders")]?.cascade == true)
    }
}
