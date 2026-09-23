//
//  SQLiteIndexCatalogTests.swift
//  TableProTests
//

import Foundation
import SQLite3
@testable import TablePro
import TableProPluginKit
import Testing

private final class InMemorySQLite {
    private var handle: OpaquePointer?

    init() throws {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else { throw SQLiteTestError(message: "open") }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func run(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec"
            sqlite3_free(error)
            throw SQLiteTestError(message: message)
        }
    }

    func rows(_ sql: String) throws -> [[PluginCellValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[PluginCellValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return .null }
                return .text(String(cString: text))
            })
        }
        return rows
    }
}

private struct SQLiteTestError: Error {
    let message: String
}

@Suite("SQLite index catalog")
@MainActor
struct SQLiteIndexCatalogTests {
    private static let table = """
        CREATE TABLE t (
            id INTEGER PRIMARY KEY, v TEXT, a TEXT, b TEXT, "Weird, Name" TEXT, "lower(v)" TEXT, email TEXT UNIQUE
        )
        """

    private static let indexes = [
        "CREATE INDEX i_mix ON t (id, coalesce(a, b))",
        "CREATE INDEX i_fn ON t (lower(v))",
        "CREATE INDEX i_desc ON t (lower(v) COLLATE NOCASE DESC, v DESC)",
        "CREATE INDEX i_partial ON t (a) WHERE b IS NOT NULL",
        #"CREATE INDEX i_colnamed ON t ("lower(v)", "Weird, Name")"#,
        #"CREATE INDEX "i ""q""" ON t ((lower(v)))"#,
    ]

