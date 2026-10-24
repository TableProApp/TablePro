import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

private struct StubCatalog: SQLCompletionCatalog {
    let tables: [String]
    let columns: [String: [String]]
    var values: [String] = []
    var databases: [String] = []
    var schemas: [String] = []
    var schemaTables: [String: [String]] = [:]

    func resolveAlias(_ aliasOrName: String, in references: [TableReference]) -> String? {
        let name = aliasOrName.lowercased()
        if let match = references.first(where: { $0.alias?.lowercased() == name }) {
            return match.tableName
        }
        if let match = references.first(where: { $0.tableName.lowercased() == name }) {
            return match.tableName
        }
        return tables.first { $0.lowercased() == name }
    }

    func columnCompletionItems(for tableName: String, schema: String?) -> [SQLCompletionItem] {
        (columns[tableName.lowercased()] ?? []).map { SQLCompletionItem.column($0, dataType: nil, tableName: tableName) }
    }

    func tableCompletionItems() -> [SQLCompletionItem] {
        tables.map { SQLCompletionItem.table($0) }
    }

    func tableCompletionItems(inSchema schema: String) -> [SQLCompletionItem] {
        (schemaTables[schema] ?? []).map { SQLCompletionItem.table($0) }
    }

    func schemaCompletionItems() -> [SQLCompletionItem] { schemas.map { SQLCompletionItem.schemaName($0) } }
    func namespaceCompletionItems() -> [SQLCompletionItem] { [] }
    func isKnownSchema(_ name: String) -> Bool { schemas.contains(name) }
    func isKnownDatabase(_ name: String) -> Bool { databases.contains(name) }
    func allowedValues(forColumn column: String, in references: [TableReference]) -> [String] { values }

    func allColumnsInScope(for references: [TableReference]) -> [SQLCompletionItem] {
        references.flatMap { reference in
            guard let derived = reference.derivedColumns else {
                return columnCompletionItems(for: reference.tableName, schema: reference.schema)
            }
            return derived.map { SQLCompletionItem.column($0, dataType: nil, tableName: reference.identifier) }
        }
    }

    func allColumnsFromCachedTables() -> [SQLCompletionItem] { [] }
}

struct SQLCompletionProviderCatalogTests {
    private let provider = SQLCompletionProvider(
        catalog: StubCatalog(
            tables: ["customers", "orders"],
            columns: ["orders": ["id", "total", "status"], "customers": ["id", "name"]]
        ),
        grammar: .engine("SQLite"),
        vocabulary: .generic
    )

    // `|` marks the cursor.
    private func labels(_ marked: String) async -> [String] {
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        return await provider.completionSession(text: text, cursorPosition: marker.location).items.map(\.label)
    }

    @Test("A table slot leads with the table the prefix names")
    func tableSlotLeadsWithTheTable() async {
        let session = await provider.completionSession(text: "SELECT * FROM or", cursorPosition: 16)
        #expect(session.items.first?.label == "orders")
    }

    @Test("An alias with a dot offers its table's columns")
    func aliasDotOffersColumns() async {
        let session = await provider.completionSession(text: "SELECT o. FROM orders o", cursorPosition: 9)
        #expect(Set(session.items.map(\.label)) == ["id", "total", "status"])
    }

    @Test("A database and a dot offer its schemas")
    func databaseDotOffersSchemas() async {
        let catalog = StubCatalog(
            tables: [], columns: [:], databases: ["shop"], schemas: ["sales", "audit"],
            schemaTables: ["shop": ["orders"]]
        )
        let provider = SQLCompletionProvider(catalog: catalog, grammar: .engine("SQLite"), vocabulary: .generic)
        let session = await provider.completionSession(text: "SELECT * FROM shop.", cursorPosition: 19)
        #expect(Set(session.items.map(\.label)) == ["sales", "audit"])
    }

