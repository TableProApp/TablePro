import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProTestSupport
import Testing

struct SQLiteTransferEngineTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func driver(_ name: String) async throws -> SQLiteBackedDriver {
        let driver = SQLiteBackedDriver(source: .file(directory.appendingPathComponent(name)), openMode: .createNew)
        try await driver.connect()
        return driver
    }

    @Test("Export rows keep a blob's bytes, a NUL inside text and a NULL, with every row and the declared types")
    func exportRowsKeepValues() async throws {
        let driver = try await driver("rows.db")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER, body TEXT, data BLOB)")
        _ = try await driver.executeParameterized(
            query: "INSERT INTO t VALUES (?, ?, ?)",
            parameters: [.text("1"), .text("a\0b"), .bytes(Data([0x00, 0xFF, 0x10]))],
            typeNames: nil
        )
        _ = try await driver.executeParameterized(
            query: "INSERT INTO t VALUES (?, ?, ?)", parameters: [.text("2"), .null, .bytes(Data())], typeNames: nil
        )
        _ = try await driver.execute(query: """
            WITH RECURSIVE n(x) AS (SELECT 3 UNION ALL SELECT x + 1 FROM n WHERE x < 1203)
            INSERT INTO t SELECT x, 'x', NULL FROM n
            """)

        let (header, rows) = try await collect(driver.exportRows(query: "SELECT * FROM t ORDER BY id", readOnly: false))
        try await driver.disconnect()

        #expect(header?.columns == ["id", "body", "data"])
        #expect(header?.columnTypeNames == ["INTEGER", "TEXT", "BLOB"])
        #expect(rows.count == 1_203)
        #expect(rows[0] == [.text("1"), .text("a\0b"), .bytes(Data([0x00, 0xFF, 0x10]))])
        #expect(rows[1] == [.text("2"), .null, .bytes(Data())])
    }

    @Test("A NUL inside text reaches the SQL dump as char(0), so the value restores whole")
    func dumpLiteralKeepsNul() async throws {
        let driver = try await driver("nul.db")
        let body = try await driver.makeExportCatalog(
            context: MobileTransferContext(databaseType: .sqlite, database: nil, schema: nil)
        ).escapeStringLiteral("a\0b'c")

        let restored = try await driver.execute(query: "SELECT hex('\(body)')").rows.first?.first
        try await driver.disconnect()

        #expect(body == "a'||char(0)||'b''c")
        #expect(restored == "6100622763")
    }

    // SQLite refuses to drop a table a statement still reads (SQLITE_LOCKED), so the drop lands once the read is gone.
    @Test("A reader that stops early finalizes its statement when it lets go")
    func earlyStopFinalizes() async throws {
        let driver = try await driver("stop.db")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        _ = try await driver.execute(query: """
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 2000) INSERT INTO t SELECT x FROM n
            """)
        try await readTwoElements(of: driver.exportRows(query: "SELECT id FROM t", readOnly: false))

        try await waitUntil { (try? await driver.execute(query: "DROP TABLE t")) != nil }
        try await driver.disconnect()
    }

    @Test("An export reading the session lets other statements run between its batches and reads every row")
    func sessionExportInterleaves() async throws {
        let driver = try await driver("interleave.db")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        _ = try await driver.execute(query: """
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1500) INSERT INTO t SELECT x FROM n
            """)
        try await driver.beginTransaction()
        let transfer = try await driver.openTransferDriver()
        #expect(transfer === driver)

        var iterator = driver.exportRows(query: "SELECT id FROM t ORDER BY id", readOnly: false).makeAsyncIterator()
        var rows = 0
        var besideIt: [[String?]] = []
        while let element = try await iterator.next() {
            guard case .rows(let batch) = element else { continue }
            rows += batch.count
            besideIt += try await driver.execute(query: "SELECT count(*) FROM t").rows
        }
        try await driver.rollbackTransaction()
        try await driver.disconnect()

        #expect(rows == 1_500)
        #expect(besideIt.count >= 3)
        #expect(besideIt.allSatisfy { $0 == ["1500"] })
    }

    private func readTwoElements(of stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws {
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await iterator.next()
    }

    @Test("A bound value count that does not match the statement is refused")
    func refusesMismatchedValues() async throws {
        let driver = try await driver("binds.db")
        _ = try await driver.execute(query: "CREATE TABLE t (a TEXT, b TEXT)")

        await #expect(throws: SQLitePluginError.self) {
            _ = try await driver.executeParameterized(
                query: "INSERT INTO t VALUES (?, ?)", parameters: [.text("only one")], typeNames: nil
            )
        }
        try await driver.disconnect()
    }

    @Test("The catalog lists tables, views and triggers, and reads each one's definition")
    func catalogListsEveryKind() async throws {
        let driver = try await driver("catalog.db")
        _ = try await driver.execute(query: "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await driver.execute(query: "CREATE VIEW names AS SELECT name FROM parent")
        _ = try await driver.execute(query: """
            CREATE TRIGGER stamp AFTER INSERT ON parent BEGIN UPDATE parent SET name = name WHERE id = NEW.id; END
            """)
        let catalog = try await driver.makeExportCatalog(
            context: MobileTransferContext(databaseType: .sqlite, database: nil, schema: nil)
        )

        let objects = try await catalog.exportObjects(database: "", schema: nil)
        let trigger = try #require(objects.first { $0.kind == .trigger })
        let triggerDDL = try await catalog.fetchObjectDDL(trigger)
        let viewDDL = try await catalog.fetchObjectDDL(try #require(objects.first { $0.kind == .view }))
        try await driver.disconnect()
        let names = objects.map { $0.name }
        let kinds = objects.map { $0.kind }

        #expect(names == ["names", "parent", "stamp"])
        #expect(kinds == [.view, .table, .trigger])
        #expect(trigger.parentTable == "parent")
        #expect(triggerDDL.hasPrefix("CREATE TRIGGER stamp"))
        #expect(viewDDL.hasPrefix("CREATE VIEW names"))
        #expect(catalog.dropStatement(for: trigger) == "DROP TRIGGER IF EXISTS `stamp`")
    }

    @Test("The CREATE TABLE writer's statement runs, and the import statements quote and bind for SQLite")
    func writeDialect() async throws {
        let driver = try await driver("write.db")
        let dialect = try await driver.makeWriteDialect(
            context: MobileTransferContext(databaseType: .sqlite, database: nil, schema: nil)
        )
        let definition = PluginCreateTableDefinition(
            tableName: "new table",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "note", dataType: "TEXT"),
            ],
            primaryKeyColumns: ["id"]
        )
        for statement in try dialect.createTableStatements(definition: definition, schema: nil) {
            _ = try await driver.execute(query: statement)
        }
        let statements = try await dialect.importStatements(
            table: "new table", schema: nil, columns: [ColumnInfo(name: "id", typeName: "INTEGER")]
        )
        let insert = try #require(statements.insertStatement(columns: ["id", "note"], values: [.text("7"), .text("x")]))
        _ = try await driver.executeParameterized(query: insert.sql, parameters: insert.parameters, typeNames: nil)
        let stored = try await driver.execute(query: "SELECT id, note FROM \"new table\"").rows
        try await driver.disconnect()

        #expect(insert.sql == "INSERT INTO `new table` (`id`, `note`) VALUES (?, ?)")
        #expect(stored == [["7", "x"]])
    }

    @Test("Foreign key checks turn off and back on with PRAGMA foreign_keys")
    func foreignKeyStatements() async throws {
        let driver = SQLiteBackedDriver(source: .inMemory)
        #expect(driver.foreignKeyCheckStatements(enabled: false) == ["PRAGMA foreign_keys = OFF"])
        #expect(driver.foreignKeyCheckStatements(enabled: true) == ["PRAGMA foreign_keys = ON"])
    }

    @Test("A WAL file gets a second, read-only reader that sees committed rows and refuses writes")
    func walGetsASecondReader() async throws {
        let driver = try await driver("wal.db")
        _ = try await driver.execute(query: "PRAGMA journal_mode = WAL")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO t VALUES (1)")

        let reader = try await driver.openTransferDriver()
        let count = try await reader.execute(query: "SELECT count(*) FROM t").rows.first?.first ?? nil
        await #expect(throws: SQLitePluginError.self) { _ = try await reader.execute(query: "INSERT INTO t VALUES (2)") }
        try await reader.disconnect()
        try await driver.disconnect()

        #expect(reader !== driver)
        #expect(count == "1")
    }

    @Test("A rollback-journal file is read from a snapshot, removed when the transfer ends")
    func rollbackJournalReadsASnapshot() async throws {
        let driver = try await driver("journal.db")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO t VALUES (1)")

        let snapshot = try await driver.openTransferDriver()
        _ = try await driver.execute(query: "INSERT INTO t VALUES (2)")
        let count = try await snapshot.execute(query: "SELECT count(*) FROM t").rows.first?.first ?? nil
        let leftBefore = try FileManager.default.contentsOfDirectory(atPath: SQLiteBackedDriver.snapshotDirectory.path)
        try await snapshot.disconnect()
        let leftAfter = (try? FileManager.default.contentsOfDirectory(atPath: SQLiteBackedDriver.snapshotDirectory.path)) ?? []
        try await driver.disconnect()

        #expect(snapshot !== driver)
        #expect(count == "1")
        #expect(leftAfter.count == leftBefore.count - 1)
    }

    @Test("With the user's transaction open the transfer reads the session inside it")
    func openTransactionReadsTheSession() async throws {
        let driver = try await driver("busy.db")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        try await driver.beginTransaction()

        let transfer = try await driver.openTransferDriver()
        try await driver.rollbackTransaction()
        try await driver.disconnect()

        #expect(transfer === driver)
    }

    @Test("An in-memory database is read on its session")
    func inMemoryReadsTheSession() async throws {
        let driver = SQLiteBackedDriver(source: .inMemory)
        try await driver.connect()

        let transfer = try await driver.openTransferDriver()
        try await driver.disconnect()

        #expect(transfer === driver)
    }

    private func collect(
        _ stream: AsyncThrowingStream<PluginStreamElement, Error>
    ) async throws -> (header: PluginStreamHeader?, rows: [[PluginCellValue]]) {
        var header: PluginStreamHeader?
        var rows: [[PluginCellValue]] = []
        for try await element in stream {
            switch element {
            case .header(let value): header = value
            case .rows(let batch): rows += batch
            }
        }
        return (header, rows)
    }
}
