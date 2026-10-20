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

    @Test("without a schema list the only known schema is the active one")
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

    @Test("the connection's schemas and databases are offered, and another schema's tables are read once")
    func namespacesAndOtherSchemaTables() async {
        let reads = SchemaTableReads(["sales": [table("invoices"), table("Quarterly Totals", .view)]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .postgresql, schema: "public",
            readColumns: CatalogColumnSource([:]).reader, readSchemaTables: reads.reader,
            schemas: ["public", "sales"], databases: ["shop", "archive"]
        )

        #expect(await catalog.isKnownSchema("SALES"))
        #expect(await catalog.isKnownDatabase("archive"))
        #expect(labels(await catalog.schemaCompletionItems()) == ["public", "sales"])
        #expect(labels(await catalog.namespaceCompletionItems()) == ["shop", "archive", "public", "sales"])
        let first = await catalog.tableCompletionItems(inSchema: "sales")
        let again = await catalog.tableCompletionItems(inSchema: "sales")
        #expect(labels(first) == ["invoices", "Quarterly Totals"])
        #expect(first.map(\.insertText) == ["invoices", "\"Quarterly Totals\""])
        #expect(labels(again) == labels(first))
        #expect(await reads.count == 1)
    }

    @Test("another schema's tables come from the catalog connection first, from the session only while reads are open")
    func schemaTablesPreferTheCatalog() async {
        let catalogReads = SchemaTableReads(["sales": [table("from_catalog")]])
        let sessionReads = SchemaTableReads(["sales": [table("from_session")], "audit": [table("log")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .postgresql, schema: "public",
            readColumns: CatalogColumnSource([:]).reader,
            readSchemaTables: sessionReads.reader, readCatalogSchemaTables: catalogReads.reader,
            schemas: ["public", "sales", "audit"]
        )

        let sales = await catalog.tableCompletionItems(inSchema: "sales")
        await catalogReads.answerNothing()
        await catalog.setColumnReadsAllowed(false)
        let closed = await catalog.tableCompletionItems(inSchema: "audit")
        await catalog.setColumnReadsAllowed(true)
        let open = await catalog.tableCompletionItems(inSchema: "audit")

        #expect(labels(sales) == ["from_catalog"])
        #expect(closed.isEmpty)
        #expect(labels(open) == ["log"])
        #expect(await sessionReads.count == 1)
    }

    @Test("closing session reads waits for a schema read already sent on the session")
    func closeWaitsForSessionSchemaRead() async {
        let sessionReads = SchemaTableReads(["sales": [table("invoices")]], held: true)
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .postgresql, schema: "public",
            readColumns: CatalogColumnSource([:]).reader, readSchemaTables: sessionReads.reader,
            schemas: ["public", "sales"]
        )

        let pending = Task { await catalog.tableCompletionItems(inSchema: "sales") }
        await sessionReads.waitForRead()
        let close = Task { await catalog.closeSessionReads() }
        await sessionReads.release()
        await close.value

        #expect(labels(await pending.value) == ["invoices"])
        #expect(await sessionReads.finished == 1)
    }

    @Test("listed schemas insert quoted by the engine's case rules and keep their own table lists")
    func schemasKeepTheirSpelling() async {
        let reads = SchemaTableReads(["sales": [table("lower_orders")], "Sales": [table("upper_orders")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .postgresql, schema: "public",
            readColumns: CatalogColumnSource([:]).reader, readSchemaTables: reads.reader,
            schemas: ["public", "sales", "Sales"]
        )

        let items = await catalog.schemaCompletionItems()
        let lower = await catalog.tableCompletionItems(inSchema: "sales")
        let upper = await catalog.tableCompletionItems(inSchema: "Sales")

        #expect(items.map(\.insertText) == ["public", "sales", "\"Sales\""])
        #expect(labels(lower) == ["lower_orders"])
        #expect(labels(upper) == ["upper_orders"])
        #expect(await reads.count == 2)
    }

    @Test("a schema that differs from the active one only in case lists its own tables")
    func caseDistinctSchemaIsNotTheActiveOne() async {
        let reads = SchemaTableReads(["Sales": [table("upper_orders")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("lower_orders")], databaseType: .postgresql, schema: "sales",
            readColumns: CatalogColumnSource([:]).reader, readSchemaTables: reads.reader,
            schemas: ["public", "sales", "Sales"]
        )

        #expect(labels(await catalog.tableCompletionItems(inSchema: "Sales")) == ["upper_orders"])
        #expect(labels(await catalog.tableCompletionItems(inSchema: "sales")) == ["lower_orders"])
    }

    @Test("on MySQL a database qualifies a table, and its tables are read once")
    func mysqlDatabaseQualifiesTables() async {
        let reads = SchemaTableReads(["archive": [table("orders_2019")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .mysql, schema: nil,
            readColumns: CatalogColumnSource([:]).reader, readSchemaTables: reads.reader,
            databases: ["shop", "archive"]
        )

        #expect(await catalog.isKnownSchema("ARCHIVE"))
        #expect(labels(await catalog.tableCompletionItems(inSchema: "archive")) == ["orders_2019"])
        #expect(await reads.count == 1)
    }

    @Test("an enum column offers its values: the driver's labels, or the ENUM type MySQL and DuckDB spell out")
    func enumValues() async {
        let source = CatalogColumnSource([
            "orders": [
                ColumnInfo(name: "status", typeName: "enum('new','paid','it''s late')"),
                ColumnInfo(name: "tags", typeName: "ENUM('a', 'b')[]")
            ],
            "moods": [ColumnInfo(name: "mood", typeName: "USER-DEFINED", allowedValues: ["sad", "ok"])]
        ])
        let catalog = catalog(source, tables: [table("orders"), table("moods")], type: .mysql)
        _ = await catalog.columnCompletionItems(for: "orders", schema: nil)
        _ = await catalog.columnCompletionItems(for: "moods", schema: nil)
        let orders = [TableReference(tableName: "orders", alias: nil)]

        #expect(await catalog.allowedValues(forColumn: "STATUS", in: orders) == ["new", "paid", "it's late"])
        #expect(await catalog.allowedValues(forColumn: "tags", in: orders).isEmpty)
        let moods = [TableReference(tableName: "moods", alias: nil)]
        #expect(await catalog.allowedValues(forColumn: "mood", in: moods) == ["sad", "ok"])
    }

    @Test("enum values of a table named in the statement are read when no columns are cached yet")
    func enumValuesOnColdCache() async {
        let source = CatalogColumnSource(["orders": [ColumnInfo(name: "status", typeName: "enum('new','paid')")]])
        let catalog = catalog(source, tables: [table("orders")], type: .mysql)

        #expect(await catalog.allowedValues(forColumn: "status", in: []).isEmpty)
        let derived = [TableReference(tableName: "c", alias: nil, derivedColumns: ["status"])]
        #expect(await catalog.allowedValues(forColumn: "status", in: derived).isEmpty)
        #expect(await source.reads.isEmpty)
        let orders = [TableReference(tableName: "orders", alias: nil)]
        #expect(await catalog.allowedValues(forColumn: "status", in: orders) == ["new", "paid"])
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

    @Test("the catalog connection reads first and is not closed by a run; the session reads only without one")
    func catalogConnectionFirst() async {
        let catalogSource = CatalogColumnSource(["orders": [column("id")]])
        let sessionSource = CatalogColumnSource(["orders": [column("total")], "customers": [column("name")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders"), table("customers")], databaseType: .mysql, schema: nil,
            readColumns: sessionSource.reader, readCatalogColumns: catalogSource.reader
        )

        await catalog.setColumnReadsAllowed(false)
        let orders = await catalog.columnCompletionItems(for: "orders", schema: nil)
        #expect(labels(orders) == ["id"])
        #expect(await sessionSource.reads.isEmpty)

        await catalogSource.answerNothing(1)
        await catalog.setColumnReadsAllowed(true)
        let customers = await catalog.columnCompletionItems(for: "customers", schema: nil)
        #expect(labels(customers) == ["name"])
        #expect(await catalogSource.reads == ["orders", "customers"])
        #expect(await sessionSource.reads == ["customers"])
    }

    @Test("a name the list does not hold, such as a temporary table, is read on the session when the catalog has none")
    func temporaryTableReadsTheSession() async {
        let catalogSource = CatalogColumnSource(["orders": [column("id")]])
        let sessionSource = CatalogColumnSource(["scratch": [column("note")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .mysql, schema: nil,
            readColumns: sessionSource.reader, readCatalogColumns: catalogSource.reader
        )

        let scratch = await catalog.columnCompletionItems(for: "scratch", schema: nil)
        let orders = await catalog.columnCompletionItems(for: "orders", schema: nil)

        #expect(labels(scratch) == ["note"])
        #expect(labels(orders) == ["id"])
        #expect(await sessionSource.reads == ["scratch"])
    }

    @Test("a temporary table the session made is read there, even when it shadows a listed table")
    func sessionLocalTableReadsTheSession() async {
        let catalogSource = CatalogColumnSource(["orders": [column("id")]])
        let sessionSource = CatalogColumnSource(["orders": [column("draft_note")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .mysql, schema: nil,
            readColumns: sessionSource.reader, readCatalogColumns: catalogSource.reader
        )

        await catalog.replaceSessionLocalTables(["orders"])
        let shadowed = await catalog.columnCompletionItems(for: "orders", schema: nil)

        #expect(labels(shadowed) == ["draft_note"])
        #expect(await catalogSource.reads.isEmpty)
    }

    @Test("a failed catalog read does not fall back to the session")
    func catalogFailureStays() async {
        let catalogSource = CatalogColumnSource(["orders": [column("id")]], failures: 1)
        let sessionSource = CatalogColumnSource(["orders": [column("total")]])
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .mysql, schema: nil,
            readColumns: sessionSource.reader, readCatalogColumns: catalogSource.reader
        )

        let failed = await catalog.columnCompletionItems(for: "orders", schema: nil)

        #expect(failed.isEmpty)
        #expect(await sessionSource.reads.isEmpty)
    }

    @Test("a run waits only for column reads sent on the session")
    func runWaitsOnlyForSessionReads() async {
        let catalogSource = CatalogColumnSource(["orders": [column("id")]], held: true)
        let catalog = QueryCompletionCatalog(
            tables: [table("orders")], databaseType: .mysql, schema: nil,
            readColumns: CatalogColumnSource([:]).reader, readCatalogColumns: catalogSource.reader
        )

        let pending = Task { await catalog.columnCompletionItems(for: "orders", schema: nil) }
        await catalogSource.waitForRead()
        await catalog.finishReads()

        await catalogSource.release()
        #expect(labels(await pending.value) == ["id"])
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

private actor SchemaTableReads {
    private let tables: [String: [TableInfo]]
    private var isHeld: Bool
    private var answersNothing = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    private(set) var finished = 0

    init(_ tables: [String: [TableInfo]], held: Bool = false) {
        self.tables = tables
        self.isHeld = held
    }

    nonisolated var reader: QuerySchemaTableReader {
        { schema in await self.read(schema) }
    }

    func answerNothing() {
        answersNothing = true
    }

    func waitForRead() async {
        guard count == 0 else { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func release() {
        isHeld = false
        heldReads.forEach { $0.resume() }
        heldReads = []
    }

    private func read(_ schema: String) async -> [TableInfo]? {
        guard !answersNothing else { return nil }
        count += 1
        readWaiters.forEach { $0.resume() }
        readWaiters = []
        if isHeld {
            await withCheckedContinuation { heldReads.append($0) }
        }
        finished += 1
        return tables[schema] ?? []
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

    func answerNothing(_ count: Int) {
        sessionlessReads = count
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
