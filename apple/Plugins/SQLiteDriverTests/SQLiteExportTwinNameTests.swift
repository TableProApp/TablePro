import Foundation
import TableProPluginKit
import Testing

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"

private actor SentStatements {
    private(set) var all: [String] = []

    func note(_ statement: String) {
        all.append(statement)
    }
}

// SQLite folds only ASCII case in a name, so it keeps two tables whose names differ only in Unicode form apart.
struct SQLiteExportTwinNameTests {
    private func withDriver(
        _ statements: [String],
        _ body: (SQLitePluginDriver) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-twins-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        for statement in statements {
            _ = try await driver.execute(query: statement)
        }
        try await body(driver)
    }

    private static let twins = [
        "CREATE TABLE p (id INTEGER PRIMARY KEY)",
        "CREATE TABLE \"\(composed)\" (id INTEGER PRIMARY KEY, b INTEGER GENERATED ALWAYS AS (id * 2) VIRTUAL, r INTEGER REFERENCES p (id))",
        "CREATE TABLE \"\(decomposed)\" (id INTEGER PRIMARY KEY, b INTEGER, s INTEGER REFERENCES p (id))",
    ]

    @Test("The export's column and key reads throw on two tables named alike in different Unicode forms")
    func exportReadsThrowOnTwins() async throws {
        try await withDriver(Self.twins) { driver in
            await #expect(throws: PluginNameSpellingError.self) {
                try await driver.fetchAllColumnsForExport(schema: nil)
            }
            await #expect(throws: PluginNameSpellingError.self) {
                try await driver.fetchAllForeignKeysForExport(schema: nil)
            }
        }
    }

    @Test("Each twin's own read gives only its own columns and keys")
    func ownReadsKeepTwinsApart() async throws {
        try await withDriver(Self.twins) { driver in
            let columns = try await driver.fetchColumns(table: decomposed, schema: nil)
            #expect(columns.map { $0.name } == ["id", "b", "s"])
            #expect(columns.allSatisfy { !$0.isGenerated })
            let keys = try await driver.fetchForeignKeys(table: decomposed, schema: nil)
            #expect(keys.map { $0.column } == ["s"])
        }
    }

    @Test("Without twins the export reads answer as the shared reads do")
    func exportReadsMatchTheSharedReads() async throws {
        try await withDriver([
            "CREATE TABLE p (id INTEGER PRIMARY KEY)",
            "CREATE TABLE c (id INTEGER PRIMARY KEY, g INTEGER GENERATED ALWAYS AS (id + 1) STORED, r INTEGER REFERENCES p (id))",
        ]) { driver in
            let exported = try await driver.fetchAllColumnsForExport(schema: nil)
            let shared = try await driver.fetchAllColumns(schema: nil)
            #expect(exported.keys.sorted() == ["c", "p"])
            let names: ([PluginColumnInfo]) -> [String] = { columns in columns.map { $0.name } }
            #expect(exported.mapValues(names) == shared.mapValues(names))
            #expect(exported["c"]?.map { $0.isGenerated } == [false, true, false])
            let keys = try await driver.fetchAllForeignKeysForExport(schema: nil)
            #expect(keys["c"]?.map { $0.referencedTable } == ["p"])
        }
    }

    @Test("The export reads send the shared reads' one statement each")
    func exportReadsAreOneStatementEach() async throws {
        let sent = SentStatements()
        let run: SQLiteCatalogReads.Run = { statement in
            await sent.note(statement)
            return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
        }
        _ = try await SQLiteCatalogReads.allColumns(schema: nil, keepsSpellingsApart: true, run: run)
        _ = try await SQLiteCatalogReads.allForeignKeys(schema: nil, keepsSpellingsApart: true, run: run)
        _ = try await SQLiteCatalogReads.allColumns(schema: nil, run: run)
        _ = try await SQLiteCatalogReads.allForeignKeys(schema: nil, run: run)

        let statements = await sent.all
        #expect(statements.count == 4)
        #expect(statements[0] == statements[2])
        #expect(statements[1] == statements[3])
    }
}
