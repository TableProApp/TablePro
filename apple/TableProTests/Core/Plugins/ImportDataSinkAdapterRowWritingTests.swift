//
//  ImportDataSinkAdapterRowWritingTests.swift
//  TableProTests
//

import Foundation
import SQLite3
@testable import TablePro
import TableProPluginKit
import Testing

private struct SQLiteTestError: Error {
    let message: String
}

private final class InMemorySQLiteDriver: PluginDriverStub, @unchecked Sendable {
    private var handle: OpaquePointer?
    private(set) var statements: [String] = []
    var updateForm: ((_ table: String, _ assignments: String, _ predicate: String) -> String?)?
    var deleteForm: ((_ table: String, _ predicate: String?) -> String?)?
    var immutable: Set<String> = []

    init(_ setup: String) throws {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else { throw SQLiteTestError(message: "open") }
        _ = try run(setup, parameters: [])
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try run(query, parameters: [])
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try run(query, parameters: parameters)
    }

    func rowUpdateStatement(table: String, assignments: String, predicate: String) -> String? {
        updateForm?(table, assignments, predicate)
    }

    func rowDeleteStatement(table: String, predicate: String?) -> String? {
        deleteForm?(table, predicate)
    }

    func fetchImmutableColumns(table: String, schema: String?) async throws -> Set<String> {
        immutable
    }

    func rows(_ sql: String) throws -> [[String?]] {
        try run(sql, parameters: []).rows.map { row in row.map(\.asText) }
    }

    private func run(_ sql: String, parameters: [PluginCellValue]) throws -> PluginQueryResult {
        statements.append(sql)
        var rows: [[PluginCellValue]] = []
        var remaining = sql
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let prepared = remaining.withCString { text -> Int32 in
                let code = sqlite3_prepare_v2(handle, text, -1, &statement, &tail)
                remaining = tail.map { String(cString: $0) } ?? ""
                return code
            }
            guard prepared == SQLITE_OK else { throw SQLiteTestError(message: String(cString: sqlite3_errmsg(handle))) }
            guard let statement else { continue }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in parameters.enumerated() {
                let position = Int32(offset + 1)
                switch value {
                case .null: sqlite3_bind_null(statement, position)
                case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
                case .bytes(let data):
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
                }
            }
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { .text(String(cString: $0)) } ?? .null
                })
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw SQLiteTestError(message: String(cString: sqlite3_errmsg(handle))) }
        }
        return PluginQueryResult(
            columns: [], columnTypeNames: [], rows: rows, rowsAffected: Int(sqlite3_changes(handle)), executionTime: 0
        )
    }
}

// A real SQLite, so each match, update and insert is the database's answer, not a double's.
struct ImportDataSinkAdapterRowWritingTests {
    private static let people = """
        CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT NOT NULL DEFAULT 'none');
        INSERT INTO people VALUES (1, 'a', 'n1'), (2, 'b', 'n2'), (3, 'c', 'n3');
        """

