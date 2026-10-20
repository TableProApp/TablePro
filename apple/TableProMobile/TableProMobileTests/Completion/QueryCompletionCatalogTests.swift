import Foundation
import TableProAutocomplete
@testable import TableProMobile
import TableProModels
import Testing

struct QueryCompletionCatalogTests {
    private func table(_ name: String, _ type: TableInfo.TableKind = .table) -> TableInfo {
        TableInfo(name: name, type: type)
    }

    private func column(_ name: String, _ position: Int = 0) -> ColumnInfo {
        ColumnInfo(name: name, typeName: "integer", ordinalPosition: position)
    }

    private func catalog(
        _ source: CatalogColumnSource,
        tables: [TableInfo],
        type: DatabaseType = .sqlite,
        schema: String? = nil
    ) -> QueryCompletionCatalog {
        QueryCompletionCatalog(tables: tables, databaseType: type, schema: schema, readColumns: source.reader)
    }

    private func labels(_ items: [SQLCompletionItem]) -> [String] {
        items.map { $0.label }
    }

    @Test("a table's columns are read once, by concurrent and later requests alike")
    func oneReadPerTable() async {
        let source = CatalogColumnSource(["orders": [column("id")], "customers": [column("name")]], held: true)
        let catalog = catalog(source, tables: [table("orders"), table("customers")])

        let first = Task { await catalog.columnCompletionItems(for: "orders", schema: nil) }
        await source.waitForRead()
        let second = Task { await catalog.columnCompletionItems(for: "orders", schema: nil) }
        await source.release()
        let firstItems = await first.value
        let secondItems = await second.value
        let later = await catalog.columnCompletionItems(for: "orders", schema: nil)
        _ = await catalog.columnCompletionItems(for: "customers", schema: nil)

        #expect(labels(firstItems) == ["id"])
        #expect(labels(secondItems) == ["id"])
        #expect(labels(later) == ["id"])
        #expect(await source.reads == ["orders", "customers"])
    }

    @Test("a failed read is not kept, so the next request reads again")
    func failedReadIsRetried() async {
        let source = CatalogColumnSource(["orders": [column("id")]], failures: 1)
        let catalog = catalog(source, tables: [table("orders")])

        let failed = await catalog.columnCompletionItems(for: "orders", schema: nil)
        let retried = await catalog.columnCompletionItems(for: "orders", schema: nil)
        let kept = await catalog.columnCompletionItems(for: "orders", schema: nil)

        #expect(failed.isEmpty)
        #expect(labels(retried) == ["id"])
        #expect(labels(kept) == ["id"])
        #expect(await source.reads == ["orders", "orders"])
    }

    @Test("a reader with no session keeps nothing")
    func noSessionKeepsNothing() async {
        let source = CatalogColumnSource(["orders": [column("id")]], sessionlessReads: 1)
        let catalog = catalog(source, tables: [table("orders")])

        let none = await catalog.columnCompletionItems(for: "orders", schema: nil)
        let read = await catalog.columnCompletionItems(for: "orders", schema: nil)

        #expect(none.isEmpty)
        #expect(labels(read) == ["id"])
        #expect(await source.reads == ["orders", "orders"])
    }

    @Test("nothing is read while column reads are closed, and what was read stays offered")
    func noReadWhileClosed() async {
        let source = CatalogColumnSource(["orders": [column("id")], "customers": [column("name")]])
        let catalog = catalog(source, tables: [table("orders"), table("customers")])

        _ = await catalog.columnCompletionItems(for: "orders", schema: nil)
        await catalog.setColumnReadsAllowed(false)
        let unread = await catalog.columnCompletionItems(for: "customers", schema: nil)
        let cached = await catalog.columnCompletionItems(for: "orders", schema: nil)
        #expect(unread.isEmpty)
        #expect(labels(cached) == ["id"])
        #expect(await source.reads == ["orders"])

        await catalog.setColumnReadsAllowed(true)
        let reopened = await catalog.columnCompletionItems(for: "customers", schema: nil)
        #expect(labels(reopened) == ["name"])
        #expect(await source.reads == ["orders", "customers"])
    }

    @Test("an alias, a table name and a listed table all resolve to the listed spelling")
    func caseMapping() async {
        let source = CatalogColumnSource(["Orders": [column("id")]])
        let catalog = catalog(source, tables: [table("Orders")])
        let aliased = [TableReference(tableName: "orders", alias: "o")]

        #expect(await catalog.resolveAlias("O", in: aliased) == "Orders")
        #expect(await catalog.resolveAlias("ORDERS", in: [TableReference(tableName: "orders", alias: nil)]) == "Orders")
        #expect(await catalog.resolveAlias("orders", in: []) == "Orders")
        #expect(await catalog.resolveAlias("missing", in: []) == nil)

        let items = await catalog.columnCompletionItems(for: "orders", schema: nil)
        #expect(labels(items) == ["id"])
        #expect(await source.reads == ["Orders"])
    }