    @Test("A database and a dot offer its tables on an engine with no schemas")
    func databaseDotOffersTablesWithoutSchemas() async {
        let catalog = StubCatalog(
            tables: [], columns: [:], databases: ["shop"], schemaTables: ["shop": ["orders", "customers"]]
        )
        let provider = SQLCompletionProvider(catalog: catalog, grammar: .engine("SQLite"), vocabulary: .generic)
        let session = await provider.completionSession(text: "SELECT * FROM shop.", cursorPosition: 19)
        #expect(Set(session.items.map(\.label)) == ["orders", "customers"])
    }

    @Test("UPDATE offers tables")
    func updateOffersTables() async {
        let session = await provider.completionSession(text: "UPDATE or", cursorPosition: 9)
        #expect(session.items.contains { $0.label == "orders" && $0.kind == .table })
    }

    @Test("A cursor in a string offers nothing")
    func stringOffersNothing() async {
        let text = "SELECT * FROM orders WHERE note = 'or"
        let session = await provider.completionSession(text: text, cursorPosition: (text as NSString).length)
        #expect(session.items.isEmpty)
        #expect(session.context.isInsideString)
    }

    @Test("A quoted name with a space ranks on the whole name")
    func quotedNameRanksOnTheWholeName() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["Details", "Order Details", "orders"], columns: [:]),
            grammar: .engine("SQL Server"),
            vocabulary: .generic
        )
        let session = await provider.completionSession(text: "SELECT * FROM [Order Det]", cursorPosition: 24)
        #expect(session.items.first?.label == "Order Details")
        #expect(!session.items.contains { $0.label == "Details" })
    }

    // `[ord|]` offered ORDER BY and LEFT OUTER JOIN, which an accept wrote between the brackets.
    @Test("Inside a quoted name only names are offered")
    func quotedNameOffersOnlyNames() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["orders"], columns: [:]),
            grammar: .engine("SQL Server"),
            vocabulary: .generic
        )
        let quoted = await provider.completionSession(text: "SELECT * FROM [ord]", cursorPosition: 18)
        #expect(quoted.items.contains { $0.label == "orders" })
        #expect(!quoted.items.contains { $0.kind == .keyword })

        let bare = await provider.completionSession(text: "SELECT * FROM ord", cursorPosition: 17)
        #expect(bare.items.contains { $0.kind == .keyword })
    }

    @Test("A vocabulary's statement completions replace the generic statement keywords")
    func vocabularyStatementCompletions() {
        let custom = SQLCompletionProvider(
            catalog: nil,
            grammar: .ansi,
            vocabulary: SQLCompletionVocabulary(statementCompletions: [.init(label: "FIND", insertText: "FIND ")])
        )
        #expect(custom.statementStartCompletionItems().map(\.label) == ["FIND"])
        #expect(provider.statementStartCompletionItems().contains { $0.label == "SELECT" })
    }

    // MARK: - CTEs and derived tables

    @Test("A MATERIALIZED CTE offers its columns", arguments: ["MATERIALIZED", "NOT MATERIALIZED"])
    func materializedCteColumns(_ hint: String) async {
        let labels = await labels("WITH recent AS \(hint) (SELECT id, total FROM orders) SELECT r.| FROM recent r")
        #expect(Set(labels) == ["id", "total"])
    }

    @Test("A data-modifying CTE offers its RETURNING columns")
    func dataModifyingCteColumns() async {
        let labels = await labels("WITH moved AS (DELETE FROM queue WHERE done RETURNING id, payload) SELECT m.| FROM moved m")
        #expect(Set(labels) == ["id", "payload"])
    }

    @Test("RETURNING star offers the written table's columns from the catalog")
    func returningStarColumns() async {
        let dotted = await labels("WITH moved AS (DELETE FROM orders WHERE status = 'done' RETURNING *) SELECT m.| FROM moved m")
        #expect(Set(dotted) == ["id", "total", "status"])
        let listed = await labels("WITH moved AS (DELETE FROM orders RETURNING *) SELECT | FROM moved")
        #expect(Set(["id", "total", "status"]).isSubset(of: Set(listed)))
    }

    @Test("A column list renames a star's columns by position")
    func columnListOverStar() async {
        let labels = await labels("WITH moved (order_id) AS (DELETE FROM orders RETURNING *) SELECT m.| FROM moved m")
        #expect(Set(labels) == ["order_id", "total", "status"])
    }

    @Test("A star over another CTE reads that CTE")
    func starOverSiblingCte() async {
        let labels = await labels("WITH a AS (SELECT * FROM orders), b AS (SELECT * FROM a) SELECT b.| FROM b")
        #expect(Set(labels) == ["id", "total", "status"])
    }

    @Test("A CTE that reads its own name reads the table, not itself")
    func cteShadowingItsTable() async {
        let labels = await labels("WITH orders AS (SELECT * FROM orders WHERE total > 0) SELECT o.| FROM orders o")
        #expect(Set(labels) == ["id", "total", "status"])
    }

    @Test("A derived table over a star offers its table's columns")
    func derivedStarColumns() async {
        let labels = await labels("SELECT x.| FROM (SELECT * FROM orders) x")
        #expect(Set(labels) == ["id", "total", "status"])
    }

    @Test("A USING join lists its join column once, so a column list renames the right columns", arguments: [
        ("WITH c AS (SELECT * FROM a JOIN b USING (id)) SELECT c.| FROM c", ["id", "x", "y"]),
        ("WITH c (key, ax, by) AS (SELECT * FROM a JOIN b USING (id)) SELECT c.| FROM c", ["key", "ax", "by"]),
        ("WITH c (key, ax) AS (SELECT * FROM a, b) SELECT c.| FROM c", ["key", "ax", "y", "id"]),
        ("WITH c AS (SELECT * FROM a NATURAL JOIN b) SELECT c.| FROM c", ["id", "x", "y"]),
        ("WITH c (key, ax, by) AS (SELECT * FROM a NATURAL LEFT JOIN b) SELECT c.| FROM c", ["key", "ax", "by"]),
    ])
    func usingJoinStar(_ marked: String, _ columns: [String]) async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["a", "b"], columns: ["a": ["x", "id"], "b": ["y", "id"]]),
            grammar: .engine("PostgreSQL"),
            vocabulary: .generic
        )
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        let labels = await provider.completionSession(text: text, cursorPosition: marker.location).items.map(\.label)
        #expect(labels.count == columns.count)
        #expect(Set(labels) == Set(columns))
    }

    @Test("SET inside a CTE offers the UPDATE table's columns")
    func setInsideCte() async {
        let labels = await labels("WITH u AS (UPDATE orders SET st| WHERE id = 1 RETURNING *) SELECT * FROM u")
        #expect(labels.first == "status")
    }

    @Test("SET offers the UPDATE table's columns, not a FROM table's")
    func setWithFromTable() async {
        let labels = await labels("UPDATE orders SET | FROM customers c WHERE c.id = orders.id")
        #expect(labels.contains("total"))
        #expect(!labels.contains("name"))
    }

    @Test("SET reads a table the UPDATE names by its FROM alias")
    func setThroughFromAlias() async {
        let labels = await labels("UPDATE o SET st| FROM orders o JOIN customers c ON c.id = o.id")
        #expect(labels.first == "status")
    }

    @Test("A star expands the real table, not a derived table of the same name")
    func starIgnoresSiblingDerivedName() async {
        let labels = await labels("SELECT d.| FROM (SELECT * FROM orders) d, (SELECT 1 AS fake) orders")
        #expect(Set(labels) == ["id", "total", "status"])
    }

    @Test("An INSERT column list offers the INSERT table's columns, not the SELECT's")
    func insertColumnsWithSelect() async {
        let labels = await labels("INSERT INTO orders (|) SELECT id, name FROM customers")
        #expect(labels.contains("total"))
        #expect(!labels.contains("name"))
    }

    // MARK: - ORDER BY

    @Test("ORDER BY offers a SELECT alias ahead of the table columns")
    func orderByAliasLeads() async {
        let empty = await labels("SELECT total * 2 AS line_total FROM orders ORDER BY |")
        #expect(empty.first == "line_total")
        #expect(empty.contains("total"))
        let typed = await labels("SELECT total * 2 AS line_total FROM orders ORDER BY li|")
        #expect(typed.first == "line_total")
    }

    @Test("ORDER BY inserts a quoted alias as written")
    func orderByQuotedAlias() async {
        let marked = "SELECT total AS \"Grand Total\" FROM orders ORDER BY Gr|"
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        let items = await provider.completionSession(text: text, cursorPosition: marker.location).items
        #expect(items.first?.label == "Grand Total")
        #expect(items.first?.insertText == "\"Grand Total\"")
    }

    @Test("Inside an opened quote ORDER BY inserts the alias's bare name")
    func orderByAliasInsideQuotes() async {
        let marked = "SELECT total AS \"Grand Total\" FROM orders ORDER BY \"Gr|\""
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        let items = await provider.completionSession(text: text, cursorPosition: marker.location).items
        #expect(items.first?.label == "Grand Total")
        #expect(items.first?.insertText == "Grand Total")
    }

    @Test("A string-literal alias is inserted as a quoted name", arguments: [
        ("SQLite", "\"Grand Total\""),
        ("MySQL", "`Grand Total`"),
    ])
    func orderByLiteralAlias(_ engine: String, _ insertText: String) async {
        let provider = SQLCompletionProvider(catalog: nil, grammar: .engine(engine), vocabulary: .generic)
        let text = "SELECT total AS 'Grand Total', 1 AS 'plain' FROM orders ORDER BY "
        let items = await provider.completionSession(text: text, cursorPosition: (text as NSString).length).items
        #expect(items.first { $0.label == "Grand Total" }?.insertText == insertText)
        #expect(items.first { $0.label == "plain" }?.insertText == "plain")
    }

    @Test("An opened quote with no close is replaced along with the name, so the alias keeps its quotes")
    func orderByAliasAfterOpenQuote() async {
        let text = "SELECT total AS \"Grand Total\" FROM orders ORDER BY \"Gr"
        let items = await provider.completionSession(text: text, cursorPosition: (text as NSString).length).items
        #expect(items.first?.label == "Grand Total")
        #expect(items.first?.insertText == "\"Grand Total\"")
    }

    @Test("A quoted alias differing only in case from a column is still offered")
    func orderByQuotedAliasCase() async {
        let marked = "SELECT total AS \"Status\" FROM orders ORDER BY St|"
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        let items = await provider.completionSession(text: text, cursorPosition: marker.location).items
        #expect(items.first?.insertText == "\"Status\"")
        #expect(items.contains { $0.label == "status" })
    }

    @Test("A string-literal alias that is a keyword is inserted quoted")
    func orderByKeywordLiteralAlias() async {
        let provider = SQLCompletionProvider(catalog: nil, grammar: .engine("SQLite"), vocabulary: .generic)
        let text = "SELECT 1 AS 'group' FROM orders ORDER BY gr"
        let items = await provider.completionSession(text: text, cursorPosition: (text as NSString).length).items
        #expect(items.first { $0.label == "group" }?.insertText == "\"group\"")
    }

    @Test("ORDER BY offers an alias that repeats a column name once")
    func orderByAliasMatchingColumn() async {
        let labels = await labels("SELECT status AS status, total FROM orders ORDER BY |")
        #expect(labels.filter { $0 == "status" }.count == 1)
    }

    @Test("ORDER BY inside an aggregate offers no output alias")
    func orderByInsideAggregate() async {
        let labels = await labels("SELECT string_agg(status, ',' ORDER BY |) AS statuses FROM orders")
        #expect(!labels.contains("statuses"))
        #expect(labels.contains("status"))
    }

    @Test("An allowed value with an apostrophe inserts as a valid literal")
    func allowedValueIsEscaped() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["orders"], columns: ["orders": ["status"]], values: ["it's late"]),
            grammar: .engine("MySQL"),
            vocabulary: .generic
        )
        let text = "SELECT * FROM orders WHERE status = "
        let session = await provider.completionSession(text: text, cursorPosition: (text as NSString).length)

        let item = session.items.first { $0.label == "'it's late'" }
        #expect(item?.insertText == "'it''s late'")
    }

    @Test("A table-qualified column is marked as two names; a column whose name holds a dot is not")
    func qualifiedReferenceIsMarked() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(
                tables: ["orders", "customers"],
                columns: ["orders": ["order.total"], "customers": ["id"]]
            ),
            grammar: .engine("PostgreSQL"),
            vocabulary: .generic
        )
        let text = "SELECT * FROM orders o JOIN customers c ON "
        let session = await provider.completionSession(text: text, cursorPosition: (text as NSString).length)

        #expect(session.items.first { $0.label == "o.order.total" }?.isQualifiedReference == true)
        #expect(session.items.first { $0.label == "c.id" }?.isQualifiedReference == true)
        #expect(session.items.first { $0.label == "order.total" }?.isQualifiedReference == false)
    }

    @Test("A function the engine writes bare inserts with no parentheses")
    func bareFunctionHasNoParentheses() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["orders"], columns: [:]),
            grammar: .engine("Oracle"),
            vocabulary: .curated(forDatabaseTypeId: "Oracle")
        )
        let text = "SELECT SYS"
        let session = await provider.completionSession(text: text, cursorPosition: (text as NSString).length)

        #expect(session.items.first { $0.label == "SYSDATE" }?.insertText == "SYSDATE")
        #expect(session.items.first { $0.label == "SYS_GUID" }?.insertText == "SYS_GUID()")

        let sqlServer = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["orders"], columns: [:]),
            grammar: .engine("SQL Server"),
            vocabulary: .curated(forDatabaseTypeId: "SQL Server")
        )
        let global = "SELECT @@ROW"
        let globals = await sqlServer.completionSession(text: global, cursorPosition: (global as NSString).length)
        #expect(globals.items.first { $0.label == "@@ROWCOUNT" }?.insertText == "@@ROWCOUNT")
    }

    // MARK: - Large catalogs

    @Test("A pool cut short of the matches says so, and one holding every match does not")
    func cutPoolIsMarked() async {
        let large = SQLCompletionProvider(
            catalog: StubCatalog(tables: (0..<500).map { String(format: "t%03d", $0) }, columns: [:]),
            grammar: .engine("MySQL"),
            vocabulary: .generic
        )

        let cut = await large.completionSession(text: "SELECT * FROM ", cursorPosition: 14)
        let whole = await provider.completionSession(text: "SELECT * FROM ", cursorPosition: 14)

        #expect(cut.candidates.count == 400)
        #expect(cut.candidatesTruncated)
        #expect(!whole.candidatesTruncated)
    }
}

@MainActor
struct SQLCompletionProviderIsolationTests {
    @available(macOS 15, iOS 18, *)
    @Test("Filtering and ranking run off the caller's actor")
    func rankingLeavesTheCallersActor() async {
        let provider = SQLCompletionProvider(
            catalog: StubCatalog(tables: ["customers", "orders"], columns: [:]),
            grammar: .engine("MySQL"),
            vocabulary: .generic
        )
        let executor = CountingTaskExecutor()

        let session = await withTaskExecutorPreference(executor) {
            await provider.completionSession(text: "SELECT * FROM or", cursorPosition: 16)
        }

        #expect(session.items.first?.label == "orders")
        #expect(executor.enqueuedJobs > 0)
    }
}

// The caller's own actor never reaches it, so a job here is work that left the caller.
@available(macOS 15, iOS 18, *)
private final class CountingTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var enqueuedJobs: Int { lock.withLock { count } }

    func enqueue(_ job: consuming ExecutorJob) {
        lock.withLock { count += 1 }
        let job = UnownedJob(job)
        DispatchQueue.global().async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