    private func sink(
        on driver: InMemorySQLiteDriver,
        mode: ImportWriteMode,
        key: [String] = ["id"],
        mapping: [String: String] = ["id": "id", "name": "name"]
    ) -> ImportDataSinkAdapter {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .sqlite), pluginDriver: driver)
        return ImportDataSinkAdapter(
            driver: adapter,
            databaseType: .sqlite,
            targetTable: "people",
            columnMapping: mapping,
            sourceFields: Set(mapping.keys),
            rowWriting: mode == .insert ? .insert : ImportRowWriting(mode: mode, keyColumns: key)
        )
    }

    private func people(_ driver: InMemorySQLiteDriver) throws -> [[String?]] {
        try driver.rows("SELECT id, name, note FROM people ORDER BY id")
    }

    private static let changedAndNew: [[String: PluginCellValue]] = [
        ["id": .text("2"), "name": .text("b2")],
        ["id": .text("4"), "name": .text("d")],
    ]

    @Test("Update changes the mapped columns of matched rows and leaves new rows out")
    func updateWritesMatchedRowsOnly() async throws {
        let driver = try InMemorySQLiteDriver("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT NOT NULL);
            INSERT INTO people VALUES (1, 'a', 'n1'), (2, 'b', 'n2'), (3, 'c', 'n3');
            """)
        let sink = sink(on: driver, mode: .update)

        try await sink.insertRows(Self.changedAndNew)

        #expect(try people(driver) == [["1", "a", "n1"], ["2", "b2", "n2"], ["3", "c", "n3"]])
        var expected = ImportRowTally(mode: .update)
        expected.updated = 1
        expected.unmatched = 1
        #expect(sink.rowTally == expected)
    }

    @Test("A matched row is updated with the driver's own UPDATE form, its values bound in order")
    func updateUsesDriverForm() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        driver.updateForm = { table, assignments, predicate in
            "UPDATE OR ABORT \(table) SET \(assignments) WHERE \(predicate)"
        }
        let sink = sink(on: driver, mode: .upsert)

        try await sink.insertRows(Self.changedAndNew)

        #expect(try people(driver) == [["1", "a", "n1"], ["2", "b2", "n2"], ["3", "c", "n3"], ["4", "d", "none"]])
        #expect(driver.statements.contains(#"UPDATE OR ABORT "people" SET "name" = ? WHERE "id" = ?"#))
        #expect(!driver.statements.contains { $0.hasPrefix(#"UPDATE ""#) })
    }

    @Test("A column no UPDATE may assign keeps its value on a matched row and is written for a new one")
    func immutableColumnIsLeftOutOfUpdates() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        driver.immutable = ["note"]
        let sink = sink(on: driver, mode: .upsert, mapping: ["id": "id", "name": "name", "note": "note"])

        try await sink.insertRows([
            ["id": .text("2"), "name": .text("b2"), "note": .text("changed")],
            ["id": .text("4"), "name": .text("d"), "note": .text("n4")],
        ])

        #expect(try people(driver) == [["1", "a", "n1"], ["2", "b2", "n2"], ["3", "c", "n3"], ["4", "d", "n4"]])
        #expect(sink.rowTally.updated == 1)
    }

    @Test("Delete existing rows empties the table with the driver's own statement")
    func clearingUsesDriverForm() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        driver.deleteForm = { table, predicate in predicate == nil ? "DELETE FROM \(table) WHERE 1" : nil }
        let sink = sink(on: driver, mode: .insert)

        try await sink.deleteAllRowsFromTargetTable()

        #expect(try people(driver).isEmpty)
        #expect(driver.statements.contains(#"DELETE FROM "people" WHERE 1"#))
    }

    @Test("Insert or Update updates matched rows and inserts the rest")
    func upsertUpdatesAndInserts() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        let sink = sink(on: driver, mode: .upsert)

        try await sink.insertRows(Self.changedAndNew)

        #expect(try people(driver) == [["1", "a", "n1"], ["2", "b2", "n2"], ["3", "c", "n3"], ["4", "d", "none"]])
        #expect(sink.rowTally.updated == 1)
        #expect(sink.rowTally.inserted == 1)
        #expect(sink.rowTally.matched == 1)
        #expect(sink.rowTally.skipped == 0)
    }

    @Test("Insert, Skip Existing inserts only the rows whose key is new")
    func skipExistingLeavesMatchedRowsAlone() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        let sink = sink(on: driver, mode: .insertSkippingExisting)

        try await sink.insertRows(Self.changedAndNew)

        #expect(try people(driver) == [["1", "a", "n1"], ["2", "b", "n2"], ["3", "c", "n3"], ["4", "d", "none"]])
        #expect(sink.rowTally.existing == 1)
        #expect(sink.rowTally.inserted == 1)
        #expect(sink.rowTally.updated == 0)
    }

    @Test("A key repeated in one batch updates the row its first occurrence inserted")
    func repeatedKeyInBatchSeesEarlierWrite() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        let sink = sink(on: driver, mode: .upsert)

        try await sink.insertRows([
            ["id": .text("5"), "name": .text("x")],
            ["id": .text("5"), "name": .text("y")],
        ])

        #expect(try driver.rows("SELECT name FROM people WHERE id = 5") == [["y"]])
        #expect(sink.rowTally.inserted == 1)
        #expect(sink.rowTally.updated == 1)
    }

    @Test("Keys the database takes as one still see each other's write within a batch")
    func equivalentKeysInBatchSeeEarlierWrite() async throws {
        let driver = try InMemorySQLiteDriver("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT NOT NULL DEFAULT 'none');
            CREATE TABLE codes (code TEXT NOT NULL UNIQUE COLLATE NOCASE, note TEXT);
            """)
        let upsert = sink(on: driver, mode: .upsert)
        try await upsert.insertRows([
            ["id": .text("7"), "name": .text("x")],
            ["id": .text("07"), "name": .text("y")],
        ])
        #expect(try driver.rows("SELECT id, name FROM people") == [["7", "y"]])

        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .sqlite), pluginDriver: driver)
        let skip = ImportDataSinkAdapter(
            driver: adapter,
            databaseType: .sqlite,
            targetTable: "codes",
            columnMapping: ["code": "code", "note": "note"],
            sourceFields: ["code", "note"],
            rowWriting: ImportRowWriting(mode: .insertSkippingExisting, keyColumns: ["code"])
        )
        try await skip.insertRows([
            ["code": .text("a"), "note": .text("first")],
            ["code": .text("A"), "note": .text("second")],
        ])
        #expect(try driver.rows("SELECT code, note FROM codes") == [["a", "first"]])
        #expect(skip.rowTally.inserted == 1)
        #expect(skip.rowTally.existing == 1)
    }

    @Test("A new row is written before a later update that refers to it")
    func writesKeepFileOrder() async throws {
        let driver = try InMemorySQLiteDriver("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT REFERENCES people(id));
            INSERT INTO people VALUES (1, 'a', NULL), (2, 'b', 1);
            """)
        let sink = sink(on: driver, mode: .upsert, mapping: ["id": "id", "name": "name", "note": "note"])

        try await sink.insertRows([
            ["id": .text("4"), "name": .text("d")],
            ["id": .text("2"), "note": .text("4")],
        ])

        #expect(try people(driver) == [["1", "a", nil], ["2", "b", "4"], ["4", "d", nil]])
    }

    @Test("Key folding joins the spellings a collation or a number comparison treats as equal")
    func keyFolding() {
        func folded(_ text: String) -> String { ImportDataSinkAdapter.foldedKeyValue(.text(text)) }
        #expect(folded("01") == folded("1"))
        #expect(folded("1.0") == folded("1"))
        #expect(folded("0.1") == folded("0.100000000000000001"))
        #expect(folded("-0") == folded("0"))
        #expect(folded(" A ") == folded("a"))
        #expect(folded("é") == folded("e"))
        #expect(folded("１") == folded("1"))
        #expect(folded("12abc") != folded("12"))
        #expect(folded("a") != folded("b"))
    }

    @Test("Matches across several probe statements land on the right rows")
    func manyKeysSpanSeveralProbes() async throws {
        let driver = try InMemorySQLiteDriver("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT NOT NULL DEFAULT 'none');
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 2 FROM n WHERE i < 249)
            INSERT INTO people (id, name) SELECT i, 'old' FROM n;
            """)
        let sink = sink(on: driver, mode: .upsert)

        try await sink.insertRows((1...250).map { ["id": .text(String($0)), "name": .text("new")] })

        #expect(try driver.rows("SELECT COUNT(*), SUM(name = 'new') FROM people") == [["250", "250"]])
        #expect(sink.rowTally.updated == 125)
        #expect(sink.rowTally.inserted == 125)
    }

    @Test("A key that matches more than one row is refused and nothing is written")
    func ambiguousKeyIsRefused() async throws {
        let driver = try InMemorySQLiteDriver("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT NOT NULL DEFAULT 'none');
            INSERT INTO people VALUES (1, 'dup', 'n1'), (2, 'dup', 'n2');
            """)
        let sink = sink(on: driver, mode: .update, key: ["name"], mapping: ["name": "name", "note": "note"])

        await #expect(throws: PluginImportError.self) {
            try await sink.insertRow(["name": .text("dup"), "note": .text("changed")])
        }
        #expect(try driver.rows("SELECT note FROM people ORDER BY id") == [["n1"], ["n2"]])
        #expect(sink.rowTally == ImportRowTally(mode: .update))
    }

    @Test("A row with no value for the key is refused")
    func rowWithoutKeyIsRefused() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        let sink = sink(on: driver, mode: .update)

        await #expect(throws: PluginImportError.self) {
            try await sink.insertRow(["name": .text("nobody")])
        }
    }

    @Test("A matching mode refuses to empty the table first")
    func matchingModeRefusesClearing() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        let sink = sink(on: driver, mode: .upsert)

        await #expect(throws: PluginImportError.self) {
            try await sink.deleteAllRowsFromTargetTable()
        }
        #expect(try people(driver).count == 3)
    }

    @Test("Insert counts the rows it wrote")
    func insertTalliesRows() async throws {
        let driver = try InMemorySQLiteDriver(Self.people)
        let sink = sink(on: driver, mode: .insert)

        try await sink.insertRows([["id": .text("7"), "name": .text("g")], ["id": .text("8"), "name": .text("h")]])
        try await sink.insertRow(["id": .text("9"), "name": .text("i")])

        #expect(sink.rowTally.inserted == 3)
        #expect(try people(driver).count == 6)
    }

    @Test("Skip and Continue records an ambiguous key against its line and writes the other rows")
    func skipAndContinueRecordsAmbiguousKey() async throws {
        let driver = try InMemorySQLiteDriver("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT NOT NULL DEFAULT 'none');
            INSERT INTO people VALUES (1, 'dup', 'n1'), (2, 'dup', 'n2'), (3, 'solo', 'n3');
            """)
        let sink = sink(on: driver, mode: .upsert, key: ["name"], mapping: ["name": "name", "note": "note"])
        var batches: [[RowImportRunner.Entry]] = [[
            (line: 2, row: ["name": .text("dup"), "note": .text("x")]),
            (line: 3, row: ["name": .text("solo"), "note": .text("updated")]),
            (line: 4, row: ["name": .text("fresh"), "note": .text("added")]),
        ]]

        let outcome = try await RowImportRunner.run(
            configuration: .init(errorHandling: .skipAndContinue, wrapInTransaction: false, deleteExistingRows: false),
            sink: sink,
            progress: PluginImportProgress(progress: Progress(totalUnitCount: 3))
        ) {
            batches.isEmpty ? nil : batches.removeFirst()
        }

        #expect(outcome.skipped == 1)
        #expect(outcome.errors.map { $0.line } == [2])
        #expect(try driver.rows("SELECT name, note FROM people ORDER BY id") == [
            ["dup", "n1"], ["dup", "n2"], ["solo", "updated"], ["fresh", "added"],
        ])
        #expect(sink.rowTally.updated == 1)
        #expect(sink.rowTally.inserted == 1)
    }
}
