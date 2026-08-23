import Foundation
import TableProPluginKit
import XCTest

final class DamengPluginDriverTests: XCTestCase {
    func testTypingSuggestionsIncludeDM8StatementsAndDialectSymbols() {
        let completions = Set(DamengPlugin.statementCompletions.map(\.label))

        XCTAssertTrue(completions.isSuperset(of: ["SET SCHEMA", "CREATE SCHEMA", "EXPLAIN", "CONNECT BY"]))
        XCTAssertTrue(DamengPlugin.sqlDialect?.keywords.contains("ROWNUM") == true)
        XCTAssertTrue(DamengPlugin.sqlDialect?.functions.contains("NVL") == true)
        XCTAssertTrue(DamengPlugin.sqlDialect?.dataTypes.contains("VARCHAR2") == true)

        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        XCTAssertEqual(driver.buildExplainQuery("SELECT 1"), "EXPLAIN SELECT 1")
    }

    func testDDLGenerationQuotesNamesAndPreservesConstraints() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let definition = PluginCreateTableDefinition(
            tableName: "order",
            columns: [
                PluginColumnDefinition(
                    name: "id",
                    dataType: "int",
                    isNullable: false,
                    isPrimaryKey: true,
                    autoIncrement: true
                ),
                PluginColumnDefinition(
                    name: "display name",
                    dataType: "varchar(100)",
                    defaultValue: "guest's record",
                    comment: "customer's label"
                )
            ],
            indexes: [PluginIndexDefinition(name: "idx display", columns: ["display name"])],
            foreignKeys: []
        )

        let sql = try XCTUnwrap(driver.generateCreateTableSQL(definition: definition))