    @Test("a table outside the list is read as the statement names it")
    func unlistedTable() async {
        let source = CatalogColumnSource(["audit_log": [column("id")]])
        let catalog = catalog(source, tables: [table("orders")])

        #expect(await catalog.resolveAlias("a", in: [TableReference(tableName: "audit_log", alias: "a")]) == "audit_log")
        _ = await catalog.columnCompletionItems(for: "audit_log", schema: nil)
        #expect(await source.reads == ["audit_log"])
    }

    @Test("tables and columns insert quoted for the engine, a qualified column per part")
    func perPartQuoting() async {
        let source = CatalogColumnSource([
            "Orders": [column("Total", 0), column("id", 1)],
            "customers": [column("name")],
        ])
        let catalog = catalog(
            source,
            tables: [table("Orders"), table("customers"), table("Recent Orders", .view)],
            type: .postgresql,
            schema: "public"
        )

        let tables = await catalog.tableCompletionItems()
        #expect(tables.map { $0.insertText } == ["\"Orders\"", "customers", "\"Recent Orders\""])
        #expect(tables.map { $0.kind } == [.table, .table, .view])

        let aliased = await catalog.allColumnsInScope(for: [
            TableReference(tableName: "Orders", alias: "O"),
            TableReference(tableName: "customers", alias: "c"),
        ])
        #expect(aliased.map { $0.label } == ["O.Total", "O.id", "c.name"])
        #expect(aliased.map { $0.insertText } == ["O.\"Total\"", "O.id", "c.name"])

        let unaliased = await catalog.allColumnsInScope(for: [
            TableReference(tableName: "orders", alias: nil),
            TableReference(tableName: "customers", alias: nil),
        ])
        #expect(unaliased.map { $0.insertText } == ["\"Orders\".\"Total\"", "\"Orders\".id", "customers.name"])

        let single = await catalog.columnCompletionItems(for: "Orders", schema: nil)
        #expect(single.map { $0.insertText } == ["\"Total\"", "id"])
    }

    @Test("a qualifier quoted in the statement keeps its quotes, so it does not fold to another name")
    func quotedQualifier() async {
        let source = CatalogColumnSource(["orders": [column("id")], "Audit": [column("at")]])
        let catalog = catalog(source, tables: [table("orders")], type: .postgresql, schema: "public")

        let items = await catalog.allColumnsInScope(for: [
            TableReference(tableName: "orders", alias: "O", isIdentifierQuoted: true),
            TableReference(tableName: "Audit", alias: nil, schema: "sales", isIdentifierQuoted: true),
            TableReference(tableName: "orders", alias: "o"),
        ])
        #expect(items.map { $0.insertText } == ["\"O\".id", "\"Audit\".at", "o.id"])
    }

    @Test("two unaliased tables of one name keep their schemas apart")
    func sameNameInTwoSchemas() async {
        let source = CatalogColumnSource(["orders": [column("id")]])
        let catalog = catalog(source, tables: [table("orders")], type: .postgresql, schema: "public")

        let items = await catalog.allColumnsInScope(for: [
            TableReference(tableName: "orders", alias: nil, schema: "public"),
            TableReference(tableName: "orders", alias: nil, schema: "sales"),
        ])
        #expect(items.map { $0.label } == ["public.orders.id", "sales.orders.id"])
        #expect(items.map { $0.insertText } == ["public.orders.id", "sales.orders.id"])
    }

    @Test("columns marked stale are read again on their next use, and a failed read keeps them")
    func staleColumnsReadAgain() async {
        let source = CatalogColumnSource(["orders": [column("id")]])
        let catalog = catalog(source, tables: [table("orders")])

        _ = await catalog.columnCompletionItems(for: "orders", schema: nil)
        await source.setColumns(["orders": [column("id"), column("total", 1)]])
        await catalog.markColumnsStale()
        let refreshed = await catalog.columnCompletionItems(for: "orders", schema: nil)
        let cached = await catalog.columnCompletionItems(for: "orders", schema: nil)

        await source.failNextReads(1)
        await catalog.markColumnsStale()
        let kept = await catalog.columnCompletionItems(for: "orders", schema: nil)

        #expect(labels(refreshed) == ["id", "total"])
        #expect(labels(cached) == ["id", "total"])
        #expect(labels(kept) == ["id", "total"])
        #expect(await source.reads == ["orders", "orders", "orders"])
    }

