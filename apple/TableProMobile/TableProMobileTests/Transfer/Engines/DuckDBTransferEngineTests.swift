import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct DuckDBTransferEngineTests {
    private func session() async throws -> DuckDBDriver {
        let driver = DuckDBDriver(source: .inMemory)
        try await driver.connect()
        return driver
    }

    private static let context = MobileTransferContext(databaseType: .duckdb, database: nil, schema: nil)

    @Test("Bound text, bytes and NULL land as written, and export rows read the blob back as its bytes")
    func bindsAndExportsBytes() async throws {
        let driver = try await session()
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER, body VARCHAR, data BLOB)")
        _ = try await driver.executeParameterized(
            query: "INSERT INTO t VALUES ($1, $2, $3)",
            parameters: [.text("1"), .text("it's \\ here"), .bytes(Data([0x00, 0xFF, 0x7F]))],
            typeNames: nil
        )
        _ = try await driver.executeParameterized(
            query: "INSERT INTO t VALUES ($1, $2, $3)", parameters: [.text("2"), .null, .bytes(Data())], typeNames: nil
        )
        _ = try await driver.execute(query: "INSERT INTO t SELECT i, 'x', NULL FROM range(3, 5003) AS r(i)")

        var header: PluginStreamHeader?
        var rows: [[PluginCellValue]] = []
        for try await element in driver.exportRows(query: "SELECT * FROM t ORDER BY id", readOnly: false) {
            switch element {
            case .header(let value): header = value
            case .rows(let batch): rows += batch
            }
        }
        try await driver.disconnect()

        #expect(header?.columns == ["id", "body", "data"])
        #expect(header?.columnTypeNames == ["INTEGER", "VARCHAR", "BLOB"])
        #expect(rows.count == 5_002)
        #expect(rows[0] == [.text("1"), .text("it's \\ here"), .bytes(Data([0x00, 0xFF, 0x7F]))])
        #expect(rows[1] == [.text("2"), .null, .bytes(Data())])
    }

    @Test("A catalog read binds its values and keeps bytes")
    func catalogQueryBinds() async throws {
        let driver = try await session()

        let result = try await driver.catalogQuery("SELECT $1 AS a, $2::BLOB AS b", parameters: [.text("x"), .bytes(Data([1, 2]))])
        try await driver.disconnect()

        #expect(result.rows == [[.text("x"), .bytes(Data([1, 2]))]])
    }

    @Test("The catalog lists tables, views and both macro kinds, and drops a table macro as one")
    func catalogListsMacros() async throws {
        let driver = try await session()
        _ = try await driver.execute(query: "CREATE TABLE facts (id INTEGER PRIMARY KEY, label VARCHAR)")
        _ = try await driver.execute(query: "CREATE VIEW labels AS SELECT label FROM facts")
        _ = try await driver.execute(query: "CREATE MACRO plus_one(x) AS x + 1")
        _ = try await driver.execute(query: "CREATE MACRO rows_of(n) AS TABLE SELECT * FROM range(n)")
        let catalog = try await driver.makeExportCatalog(context: Self.context)

        let objects = try await catalog.exportObjects(database: "", schema: nil)
        let scalar = try #require(objects.first { $0.name == "plus_one" })
        let table = try #require(objects.first { $0.name == "rows_of" })
        let scalarDDL = try await catalog.fetchObjectDDL(scalar)
        try await driver.disconnect()
        let relations = objects.filter { $0.kind != .routine }.map { "\($0.kind.rawValue) \($0.name)" }

        #expect(relations.sorted() == ["table facts", "view labels"])
        #expect(scalar.identity == "(x)")
        #expect(table.identity == "(n) AS TABLE")
        #expect(scalar.tableType == PluginRoutineKind.function.rawValue)
        #expect(scalarDDL.hasPrefix("CREATE OR REPLACE MACRO"))
        #expect(catalog.dropStatement(for: scalar) == "DROP MACRO IF EXISTS \"main\".\"plus_one\"")
        #expect(catalog.dropStatement(for: table) == "DROP MACRO TABLE IF EXISTS \"main\".\"rows_of\"")
    }

    @Test("The CREATE TABLE writer's statements run, and import statements bind with $n in the schema")
    func writeDialect() async throws {
        let driver = try await session()
        let dialect = try await driver.makeWriteDialect(context: Self.context)
        let definition = PluginCreateTableDefinition(
            tableName: "made",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "note", dataType: "VARCHAR"),
            ],
            primaryKeyColumns: ["id"]
        )
        for statement in try dialect.createTableStatements(definition: definition, schema: nil) {
            _ = try await driver.execute(query: statement)
        }
        let statements = try await dialect.importStatements(table: "made", schema: "main", columns: [])
        let insert = try #require(statements.insertStatement(columns: ["id", "note"], values: [.text("7"), .null]))
        _ = try await driver.executeParameterized(query: insert.sql, parameters: insert.parameters, typeNames: nil)
        let stored = try await driver.execute(query: "SELECT id, note FROM main.made").rows
        try await driver.disconnect()

        #expect(insert.sql == "INSERT INTO \"main\".\"made\" (\"id\", \"note\") VALUES ($1, $2)")
        #expect(stored == [["7", nil]])
    }

    @Test("A transfer connection reads its own snapshot while the session writes, and the session's close ends it")
    func transferConnectionLivesInsideTheSession() async throws {
        let driver = try await session()
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO t VALUES (1)")

        let transfer = try await driver.openTransferDriver()
        try await transfer.beginTransaction()
        let before = try await transfer.execute(query: "SELECT count(*) FROM t").rows.first?.first ?? nil
        _ = try await driver.execute(query: "INSERT INTO t VALUES (2)")
        let during = try await transfer.execute(query: "SELECT count(*) FROM t").rows.first?.first ?? nil
        try await driver.disconnect()

        #expect(transfer !== driver)
        #expect(!transfer.holdsSuspensionBlockingResource)
        #expect(before == "1")
        #expect(during == "1")
        await #expect(throws: DuckDBDriverError.self) { _ = try await transfer.ping() }
    }

    @Test("A grid statement on the session does not end a read the session streams for an export")
    func sessionExportSurvivesGridStatements() async throws {
        let driver = try await session()
        _ = try await driver.execute(query: "CREATE TABLE t AS SELECT i FROM range(0, 10000) AS r(i)")

        var iterator = driver.exportRows(query: "SELECT i FROM t ORDER BY i", readOnly: false).makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await driver.execute(query: "SELECT 1")
        var count = 0
        while let element = try await iterator.next() {
            if case .rows(let batch) = element { count += batch.count }
        }
        try await driver.disconnect()

        #expect(count == 10_000)
    }
}