        XCTAssertTrue(sql.hasPrefix("CREATE TABLE \"APP\".\"order\""))
        XCTAssertTrue(sql.contains("\"id\" INT IDENTITY(1,1) NOT NULL PRIMARY KEY"))
        XCTAssertTrue(sql.contains("CREATE INDEX \"idx display\" ON \"APP\".\"order\" (\"display name\")"))
        XCTAssertFalse(sql.contains("EXECUTE IMMEDIATE"))
        XCTAssertTrue(sql.contains("DEFAULT 'guest''s record'"))
        XCTAssertTrue(sql.contains("IS 'customer''s label'"))
    }

    func testDDLGenerationDoesNotNestStatementsInAStringLiteral() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let definition = PluginCreateTableDefinition(
            tableName: "note",
            columns: [
                PluginColumnDefinition(
                    name: "body",
                    dataType: "varchar(100)",
                    comment: "a quote carrying a combining mark: '\u{0301} end"
                )
            ],
            indexes: [],
            foreignKeys: []
        )

        let sql = try XCTUnwrap(driver.generateCreateTableSQL(definition: definition))

        // Re-encoding statements as a PL/SQL literal doubled every quote a second time and
        // relied on grapheme-cluster matching, which leaves a decorated quote undoubled.
        XCTAssertFalse(sql.contains("BEGIN\n"))
        XCTAssertFalse(sql.contains("EXECUTE IMMEDIATE"))
        XCTAssertTrue(sql.contains("''\u{0301}"))
    }

    func testRowChangesUsePrimaryKeyAndBoundValues() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let change = PluginRowChange(
            rowIndex: 2,
            type: .update,
            cellChanges: [(1, "name", .text("old"), .text("new"))],
            originalRow: [.text("42"), .text("old")]
        )

        let statements = try XCTUnwrap(driver.generateStatements(
            table: "users",
            schema: "APP",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        ))

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(
            statements[0].statement,
            "UPDATE \"APP\".\"users\" SET \"name\" = ? WHERE \"id\" = ? AND ROWNUM = 1"
        )
        XCTAssertEqual(statements[0].parameters, [.text("new"), .text("42")])
    }

    func testDeletesBindTheWholePrimaryKey() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let change = PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: [.text("42"), .text("old")]
        )

        let statements = try XCTUnwrap(driver.generateStatements(
            table: "users",
            schema: "APP",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        ))

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(
            statements[0].statement,
            "DELETE FROM \"APP\".\"users\" WHERE \"id\" = ? AND ROWNUM = 1"
        )
        XCTAssertEqual(statements[0].parameters, [.text("42")])
    }

    func testCompositePrimaryKeyConstrainsEveryKeyColumn() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(2, "total", .text("1"), .text("2"))],
            originalRow: [.text("7"), .text("EU"), .text("1")]
        )

        let statements = try XCTUnwrap(driver.generateStatements(
            table: "orders",
            schema: "APP",
            columns: ["id", "region", "total"],
            primaryKeyColumns: ["id", "region"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        ))

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].statement.contains("\"id\" = ?"))
        XCTAssertTrue(statements[0].statement.contains("\"region\" = ?"))
        XCTAssertEqual(statements[0].parameters, [.text("2"), .text("7"), .text("EU")])
    }

    func testBinaryValuesAreBoundRatherThanInlined() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let payload = Data([0x00, 0xFF, 0x10])
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "blob", .null, .bytes(payload))],
            originalRow: [.text("1"), .null]
        )

        let statements = try XCTUnwrap(driver.generateStatements(
            table: "files",
            schema: "APP",
            columns: ["id", "blob"],
            primaryKeyColumns: ["id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        ))

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].statement.contains("\"blob\" = ?"))
        XCTAssertFalse(statements[0].statement.contains("HEXTORAW"))
        XCTAssertEqual(statements[0].parameters.first, .bytes(payload))
    }

    func testWithoutAPrimaryKeyEveryColumnConstrainsTheRow() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "name", .text("old"), .text("new"))],
            originalRow: [.text("42"), .text("old")]
        )

        let statements = try XCTUnwrap(driver.generateStatements(
            table: "users",
            schema: "APP",
            columns: ["id", "name"],
            primaryKeyColumns: [],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        ))

        XCTAssertEqual(
            statements[0].statement,
            "UPDATE \"APP\".\"users\" SET \"name\" = ? WHERE \"id\" = ? AND \"name\" = ? AND ROWNUM = 1"
        )
        XCTAssertEqual(statements[0].parameters, [.text("new"), .text("42"), .text("old")])
    }

    func testAnUnresolvableKeyColumnProducesNoStatement() throws {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(1, "name", .text("old"), .text("new"))],
            originalRow: [.text("42"), .text("old")]
        )

        // "tenant_id" is a declared key the grid is not showing. Skipping it would leave
        // "id" alone in the predicate, and ROWNUM = 1 would pick an arbitrary matching row.
        let statements = driver.generateStatements(
            table: "users",
            schema: "APP",
            columns: ["id", "name"],
            primaryKeyColumns: ["id", "tenant_id"],
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        XCTAssertNil(statements)
    }

    func testDropObjectStatementKeepsDM8ObjectKeywords() {
        let driver = DamengPluginDriver(config: testConfig(database: "APP"))

        XCTAssertEqual(
            driver.dropObjectStatement(
                name: "SALES_MV", objectType: "MATERIALIZED VIEW", schema: "APP", cascade: false
            ),
            "DROP MATERIALIZED VIEW \"APP\".\"SALES_MV\""
        )
        XCTAssertEqual(
            driver.dropObjectStatement(name: "ACTIVE_USERS", objectType: "view", schema: "APP", cascade: true),
            "DROP VIEW \"APP\".\"ACTIVE_USERS\""
        )
        XCTAssertEqual(
            driver.dropObjectStatement(name: "EXT_LOG", objectType: "FOREIGN TABLE", schema: "APP", cascade: false),
            "DROP TABLE \"APP\".\"EXT_LOG\""
        )
        XCTAssertEqual(
            driver.dropObjectStatement(name: "ORDERS", objectType: "TABLE", schema: "APP", cascade: true),
            "DROP TABLE \"APP\".\"ORDERS\" CASCADE"
        )
    }

    func testRowCapClampsToTheEmergencyMaximum() {
        XCTAssertEqual(DamengConnection.fetchLimit(nil), PluginRowLimits.emergencyMax)
        XCTAssertEqual(DamengConnection.fetchLimit(0), PluginRowLimits.emergencyMax)
        XCTAssertEqual(DamengConnection.fetchLimit(-5), PluginRowLimits.emergencyMax)
        XCTAssertEqual(DamengConnection.fetchLimit(10), 10)
        XCTAssertEqual(DamengConnection.fetchLimit(9_000_000), PluginRowLimits.emergencyMax)
    }

    func testCastTruncationIsDetectedAtTheDM8VarcharCeiling() {
        let full = String(repeating: "a", count: 8_188)

        XCTAssertFalse(DamengSchemaValue.isCastTruncated(full, storedLength: 8_188))
        XCTAssertTrue(DamengSchemaValue.isCastTruncated(full, storedLength: 8_189))

        XCTAssertFalse(DamengSchemaValue.isCastTruncated(String(repeating: "a", count: 8_187), storedLength: nil))
        XCTAssertTrue(DamengSchemaValue.isCastTruncated(full, storedLength: nil))
        XCTAssertTrue(DamengSchemaValue.isCastTruncated(String(repeating: "\u{e9}", count: 4_094), storedLength: nil))
    }

    func testEffectiveSchemaPreservesQuotedIdentifierCase() {
        let configured = DamengPluginDriver(config: testConfig(database: "CamelCaseSchema"))
        XCTAssertEqual(configured.effectiveSchema(nil), "CamelCaseSchema")
        XCTAssertEqual(configured.effectiveSchema("lowercase_schema"), "lowercase_schema")

        let fallback = DamengPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1",
            port: 5_236,
            username: "sysdba",
            password: "test-only",
            database: ""
        ))
        XCTAssertEqual(fallback.effectiveSchema(nil), "SYSDBA")
    }

    func testLiveDM8Workflow() async throws {
        let environment = try liveEnvironment()
        let driver = DamengPluginDriver(config: environment.config(database: "SYSDBA"))
        let schema = "TP_\(UUID().uuidString.prefix(12).replacingOccurrences(of: "-", with: ""))".uppercased()
        try await checked("connect") {
            try await driver.connect()
        }
        defer { driver.disconnect() }

        _ = try await checked("create schema") {
            try await driver.execute(query: "CREATE SCHEMA \(driver.quoteIdentifier(schema)) AUTHORIZATION SYSDBA")
        }
        do {
            try await runLiveWorkflow(driver: driver, schema: schema)
            try await driver.switchSchema(to: "SYSDBA")
            try await driver.dropSchema(name: schema)
        } catch {
            try? await driver.switchSchema(to: "SYSDBA")
            _ = try? await driver.execute(query: "DROP SCHEMA \(driver.quoteIdentifier(schema)) CASCADE")
            throw error
        }
    }

    /// The regression test for #2262. Stopping a DM8 statement closes its connection, because
    /// DM8 has no out-of-band cancel, and every later statement used to fail forever with
    /// "The Dameng connection is closed": switching schema reported a failure and tables took a
    /// long time to open or never opened at all.
    ///
    /// The stopped statement generates its own rows from `DUAL` rather than reading a table, so
    /// it takes the same few seconds on any server and needs no fixture. It also ends on its
    /// own: DM8 keeps running an abandoned statement, so one chosen to run for hours would pin
    /// the server long after the test finished.
    func testLiveDM8RecoversFromAStoppedStatement() async throws {
        let environment = try liveEnvironment()
        let driver = DamengPluginDriver(config: environment.config(database: "SYSDBA"))
        try await checked("connect") { try await driver.connect() }
        defer { driver.disconnect() }

        let stopped = Task {
            try await driver.execute(
                query: """
                    SELECT COUNT(*) FROM
                        (SELECT LEVEL AS N FROM DUAL CONNECT BY LEVEL <= 6000) a,
                        (SELECT LEVEL AS N FROM DUAL CONNECT BY LEVEL <= 6000) b
                    WHERE TO_CHAR(a.N) || TO_CHAR(b.N) LIKE '%99999%'
                    """
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        try driver.cancelQuery()
        if case .success = await stopped.result {
            XCTFail("Expected the stopped statement to fail")
        }

        let recovered = try await checked("statement after the stop") {
            try await driver.execute(query: "SELECT 1 FROM DUAL")
        }
        XCTAssertEqual(recovered.rows.first?.first, .text("1"))
        XCTAssertEqual(driver.currentSchema, "SYSDBA")

        try await checked("switch schema after the stop") { try await driver.switchSchema(to: "SYSDBA") }
        try await checked("ping after the stop") { try await driver.ping() }
    }

    /// A rebuilt connection never saw the transaction's BEGIN, so replaying into it would let
    /// the later commit report success having written nothing. The loss is reported instead.
    ///
    /// A bare `SET SCHEMA` is the deterministic way to lose the connection: DM8 answers it with
    /// a truncated frame, which desyncs the stream and closes the connection every time. A stop
    /// would not do, because one that lands after the server already answered leaves the
    /// connection healthy and there would be nothing to report.
    func testLiveDM8ReportsATransactionLostWithItsConnection() async throws {
        let environment = try liveEnvironment()
        let driver = DamengPluginDriver(config: environment.config(database: "SYSDBA"))
        try await checked("connect") { try await driver.connect() }
        defer { driver.disconnect() }

        try await checked("begin") { try await driver.beginTransaction() }
        do {
            _ = try await driver.execute(query: "SET SCHEMA \"SYSDBA\"")
            XCTFail("Expected the statement to lose its connection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("transaction"), "\(error)")
        }
        XCTAssertFalse(driver.hasOpenTransaction)

        // Reporting it once ends the transaction, so the session recovers from there.
        let recovered = try await checked("statement after the lost transaction") {
            try await driver.execute(query: "SELECT 1 FROM DUAL")
        }
        XCTAssertEqual(recovered.rows.first?.first, .text("1"))
        XCTAssertEqual(driver.currentSchema, "SYSDBA")
    }

    /// Several statements finding the connection dead share one rebuild. Each starting its own
    /// would retire the connection the previous one had just adopted.
    func testLiveDM8SharesOneRebuildBetweenConcurrentStatements() async throws {
        let environment = try liveEnvironment()
        let driver = DamengPluginDriver(config: environment.config(database: "SYSDBA"))
        try await checked("connect") { try await driver.connect() }
        defer { driver.disconnect() }

        try driver.cancelQuery()

        try await withThrowingTaskGroup(of: PluginCellValue?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await driver.execute(query: "SELECT USER FROM DUAL").rows.first?.first
                }
            }
            for try await value in group {
                XCTAssertEqual(value, .text("SYSDBA"))
            }
        }
        XCTAssertEqual(driver.currentSchema, "SYSDBA")
    }

    /// DM8 answers a query with one inline batch and holds the rest on a cursor. The driver
    /// used to stop at that batch, so a 20000 row table came back as 662 rows while reporting
    /// itself complete, and the sidebar listed 1159 of 2000 tables.
    func testLiveDM8ReturnsEveryRowOfALargeResult() async throws {
        let environment = try liveEnvironment()
        let driver = DamengPluginDriver(config: environment.config(database: "SYSDBA"))
        try await checked("connect") { try await driver.connect() }
        defer { driver.disconnect() }

        let table = "TP_ROWS_\(UUID().uuidString.prefix(8))".uppercased()
        let quoted = driver.quoteIdentifier(table)
        _ = try await driver.execute(query: "CREATE TABLE \(quoted)(\"ID\" INT, \"PAD\" VARCHAR(40))")
        defer { Task { _ = try? await driver.execute(query: "DROP TABLE \(quoted)") } }
        _ = try await driver.execute(query: """
            INSERT INTO \(quoted)("ID", "PAD")
            SELECT LEVEL, 'padpadpadpadpadpadpadpadpad' FROM DUAL CONNECT BY LEVEL <= 5000
            """)
        _ = try await driver.execute(query: "COMMIT")

        let all = try await checked("read every row") {
            try await driver.execute(query: "SELECT \"ID\", \"PAD\" FROM \(quoted) ORDER BY \"ID\"")
        }
        XCTAssertEqual(all.rows.count, 5_000)
        XCTAssertEqual(all.columns.count, 2)
        XCTAssertFalse(all.isTruncated)
        XCTAssertEqual(all.rows.first?.first, .text("1"))
        XCTAssertEqual(all.rows.last?.first, .text("5000"))

        // A row cap still stops early, and says so.
        let capped = try await checked("read with a cap") {
            try await driver.executeUserQuery(
                query: "SELECT \"ID\" FROM \(quoted) ORDER BY \"ID\"", rowCap: 100, parameters: nil
            )
        }
        XCTAssertEqual(capped.rows.count, 100)
        XCTAssertTrue(capped.isTruncated)
    }

    /// A LOB column descriptor is longer than the others, and mis-measuring it shifted the
    /// column list and reparsed the remaining descriptors as rows.
    func testLiveDM8ReadsATableWithALobColumn() async throws {
        let environment = try liveEnvironment()
        let driver = DamengPluginDriver(config: environment.config(database: "SYSDBA"))
        try await checked("connect") { try await driver.connect() }
        defer { driver.disconnect() }

        let table = "TP_LOB_\(UUID().uuidString.prefix(8))".uppercased()
        let quoted = driver.quoteIdentifier(table)
        _ = try await driver.execute(query: """
            CREATE TABLE \(quoted)("ID" INT, "NOTE" CLOB, "NAME" VARCHAR(50), "BLOB_COL" BLOB)
            """)
        defer { Task { _ = try? await driver.execute(query: "DROP TABLE \(quoted)") } }
        _ = try await driver.execute(query: "INSERT INTO \(quoted)(\"ID\", \"NAME\") VALUES(1, 'one')")
        _ = try await driver.execute(query: "INSERT INTO \(quoted)(\"ID\", \"NAME\") VALUES(2, 'two')")
        _ = try await driver.execute(query: "COMMIT")

        let everyColumn = try await checked("select star") {
            try await driver.execute(query: "SELECT * FROM \(quoted) ORDER BY \"ID\"")
        }
        XCTAssertEqual(everyColumn.columns, ["ID", "NOTE", "NAME", "BLOB_COL"])
        XCTAssertEqual(everyColumn.rows.count, 2)

        let lobFirst = try await checked("lob as the first column") {
            try await driver.execute(query: "SELECT \"NOTE\", \"ID\" FROM \(quoted) ORDER BY \"ID\"")
        }
        XCTAssertEqual(lobFirst.columns.count, 2)
        XCTAssertEqual(lobFirst.rows.count, 2)
        XCTAssertEqual(lobFirst.rows.last?[1], .text("2"))
    }

    func testLiveDM8RejectsBadCredentialsAndInvalidPort() async throws {
        let environment = try liveEnvironment()
        let invalidPortDriver = DamengPluginDriver(config: DriverConnectionConfig(
            host: environment.host,
            port: 70_000,
            username: environment.username,
            password: environment.password,
            database: ""
        ))
        do {
            try await invalidPortDriver.connect()
            XCTFail("Expected an invalid port to fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("65535"))
        }

        let badPasswordDriver = DamengPluginDriver(config: DriverConnectionConfig(
            host: environment.host,
            port: environment.port,
            username: environment.username,
            password: "not-the-password",
            database: ""
        ))
        do {
            try await badPasswordDriver.connect()
            XCTFail("Expected invalid credentials to fail")
        } catch {
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    private func runLiveWorkflow(driver: DamengPluginDriver, schema: String) async throws {
        try await checked("switch schema") {
            try await driver.switchSchema(to: schema)
        }
        XCTAssertEqual(driver.currentSchema, schema)
        XCTAssertTrue(driver.serverVersion?.contains("DM Database Server") == true)
        try await checked("ping") {
            try await driver.ping()
        }

        let parentDefinition = PluginCreateTableDefinition(
            tableName: "PARENT",
            columns: [
                PluginColumnDefinition(
                    name: "ID",
                    dataType: "INT",
                    isNullable: false,
                    isPrimaryKey: true,
                    autoIncrement: true
                ),
                PluginColumnDefinition(
                    name: "NAME",
                    dataType: "VARCHAR(100)",
                    isNullable: false,
                    comment: "the parent name"
                ),
                PluginColumnDefinition(name: "PAYLOAD", dataType: "VARBINARY(8188)")
            ],
            indexes: [PluginIndexDefinition(name: "IDX_PARENT_NAME", columns: ["NAME"])],
            foreignKeys: []
        )
        _ = try await checked("create parent") {
            try await driver.execute(query: try XCTUnwrap(driver.generateCreateTableSQL(definition: parentDefinition)))
        }
        _ = try await checked("comment parent") {
            try await driver.execute(query: "COMMENT ON TABLE \"PARENT\" IS 'TablePro DM8 integration fixture'")
        }
        _ = try await checked("create child") {
            try await driver.execute(query: """
                CREATE TABLE "CHILD" (
                    "ID" INT PRIMARY KEY,
                    "PARENT_ID" INT,
                    CONSTRAINT "FK_CHILD_PARENT" FOREIGN KEY ("PARENT_ID") REFERENCES "PARENT" ("ID") ON DELETE CASCADE
                )
                """)
        }
        _ = try await checked("create view") {
            try await driver.execute(
                query: "CREATE OR REPLACE VIEW \"PARENT_VIEW\" AS SELECT \"ID\", \"NAME\" FROM \"PARENT\""
            )
        }

        let hostileText = "Robert'); DROP TABLE \"PARENT\"; -- 达梦"
        let payload = Data([0x00, 0x01, 0x7F, 0xFF])
        _ = try await checked("insert unicode and binary") {
            try await driver.executeParameterized(
                query: "INSERT INTO \"PARENT\" (\"NAME\", \"PAYLOAD\") VALUES (?, ?)",
                parameters: [.text(hostileText), .bytes(payload)]
            )
        }
        for index in 1...4 {
            _ = try await checked("insert row \(index)") {
                try await driver.executeParameterized(
                    query: "INSERT INTO \"PARENT\" (\"NAME\") VALUES (?)",
                    parameters: [.text("row-\(index)")]
                )
            }
        }

        // ALL_COL_COMMENTS keys its OWNER on the schema's owning user, not on the schema, so a
        // schema owned by a differently named user used to return no column comments at all.
        let parentColumns = try await checked("read columns") {
            try await driver.fetchColumns(table: "PARENT", schema: schema)
        }
        let nameColumn = parentColumns.first { $0.name == "NAME" }
        XCTAssertEqual(nameColumn?.comment, "the parent name")
        XCTAssertEqual(parentColumns.first { $0.name == "ID" }?.isPrimaryKey, true)

        let columnsByTable = try await checked("read all columns") {
            try await driver.fetchAllColumns(schema: schema)
        }
        let bulkName = columnsByTable["PARENT"]?.first { $0.name == "NAME" }
        XCTAssertEqual(bulkName?.comment, "the parent name")

        let valueResult = try await checked("read unicode and binary metadata") {
            try await driver.execute(
                query: "SELECT \"NAME\", RAWTOHEX(\"PAYLOAD\") FROM \"PARENT\" ORDER BY \"ID\""
            )
        }
        XCTAssertEqual(valueResult.rows.first?[0], .text(hostileText))
        XCTAssertEqual(valueResult.rows.first?[1], .text("00017FFF"))

        // The last fractional digit is deliberately non-zero: DM8 renders a value without its
        // insignificant trailing zeros, so a literal ending in one could not tell that apart
        // from the 38th significant digit being lost, which is what this checks.
        let preciseDecimal = "1234567890123456789012345678.1234567891"
        let decimalResult = try await checked("read high-precision decimal") {
            try await driver.execute(
                query: "SELECT CAST('\(preciseDecimal)' AS DECIMAL(38, 10)) FROM DUAL"
            )
        }
        XCTAssertEqual(decimalResult.rows.first?.first, .text(preciseDecimal))

        let capped = try await driver.executeUserQuery(
            query: "SELECT \"ID\" FROM \"PARENT\" ORDER BY \"ID\"",
            rowCap: 2,
            parameters: nil
        )
        XCTAssertEqual(capped.rows.count, 2)
        XCTAssertTrue(capped.isTruncated)

        let tables = try await driver.fetchTables(schema: schema)
        XCTAssertTrue(tables.contains { $0.name == "PARENT" && $0.type == "TABLE" })
        XCTAssertTrue(tables.contains { $0.name == "PARENT_VIEW" && $0.type == "VIEW" })
        let columns = try await checked("fetch columns") {
            try await driver.fetchColumns(table: "PARENT", schema: schema)
        }
        XCTAssertTrue(columns.contains { $0.name == "ID" && $0.isPrimaryKey })
        XCTAssertTrue(columns.contains { $0.name == "NAME" && $0.dataType == "VARCHAR(100)" })
        let allColumns = try await checked("fetch completion columns") {
            try await driver.fetchAllColumns(schema: schema)
        }
        XCTAssertEqual(allColumns["PARENT"]?.map(\.name), ["ID", "NAME", "PAYLOAD"])
        XCTAssertEqual(allColumns["PARENT_VIEW"]?.map(\.name), ["ID", "NAME"])
        let indexes = try await checked("fetch indexes") {
            try await driver.fetchIndexes(table: "PARENT", schema: schema)
        }
        XCTAssertTrue(indexes.contains { $0.name == "IDX_PARENT_NAME" && $0.columns == ["NAME"] })
        let foreignKeys = try await checked("fetch foreign keys") {
            try await driver.fetchForeignKeys(table: "CHILD", schema: schema)
        }
        XCTAssertTrue(foreignKeys.contains {
            $0.name == "FK_CHILD_PARENT" && $0.referencedTable == "PARENT" && $0.onDelete == "CASCADE"
        })
        let emptyForeignKeys = try await checked("fetch empty foreign keys") {
            try await driver.fetchForeignKeys(table: "PARENT", schema: schema)
        }
        XCTAssertTrue(emptyForeignKeys.isEmpty)
        try await checked("ping after empty metadata") {
            try await driver.ping()
        }
        let viewDefinition = try await checked("fetch view definition") {
            try await driver.fetchViewDefinition(view: "PARENT_VIEW", schema: schema)
        }
        XCTAssertTrue(viewDefinition.contains("PARENT"))
        let tableDDL = try await checked("fetch table DDL") {
            try await driver.fetchTableDDL(table: "PARENT", schema: schema)
        }
        XCTAssertTrue(tableDDL.contains("PRIMARY KEY"))
        let metadata = try await checked("fetch table metadata") {
            try await driver.fetchTableMetadata(table: "PARENT", schema: schema)
        }
        XCTAssertEqual(metadata.engine, "DM8")
        XCTAssertEqual(metadata.comment, "TablePro DM8 integration fixture")

        let explain = try await checked("explain") {
            try await driver.execute(query: try XCTUnwrap(driver.buildExplainQuery("SELECT * FROM \"PARENT\"")))
        }
        XCTAssertEqual(explain.columns, ["PLAN"])
        XCTAssertTrue(explain.rows.first?.first?.asText?.contains("#") == true)
        try await checked("ping after explain") {
            try await driver.ping()
        }

        try await checked("begin transaction") {
            try await driver.beginTransaction()
        }
        _ = try await checked("insert rollback row") {
            try await driver.execute(query: "INSERT INTO \"PARENT\" (\"NAME\") VALUES ('rollback-row')")
        }
        try await checked("rollback transaction") {
            try await driver.rollbackTransaction()
        }
        let rollbackCount = try await checked("verify rollback") {
            try await driver.execute(query: "SELECT COUNT(*) FROM \"PARENT\" WHERE \"NAME\" = 'rollback-row'")
        }
        XCTAssertEqual(rollbackCount.rows.first?.first, .text("0"))

        do {
            _ = try await driver.execute(query: "SELECT * FROM \"MISSING_TABLE\"")
            XCTFail("Expected an invalid query to fail")
        } catch {
            try await driver.ping()
        }

        do {
            try await driver.switchSchema(to: "\"; DROP SCHEMA \(schema) CASCADE; --")
            XCTFail("Expected an invalid schema to fail")
        } catch {
            let schemas = try await driver.fetchSchemas()
            XCTAssertTrue(schemas.contains(schema))
        }

        do {
            try await driver.dropSchema(name: "SYSDBA")
            XCTFail("Expected a system schema drop to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("system"))
        }

        try await withThrowingTaskGroup(of: PluginCellValue?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let result = try await driver.execute(query: "SELECT USER FROM DUAL")
                    return result.rows.first?.first
                }
            }
            for try await value in group {
                XCTAssertEqual(value, .text("SYSDBA"))
            }
        }
    }

    private func liveEnvironment() throws -> LiveEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TABLEPRO_DM8_INTEGRATION"] == "1" else {
            throw XCTSkip("Set TABLEPRO_DM8_INTEGRATION=1 to run against DM8 in OrbStack")
        }
        guard let host = environment["DM_HOST"],
              let portText = environment["DM_PORT"],
              let port = Int(portText),
              let username = environment["DM_USER"],
              let password = environment["DM_PASSWORD"] else {
            XCTFail("DM_HOST, DM_PORT, DM_USER, and DM_PASSWORD are required")
            throw XCTSkip("DM8 integration environment is incomplete")
        }
        return LiveEnvironment(host: host, port: port, username: username, password: password)
    }

    @discardableResult
    private func checked<T: Sendable>(
        _ step: String,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            XCTFail("\(step): \(error)")
            throw error
        }
    }

    private func testConfig(database: String) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: "127.0.0.1",
            port: 5_236,
            username: "SYSDBA",
            password: "test-only",
            database: database
        )
    }
}

private struct LiveEnvironment {
    let host: String
    let port: Int
    let username: String
    let password: String

    func config(database: String) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database
        )
    }
}
