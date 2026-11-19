import Foundation
import TableProPluginKit
import Testing

private struct Denied: LocalizedError {
    var errorDescription: String? { "permission denied" }
}

private final class CatalogSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    let bulkReads: PluginExportBulkReads
    var failingGroupReads: PluginExportBulkReads = []
    var cancelsGroupReads = false
    var failingIndexTables: Set<String> = []
    private let lock = NSLock()
    private var recorded: [String] = []

    private let indexDDL = [
        "orders": ["CREATE INDEX orders_open ON shop.orders USING btree (customer_id) WHERE (status <> 'shipped')"],
        "totals": ["CREATE UNIQUE INDEX totals_customer ON shop.totals USING btree (customer_id)"]
    ]
    private let commentDDL = [
        "orders": [#"COMMENT ON TABLE "shop"."orders" IS 'Orders'"#, #"COMMENT ON COLUMN "shop"."orders"."note" IS 'Free text'"#],
        "recent": [#"COMMENT ON VIEW "shop"."recent" IS 'Recent'"#]
    ]
    private let sequences = [
        "orders": [PluginSequenceInfo(name: "shared_seq", ddl: "CREATE SEQUENCE \"shared_seq\";")],
        "customers": [
            PluginSequenceInfo(name: "customers_id_seq", ddl: "CREATE SEQUENCE \"customers_id_seq\";"),
            PluginSequenceInfo(name: "shared_seq", ddl: "CREATE SEQUENCE \"shared_seq\";")
        ]
    ]
    private let types = [
        "orders": [PluginEnumTypeInfo(name: "order_status", labels: ["new", "it's done"])],
        "customers": [PluginEnumTypeInfo(name: "mood", labels: ["happy", "sad"])]
    ]

    init(bulkReads: PluginExportBulkReads) {
        self.bulkReads = bulkReads
    }

    var calls: [String] {
        lock.withLock { recorded }
    }

    private func record(_ call: String) {
        lock.withLock { recorded.append(call) }
    }

    private func groupRead<Value>(_ kind: PluginExportBulkReads, _ name: String, _ answer: [String: [Value]]) throws
        -> [String: [Value]] {
        record("all \(name)")
        if cancelsGroupReads { throw CancellationError() }
        if failingGroupReads.contains(kind) { throw Denied() }
        return answer
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id"], columnTypeNames: ["integer"])))
            continuation.yield(.rows([[.text("1")]]))
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        "CREATE TABLE \"\(databaseName)\".\"\(table)\" (id integer)"
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        switch object.kind {
        case .view: "CREATE VIEW \"\(object.databaseName)\".\"\(object.name)\" AS SELECT 1"
        case .materializedView: "CREATE MATERIALIZED VIEW \"\(object.databaseName)\".\"\(object.name)\" AS SELECT 1"
        default: try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func escapeStringLiteral(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        record("index \(table)")
        if failingIndexTables.contains(table) { throw Denied() }
        return indexDDL[table] ?? []
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        record("comments \(table)")
        return commentDDL[table] ?? []
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        record("sequences \(table)")
        return sequences[table] ?? []
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        record("types \(table)")
        return types[table] ?? []
    }

    func fetchAllIndexDDL(databaseName: String) async throws -> [String: [String]] {
        try groupRead(.indexDDL, "index", indexDDL)
    }

    func fetchAllCommentDDL(databaseName: String) async throws -> [String: [String]] {
        try groupRead(.commentDDL, "comments", commentDDL)
    }

    func fetchAllDependentSequences(databaseName: String) async throws -> [String: [PluginSequenceInfo]] {
        try groupRead(.dependentSequences, "sequences", sequences)
    }

    func fetchAllDependentTypes(databaseName: String) async throws -> [String: [PluginEnumTypeInfo]] {
        try groupRead(.dependentTypes, "types", types)
    }
}

// Answers the group read for the NFC spelling of café only, and each table's own read for whatever it is asked.
private final class UnicodeNameSource: PluginExportDataSource, @unchecked Sendable {
    static let composed = "caf\u{E9}"
    static let decomposed = "cafe\u{301}"
    let databaseTypeId = "PostgreSQL"
    let bulkReads: PluginExportBulkReads = [.commentDDL]
    private(set) var tableReads: [String] = []

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func escapeStringLiteral(_ value: String) -> String { value }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchAllCommentDDL(databaseName: String) async throws -> [String: [String]] {
        [Self.composed: ["COMMENT ON TABLE composed"]]
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        tableReads.append(table)
        return ["COMMENT ON VIEW decomposed"]
    }
}

struct SQLExportGroupReadTests {
    private static let everyRead: PluginExportBulkReads = [.indexDDL, .commentDDL, .dependentSequences, .dependentTypes]

    private static func object(_ name: String, _ kind: PluginExportObjectKind, in schema: String = "shop")
        -> PluginExportTable {
        PluginExportTable(
            name: name, databaseName: schema, tableType: kind.rawValue,
            optionValues: [true, true, true], schema: schema, kind: kind
        )
    }

    private static let objects = [
        object("customers", .table), object("orders", .table), object("plain", .table),
        object("recent", .view), object("totals", .materializedView)
    ]

    private func dump(_ objects: [PluginExportTable], from source: CatalogSource) async throws
        -> (text: String, warnings: [String]) {
        let output = try await SQLExportHarness.shared.dump(tables: objects, dataSource: source)
        let text = output.text.components(separatedBy: "\n").filter { !$0.hasPrefix("-- Generated: ") }
        return (text.joined(separator: "\n"), output.result.warnings)
    }

    @Test("A group the source reads whole is asked once per kind, and the dump is the one table reads write")
    func groupReadsWriteTheTableReadDump() async throws {
        let grouped = CatalogSource(bulkReads: Self.everyRead)
        let alone = CatalogSource(bulkReads: [])

        let groupedDump = try await dump(Self.objects, from: grouped)
        let aloneDump = try await dump(Self.objects, from: alone)

        #expect(grouped.calls == ["all sequences", "all types", "all comments", "all index"])
        #expect(alone.calls.contains("index orders"))
        #expect(alone.calls.contains("comments recent"))
        #expect(groupedDump.text == aloneDump.text)
        #expect(groupedDump.warnings == aloneDump.warnings)
        #expect(groupedDump.text.contains("CREATE TYPE \"order_status\" AS ENUM ('new', 'it''s done');"))
        #expect(groupedDump.text.contains("CREATE UNIQUE INDEX totals_customer"))
        #expect(groupedDump.text.contains(#"COMMENT ON VIEW "shop"."recent" IS 'Recent';"#))
    }

    @Test("A group read that fails leaves each object to its own read, which still names the table it failed on")
    func failedGroupReadFallsBackToTableReads() async throws {
        let grouped = CatalogSource(bulkReads: Self.everyRead)
        grouped.failingGroupReads = [.indexDDL]
        grouped.failingIndexTables = ["orders"]
        let alone = CatalogSource(bulkReads: [])
        alone.failingIndexTables = ["orders"]

        let groupedDump = try await dump(Self.objects, from: grouped)
        let aloneDump = try await dump(Self.objects, from: alone)

        #expect(grouped.calls.filter { $0.hasPrefix("all index") }.count == 1)
        #expect(grouped.calls.contains("index orders"))
        #expect(grouped.calls.contains("index totals"))
        #expect(groupedDump.text == aloneDump.text)
        #expect(groupedDump.warnings.contains("Could not fetch indexes for: orders"))
        #expect(groupedDump.warnings == aloneDump.warnings)
    }

    @Test("A group with one object of a kind reads that object alone")
    func loneObjectReadsAlone() async throws {
        let source = CatalogSource(bulkReads: Self.everyRead)
        let objects = [Self.object("orders", .table, in: "shop"), Self.object("customers", .table, in: "crm"),
                       Self.object("plain", .table, in: "crm")]

        _ = try await dump(objects, from: source)

        #expect(source.calls.filter { $0.hasPrefix("all ") }.count == 4)
        #expect(source.calls.contains("sequences orders"))
        #expect(source.calls.contains("comments orders"))
        #expect(source.calls.contains("index orders"))
        #expect(!source.calls.contains("index customers"))
    }

    @Test("A group read that reaches the row limit is not taken as any table's answer")
    func groupReadAtTheRowLimitFallsBack() async throws {
        let source = CatalogSource(bulkReads: Self.everyRead)
        let tables = [Self.object("orders", .table), Self.object("totals", .materializedView)]
        let reads = SQLExportGroupReads(
            dataSource: source,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)),
            tables: tables,
            commentedObjects: tables,
            indexedObjects: tables,
            rowLimit: 2
        )

        #expect(try await reads.indexDDL(for: tables[0]).count == 1)
        #expect(try await reads.indexDDL(for: tables[1]).count == 1)
        #expect(source.calls == ["all index", "index orders", "index totals"])
    }

    @Test("A name Swift equates with a group key but the server keeps apart reads its own answer")
    func unicodeFormOfAGroupKeyReadsAlone() async throws {
        let source = UnicodeNameSource()
        let table = Self.object(UnicodeNameSource.composed, .table)
        let view = Self.object(UnicodeNameSource.decomposed, .view)
        let reads = SQLExportGroupReads(
            dataSource: source,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)),
            tables: [table],
            commentedObjects: [table, view],
            indexedObjects: [table]
        )

        #expect(try await reads.commentDDL(for: table) == ["COMMENT ON TABLE composed"])
        #expect(try await reads.commentDDL(for: view) == ["COMMENT ON VIEW decomposed"])
        #expect(source.tableReads.count == 1)
        #expect(source.tableReads.first?.unicodeScalars.elementsEqual(UnicodeNameSource.decomposed.unicodeScalars) == true)
    }

    @Test("A cancelled group read is rethrown rather than answered table by table")
    func cancelledGroupReadIsRethrown() async throws {
        let source = CatalogSource(bulkReads: Self.everyRead)
        source.cancelsGroupReads = true
        let tables = [Self.object("orders", .table), Self.object("customers", .table)]
        let reads = SQLExportGroupReads(
            dataSource: source,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)),
            tables: tables,
            commentedObjects: tables,
            indexedObjects: tables
        )

        await #expect(throws: CancellationError.self) {
            try await reads.dependentTypes(for: tables[0])
        }
        #expect(source.calls == ["all types"])
    }
}