    private static let measuredRows: [[PluginCellValue]] = [
        ["i \"q\"", "0", "c", "-2", nil, #"CREATE INDEX "i ""q""" ON t ((lower(v)))"#],
        ["i_colnamed", "0", "c", "5", "lower(v)", #"CREATE INDEX i_colnamed ON t ("lower(v)", "Weird, Name")"#],
        ["i_colnamed", "0", "c", "4", "Weird, Name", #"CREATE INDEX i_colnamed ON t ("lower(v)", "Weird, Name")"#],
        ["i_partial", "0", "c", "2", "a", "CREATE INDEX i_partial ON t (a) WHERE b IS NOT NULL"],
        ["i_desc", "0", "c", "-2", nil, "CREATE INDEX i_desc ON t (lower(v) COLLATE NOCASE DESC, v DESC)"],
        ["i_desc", "0", "c", "1", "v", "CREATE INDEX i_desc ON t (lower(v) COLLATE NOCASE DESC, v DESC)"],
        ["i_fn", "0", "c", "-2", nil, "CREATE INDEX i_fn ON t (lower(v))"],
        ["i_mix", "0", "c", "0", "id", "CREATE INDEX i_mix ON t (id, coalesce(a, b))"],
        ["i_mix", "0", "c", "-2", nil, "CREATE INDEX i_mix ON t (id, coalesce(a, b))"],
        ["sqlite_autoindex_t_1", "1", "u", "6", "email", nil],
    ]

    private func database() throws -> InMemorySQLite {
        let database = try InMemorySQLite()
        try database.run(Self.table)
        for statement in Self.indexes {
            try database.run(statement)
        }
        return database
    }

    private func read(_ database: InMemorySQLite) throws -> [String: PluginIndexInfo] {
        let indexes = SQLiteIndexCatalog.indexes(fromRows: try database.rows(SQLiteIndexCatalog.indexesQuery(table: "t")))
        return Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })
    }

    private func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    @Test("The measured rows give every key part, expression, predicate and spelling")
    func measuredRowsGroup() throws {
        let indexes = Dictionary(
            uniqueKeysWithValues: SQLiteIndexCatalog.indexes(fromRows: Self.measuredRows).map { ($0.name, $0) }
        )

        let mixed = try #require(indexes["i_mix"])
        #expect(mixed.columns == ["id", "coalesce(a, b)"])
        #expect(mixed.expressions == ["coalesce(a, b)"])
        #expect(mixed.ddlMethodAndKeys == "(id, coalesce(a, b))")

        #expect(indexes["i_fn"]?.columns == ["lower(v)"])
        #expect(indexes["i_fn"]?.expressions == ["lower(v)"])

        let descending = try #require(indexes["i_desc"])
        #expect(descending.columns == ["lower(v) COLLATE NOCASE", "v"])
        #expect(descending.expressions == ["lower(v) COLLATE NOCASE"])
        #expect(descending.ddlMethodAndKeys == "(lower(v) COLLATE NOCASE DESC, v DESC)")

        #expect(indexes["i_partial"]?.columns == ["a"])
        #expect(indexes["i_partial"]?.whereClause == "b IS NOT NULL")

        #expect(indexes["i_colnamed"]?.columns == ["lower(v)", "Weird, Name"])
        #expect(indexes["i_colnamed"]?.expressions == nil)

        #expect(indexes["i \"q\""]?.expressions == ["(lower(v))"])

        let constraint = try #require(indexes["sqlite_autoindex_t_1"])
        #expect(constraint.columns == ["email"])
        #expect(constraint.isUnique)
        #expect(constraint.ddlMethodAndKeys == nil)
    }

    @Test("The catalog query against SQLite returns what was measured")
    func liveQueryMatchesTheMeasurement() throws {
        let live = try read(try database())
        let measured = SQLiteIndexCatalog.indexes(fromRows: Self.measuredRows)
        for index in measured {
            let read = try #require(live[index.name])
            #expect(read.columns == index.columns, "\(index.name)")
            #expect(read.expressions == index.expressions, "\(index.name)")
            #expect(read.whereClause == index.whereClause, "\(index.name)")
            #expect(read.ddlMethodAndKeys == index.ddlMethodAndKeys, "\(index.name)")
        }
    }

    @Test("The schema-wide query groups each table's indexes")
    func schemaWideQuery() throws {
        let database = try database()
        try database.run("CREATE TABLE u (x TEXT)")
        try database.run("CREATE INDEX u_upper ON u (upper(x))")

        let byTable = SQLiteIndexCatalog.indexesByTable(fromRows: try database.rows(SQLiteIndexCatalog.schemaIndexesQuery))
        #expect(byTable["u"]?.map(\.columns) == [["upper(x)"]])
        #expect(byTable["t"]?.count == 7)
    }

    @Test("Renaming an index recreates its sort order and collation")
    func renameKeepsSortOrderAndCollation() throws {
        let database = try database()
        var index = EditableIndexDefinition.from(IndexInfo(try #require(try read(database)["i_desc"])))
        index.name = "i_desc_renamed"

        try database.run("DROP INDEX i_desc")
        try database.run(SQLiteIndexCatalog.createStatement(for: index.toPlugin(), table: "t", quote: quote))

        let renamed = try #require(try read(database)["i_desc_renamed"])
        #expect(renamed.columns == ["lower(v) COLLATE NOCASE", "v"])
        #expect(renamed.ddlMethodAndKeys == "(lower(v) COLLATE NOCASE DESC, v DESC)")
    }

    @Test("Renaming a partial index keeps its condition")
    func renameKeepsTheCondition() throws {
        let database = try database()
        var index = EditableIndexDefinition.from(IndexInfo(try #require(try read(database)["i_partial"])))
        index.name = "i_partial_renamed"

        try database.run("DROP INDEX i_partial")
        try database.run(SQLiteIndexCatalog.createStatement(for: index.toPlugin(), table: "t", quote: quote))

        #expect(try read(database)["i_partial_renamed"]?.whereClause == "b IS NOT NULL")
    }

    @Test("A typed expression is written as typed and read back as an expression")
    func typedExpressionRoundTrips() throws {
        let database = try database()
        var index = EditableIndexDefinition.placeholder()
        let keys = IndexKeyContext.testing(.sqlite, columns: ["id", "v", "a", "b"])
        StructureEditingSupport.updateIndex(&index, at: 0, with: "i_typed", keys: keys)
        StructureEditingSupport.updateIndex(&index, at: 1, with: "a || ', ' || b, id", keys: keys)

        let statement = SQLiteIndexCatalog.createStatement(for: index.toPlugin(), table: "t", quote: quote)
        #expect(statement == #"CREATE INDEX "i_typed" ON "t" (a || ', ' || b, "id")"#)
        try database.run(statement)

        let read = try #require(try read(database)["i_typed"])
        #expect(read.columns == ["a || ', ' || b", "id"])
        #expect(read.expressions == ["a || ', ' || b"])
    }

    @Test("A partial index keeps its WHERE predicate")
    func partialIndexStatement() {
        let index = PluginIndexDefinition(
            name: "idx_open", columns: ["parent_id"], isUnique: true, whereClause: "deleted_at IS NULL"
        )
        #expect(
            SQLiteIndexCatalog.createStatement(for: index, table: "child", quote: { "`\($0)`" })
                == "CREATE UNIQUE INDEX `idx_open` ON `child` (`parent_id`) WHERE deleted_at IS NULL"
        )
    }

    @Test("An index is its own statement")
    func indexStatement() {
        let index = PluginIndexDefinition(name: "idx_parent", columns: ["parent_id"], isUnique: true)
        #expect(
            SQLiteIndexCatalog.createStatement(for: index, table: "child", quote: { "`\($0)`" })
                == "CREATE UNIQUE INDEX `idx_parent` ON `child` (`parent_id`)"
        )
    }
}
