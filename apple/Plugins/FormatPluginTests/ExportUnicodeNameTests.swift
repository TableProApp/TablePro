import Foundation
import TableProPluginKit
import Testing

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"

private struct Denied: LocalizedError {
    var errorDescription: String? { "permission denied" }
}

private struct TwinNames: LocalizedError {
    var errorDescription: String? { "two relations share a name in different Unicode forms" }
}

private struct Relation {
    let schema: String
    let name: String
    var columns: [PluginColumnInfo] = []
    var foreignKeys: [PluginForeignKeyInfo] = []
    var indexes: [PluginIndexInfo] = []
    var sequences: [PluginSequenceInfo] = []
    var types: [PluginEnumTypeInfo] = []
}

private func same(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

// A server that keeps names apart by their bytes. A group read answers by the String keys PluginKit hands back, and
// throws when two relations of the schema would share a key, as PostgreSQL's export reads do.
private final class ByteExactCatalog: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    let bulkReads: PluginExportBulkReads
    let relations: [Relation]
    var failingColumnGroups = false
    // A group answer keyed by this spelling only, as a source that merged two spellings returns it.
    var columnGroupAnswer: [String: [PluginColumnInfo]]?
    private let lock = NSLock()
    private var recorded: [String] = []

    init(_ relations: [Relation], bulkReads: PluginExportBulkReads = []) {
        self.relations = relations
        self.bulkReads = bulkReads
    }

    var calls: [String] {
        lock.withLock { recorded }
    }

    private func record(_ call: String) {
        lock.withLock { recorded.append(call) }
    }

    private func relation(_ name: String, in schema: String) -> Relation? {
        relations.first { same($0.schema, schema) && same($0.name, name) }
    }

    private func group<Value>(_ schema: String, _ values: (Relation) -> [Value]) throws -> [String: [Value]] {
        var answer: [String: [Value]] = [:]
        for relation in relations where same(relation.schema, schema) {
            if let known = answer.index(forKey: relation.name), !same(answer[known].key, relation.name) {
                throw TwinNames()
            }
            answer[relation.name] = values(relation)
        }
        return answer
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let names = relation(table, in: databaseName)?.columns.map(\.name) ?? []
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: names, columnTypeNames: names.map { _ in "integer" })))
            continuation.yield(.rows([names.map { _ in .text("1") }]))
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        let columns = relation(table, in: databaseName)?.columns.map { "\($0.name) integer" } ?? []
        return "CREATE TABLE \(quoteIdentifier(databaseName)).\(quoteIdentifier(table)) (\(columns.joined(separator: ", ")))"
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func escapeStringLiteral(_ value: String) -> String { value }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        record("columns \(table)")
        return relation(table, in: databaseName)?.columns ?? []
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        record("all columns \(databaseName)")
        if failingColumnGroups { throw Denied() }
        if let columnGroupAnswer { return columnGroupAnswer }
        return try group(databaseName, \.columns)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        relation(table, in: databaseName)?.foreignKeys ?? []
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try group(databaseName, \.foreignKeys)
    }

    var tableDDLIncludesForeignKeys: Bool { false }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        relation(table, in: databaseName)?.indexes ?? []
    }

    func fetchAllIndexes(databaseName: String) async throws -> [String: [PluginIndexInfo]] {
        try group(databaseName, \.indexes)
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        relation(table, in: databaseName)?.sequences ?? []
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        relation(table, in: databaseName)?.types ?? []
    }
}

private func table(_ name: String, in schema: String) -> PluginExportTable {
    PluginExportTable(
        name: name, databaseName: schema, tableType: "table", optionValues: [true, true, true], schema: schema, kind: .table
    )
}

// Byte-exact: String's own `contains` and `==` equate the two spellings this suite tells apart.
private func lines(_ text: String) -> [[UInt8]] {
    text.components(separatedBy: "\n").map { Array($0.utf8) }
}

private func count(_ line: String, in text: String) -> Int {
    lines(text).filter { $0 == Array(line.utf8) }.count
}

private func firstLine(of line: String, in text: String) -> Int? {
    lines(text).firstIndex(of: Array(line.utf8))
}

private func dump(_ tables: [PluginExportTable], from source: ByteExactCatalog) async throws
    -> (text: String, warnings: [String]) {
    let output = try await SQLExportHarness.shared.dump(tables: tables, dataSource: source)
    return (output.text, output.result.warnings)
}

private func dictionary(_ tables: [PluginExportTable], from source: ByteExactCatalog) async throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("names.md")
    let plugin = DataDictionaryExportPlugin()
    let original = plugin.settings
    defer { plugin.settings = original }
    plugin.settings.fileType = .markdown
    _ = try await plugin.export(
        tables: tables,
        dataSource: source,
        destination: destination,
        progress: PluginExportProgress(progress: Progress(totalUnitCount: 0))
    )
    return try String(contentsOf: destination, encoding: .utf8)
}

private func column(_ name: String, identity: IdentityKind? = nil) -> PluginColumnInfo {
    PluginColumnInfo(name: name, dataType: "integer", identityKind: identity)
}