    @Test("a column on its own inserts without its table")
    func singleReferenceIsUnqualified() async {
        let source = CatalogColumnSource(["orders": [column("id")]])
        let catalog = catalog(source, tables: [table("orders")])

        let items = await catalog.allColumnsInScope(for: [TableReference(tableName: "orders", alias: "o")])
        #expect(items.map { $0.label } == ["id"])
        #expect(items.map { $0.insertText } == ["id"])
    }

    @Test("the only known schema is the active one")
    func activeSchemaOnly() async {
        let source = CatalogColumnSource([:])
        let catalog = catalog(source, tables: [table("orders")], type: .postgresql, schema: "public")

        let active = await catalog.tableCompletionItems(inSchema: "public")
        let other = await catalog.tableCompletionItems(inSchema: "sales")
        #expect(await catalog.isKnownSchema("PUBLIC"))
        #expect(await !catalog.isKnownSchema("sales"))
        #expect(await !catalog.isKnownDatabase("postgres"))
        #expect(labels(active) == ["orders"])
        #expect(other.isEmpty)
    }

    @Test("a schema-qualified table in another schema is read with that schema")
    func foreignSchemaRead() async {
        let source = CatalogColumnSource(["orders": [column("id")]])
        let catalog = catalog(source, tables: [table("Orders")], type: .postgresql, schema: "public")

        _ = await catalog.columnCompletionItems(for: "orders", schema: "sales")
        _ = await catalog.columnCompletionItems(for: "orders", schema: "public")

        #expect(await source.readSchemas == ["sales", nil])
        #expect(await source.reads == ["orders", "Orders"])
    }

    @Test("cached columns answer a statement that names no table, qualified where two tables share a name")
    func cachedColumns() async {
        let source = CatalogColumnSource(["orders": [column("id"), column("total", 1)], "customers": [column("id")]])
        let catalog = catalog(source, tables: [table("orders"), table("customers")])

        #expect(await catalog.allColumnsFromCachedTables().isEmpty)
        _ = await catalog.columnCompletionItems(for: "orders", schema: nil)
        _ = await catalog.columnCompletionItems(for: "customers", schema: nil)

        let items = await catalog.allColumnsFromCachedTables()
        #expect(labels(items) == ["customers.id", "orders.id", "total"])
        #expect(await source.reads == ["orders", "customers"])
    }

    @Test("new tables replace the list and keep the columns already read")
    func replaceTables() async {
        let source = CatalogColumnSource(["orders": [column("id")]])
        let catalog = catalog(source, tables: [table("orders")])

        _ = await catalog.columnCompletionItems(for: "orders", schema: nil)
        await catalog.replaceTables([table("orders"), table("invoices")])

        let tables = await catalog.tableCompletionItems()
        let columns = await catalog.columnCompletionItems(for: "orders", schema: nil)
        #expect(labels(tables) == ["orders", "invoices"])
        #expect(labels(columns) == ["id"])
        #expect(await source.reads == ["orders"])
    }
}

private actor CatalogColumnSource {
    private struct ReadFailure: Error {}

    private var columns: [String: [ColumnInfo]]
    private var isHeld: Bool
    private var failures: Int
    private var sessionlessReads: Int
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads: [String] = []
    private(set) var readSchemas: [String?] = []

    init(_ columns: [String: [ColumnInfo]], held: Bool = false, failures: Int = 0, sessionlessReads: Int = 0) {
        self.columns = columns
        self.isHeld = held
        self.failures = failures
        self.sessionlessReads = sessionlessReads
    }

    nonisolated var reader: QueryColumnReader {
        { table, schema in try await self.read(table, schema) }
    }

    func waitForRead() async {
        guard reads.isEmpty else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func release() {
        isHeld = false
        heldReads.forEach { $0.resume() }
        heldReads = []
    }

    func setColumns(_ columns: [String: [ColumnInfo]]) {
        self.columns = columns
    }

    func failNextReads(_ count: Int) {
        failures = count
    }

    private func read(_ table: String, _ schema: String?) async throws -> [ColumnInfo]? {
        reads.append(table)
        readSchemas.append(schema)
        readWaiters.forEach { $0.resume() }
        readWaiters = []
        if isHeld {
            await withCheckedContinuation { heldReads.append($0) }
        }
        if failures > 0 {
            failures -= 1
            throw ReadFailure()
        }
        if sessionlessReads > 0 {
            sessionlessReads -= 1
            return nil
        }
        return columns[table] ?? []
    }
}