private func foreignKey(_ name: String, from column: String, to parent: String, in schema: String) -> PluginForeignKeyInfo {
    PluginForeignKeyInfo(
        name: name, column: column, referencedTable: parent, referencedColumn: "id", referencedSchema: schema
    )
}

struct ExportUnicodeNameTests {
    // café composed, and café decomposed with a key to it, side by side in one schema as PostgreSQL 17.11 allows.
    private static let twinTables = [
        Relation(schema: "uni", name: decomposed, columns: [column("id"), column("b")],
                 foreignKeys: [foreignKey("child_fk", from: "b", to: composed, in: "uni")]),
        Relation(schema: "uni", name: composed, columns: [column("id", identity: .always), column("a")]),
    ]

    @Test("Two tables whose names differ only in Unicode form are both dumped, each with its own columns and keys")
    func twinTablesAreBothDumped() async throws {
        let source = ByteExactCatalog(Self.twinTables)
        let output = try await dump([table(decomposed, in: "uni"), table(composed, in: "uni")], from: source)

        #expect(output.warnings.isEmpty)
        #expect(count("-- Table: \(composed)", in: output.text) == 1)
        #expect(count("-- Table: \(decomposed)", in: output.text) == 1)
        let parent = try #require(firstLine(of: "-- Table: \(composed)", in: output.text))
        let child = try #require(firstLine(of: "-- Table: \(decomposed)", in: output.text))
        #expect(parent < child)
        #expect(count("INSERT INTO \"\(composed)\" (\"id\", \"a\") OVERRIDING SYSTEM VALUE VALUES", in: output.text) == 1)
        #expect(count("INSERT INTO \"\(decomposed)\" (\"id\", \"b\") VALUES", in: output.text) == 1)
        #expect(count(
            "SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence('\"\(composed)\"', 'id'), "
                + "GREATEST(COALESCE((SELECT MAX(\"id\") FROM \"\(composed)\"), 0), 1), true);",
            in: output.text) == 1)
        #expect(lines(output.text).filter { $0.starts(with: Array("SELECT pg_catalog.setval".utf8)) }.count == 1)
        #expect(count(
            "ALTER TABLE \"\(decomposed)\" ADD CONSTRAINT \"child_fk\" FOREIGN KEY (\"b\") REFERENCES \"\(composed)\" (\"id\");",
            in: output.text) == 1)
        #expect(lines(output.text).filter { $0.starts(with: Array("ALTER TABLE".utf8)) }.count == 1)
    }

    @Test("Two schemas whose names differ only in Unicode form each take their own group read and qualified names")
    func twinSchemasReadApart() async throws {
        let source = ByteExactCatalog([
            Relation(schema: composed, name: "t", columns: [column("id", identity: .byDefault)]),
            Relation(schema: decomposed, name: "t", columns: [column("other")]),
        ])
        let output = try await dump([table("t", in: composed), table("t", in: decomposed)], from: source)

        #expect(source.calls.filter { $0.hasPrefix("all columns") }.count == 2)
        #expect(count("INSERT INTO \"\(composed)\".\"t\" (\"id\") VALUES", in: output.text) == 1)
        #expect(count("INSERT INTO \"\(decomposed)\".\"t\" (\"other\") VALUES", in: output.text) == 1)
        #expect(count(
            "SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence('\"\(composed)\".\"t\"', 'id'), "
                + "GREATEST(COALESCE((SELECT MAX(\"id\") FROM \"\(composed)\".\"t\"), 0), 1), true);",
            in: output.text) == 1)
        #expect(lines(output.text).filter { $0.starts(with: Array("SELECT pg_catalog.setval".utf8)) }.count == 1)
    }

    @Test("Sequences and enum types whose names differ only in Unicode form are each created")
    func twinSequencesAndTypesAreEachCreated() async throws {
        let source = ByteExactCatalog([
            Relation(schema: "uni", name: "a", columns: [column("id")],
                     sequences: [PluginSequenceInfo(name: composed, ddl: "CREATE SEQUENCE \"\(composed)\";")],
                     types: [PluginEnumTypeInfo(name: composed, labels: ["x"])]),
            Relation(schema: "uni", name: "b", columns: [column("id")],
                     sequences: [PluginSequenceInfo(name: decomposed, ddl: "CREATE SEQUENCE \"\(decomposed)\";")],
                     types: [PluginEnumTypeInfo(name: decomposed, labels: ["y"])]),
        ])
        let output = try await dump([table("a", in: "uni"), table("b", in: "uni")], from: source)

        #expect(count("CREATE SEQUENCE \"\(composed)\";", in: output.text) == 1)
        #expect(count("CREATE SEQUENCE \"\(decomposed)\";", in: output.text) == 1)
        #expect(count("CREATE TYPE \"\(composed)\" AS ENUM ('x');", in: output.text) == 1)
        #expect(count("CREATE TYPE \"\(decomposed)\" AS ENUM ('y');", in: output.text) == 1)
    }

    @Test("A column group read that fails reads each table's columns alone instead of dropping them")
    func failedColumnGroupReadsEachTableAlone() async throws {
        let source = ByteExactCatalog([
            Relation(schema: "app", name: "orders", columns: [column("id", identity: .always)]),
            Relation(schema: "app", name: "lines", columns: [column("id")]),
        ])
        source.failingColumnGroups = true
        let output = try await dump([table("orders", in: "app"), table("lines", in: "app")], from: source)

        #expect(output.warnings.isEmpty)
        #expect(source.calls == ["all columns app", "columns orders", "columns lines"])
        #expect(output.text.contains("INSERT INTO \"orders\" (\"id\") OVERRIDING SYSTEM VALUE VALUES"))
        #expect(output.text.contains("pg_get_serial_sequence('\"orders\"', 'id')"))
    }

    @Test("A column group answer holding a name in another Unicode form reads that table alone")
    func otherSpellingInAColumnAnswerReadsAlone() async throws {
        let source = ByteExactCatalog([
            Relation(schema: "uni", name: decomposed, columns: [column("b")]),
            Relation(schema: "uni", name: "plain", columns: [column("p")]),
        ])
        source.columnGroupAnswer = [composed: [column("id", identity: .always)], "plain": [column("p")]]
        let output = try await dump([table(decomposed, in: "uni"), table("plain", in: "uni")], from: source)

        #expect(source.calls.contains { same($0, "columns \(decomposed)") })
        #expect(!source.calls.contains("columns plain"))
        #expect(count("INSERT INTO \"\(decomposed)\" (\"b\") VALUES", in: output.text) == 1)
        #expect(!output.text.contains("OVERRIDING SYSTEM VALUE"))
    }

    @Test("The Data Dictionary gives each of two same-named schemas its own group read")
    func dictionaryReadsTwinSchemasApart() async throws {
        let source = ByteExactCatalog([
            Relation(schema: composed, name: "t", columns: [column("first_col")]),
            Relation(schema: composed, name: "u", columns: [column("u_col")]),
            Relation(schema: decomposed, name: "t", columns: [column("second_col")]),
            Relation(schema: decomposed, name: "v", columns: [column("v_col")]),
        ], bulkReads: [.columns, .foreignKeys, .indexes])
        let text = try await dictionary(
            [table("t", in: composed), table("u", in: composed), table("t", in: decomposed), table("v", in: decomposed)],
            from: source
        )

        #expect(source.calls.filter { $0.hasPrefix("all columns") }.count == 2)
        #expect(!source.calls.contains { $0.hasPrefix("columns ") })
        #expect(text.contains("second_col"))
        #expect(text.contains("first_col"))
        #expect(lines(text).contains(Array("## `\(composed).t`".utf8)))
        #expect(lines(text).contains(Array("## `\(decomposed).t`".utf8)))
    }

    @Test("The Data Dictionary reads alone a table its group answer holds only in another Unicode form")
    func dictionaryReadsOtherSpellingAlone() async throws {
        let source = ByteExactCatalog([
            Relation(schema: "uni", name: decomposed, columns: [column("own_col")]),
            Relation(schema: "uni", name: "plain", columns: [column("p")]),
        ], bulkReads: [.columns, .foreignKeys, .indexes])
        source.columnGroupAnswer = [composed: [column("borrowed_col")], "plain": [column("p")]]
        let text = try await dictionary([table(decomposed, in: "uni"), table("plain", in: "uni")], from: source)

        #expect(source.calls.contains { same($0, "columns \(decomposed)") })
        #expect(text.contains("own_col"))
        #expect(!text.contains("borrowed_col"))
    }

    @Test("A key to one of two same-named tables links to that table's own section")
    func dictionaryLinksTheTwinItNames() {
        let objects = [
            DataDictionaryObject(name: composed, container: "uni", kind: .table),
            DataDictionaryObject(name: decomposed, container: "uni", kind: .table),
            DataDictionaryObject(
                name: "child", container: "uni", kind: .table,
                columns: [column("ref")],
                foreignKeys: [foreignKey("child_fk", from: "ref", to: decomposed, in: "uni")]
            ),
        ]
        let document = DataDictionaryDocument(
            title: "uni", databaseTypeId: "PostgreSQL", generatedAt: Date(timeIntervalSince1970: 0), objects: objects
        )

        #expect(document.anchors[0] != document.anchors[1])
        #expect(document.columnRows(at: 2).first?.references.first?.anchor == document.anchors[1])
        #expect(document.foreignKeyRows(at: 2).first?.target.anchor == document.anchors[1])
    }

    @Test("Objects from two schemas named alike in different Unicode forms are named with their schema")
    func dictionaryQualifiesTwinSchemas() {
        let document = DataDictionaryDocument(
            title: "names", databaseTypeId: "PostgreSQL", generatedAt: Date(timeIntervalSince1970: 0),
            objects: [
                DataDictionaryObject(name: "t", container: composed, kind: .table),
                DataDictionaryObject(name: "t", container: decomposed, kind: .table),
            ]
        )

        #expect(document.qualifiesNames)
    }
}
