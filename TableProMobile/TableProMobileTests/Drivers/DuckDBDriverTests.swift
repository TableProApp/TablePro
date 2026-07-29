import XCTest
import TableProDatabase
import TableProModels
@testable import TableProMobile

final class DuckDBDriverTests: XCTestCase {
    private var driver: DuckDBDriver?

    override func setUp() async throws {
        let driver = DuckDBDriver(path: DuckDBDriver.inMemoryPath, bookmark: nil)
        try await driver.connect()
        self.driver = driver
    }

    override func tearDown() async throws {
        try await driver?.disconnect()
        driver = nil
    }

    private func streamedRows(_ driver: DuckDBDriver, _ query: String) async throws -> [[String?]] {
        var rows: [[String?]] = []
        for try await element in driver.executeStreaming(query: query, options: .default) {
            if case .row(let row) = element {
                rows.append(row.cells.map { cell -> String? in
                    if case .null = cell { return nil }
                    return cell.displayString
                })
            }
        }
        return rows
    }

    func testStreamingMatchesMaterializedAcrossTypes() async throws {
        let driver = try XCTUnwrap(driver)
        let query = """
            SELECT
                42::INTEGER AS i,
                9223372036854775807::BIGINT AS big,
                170141183460469231731687303715884105727::HUGEINT AS huge,
                (-170141183460469231731687303715884105727)::HUGEINT AS huge_neg,
                3.5::DOUBLE AS d,
                true AS b,
                'hello' AS s,
                NULL::INTEGER AS n,
                DATE '2024-03-09' AS dt,
                TIMESTAMP '2024-03-09 12:34:56.789' AS tstamp,
                'abc'::BLOB AS payload,
                '550e8400-e29b-41d4-a716-446655440000'::UUID AS uid,
                12.34::DECIMAL(5,2) AS dec,
                INTERVAL '1' MONTH AS iv,
                [1, 2, 3] AS lst,
                {'a': 1, 'b': 2} AS strct
            """
        let materialized = try await driver.execute(query: query)
        let streamed = try await streamedRows(driver, query)

        XCTAssertEqual(streamed.count, 1)
        XCTAssertEqual(materialized.rows.count, 1)
        XCTAssertEqual(streamed[0], materialized.rows[0], "streamed output must match the materialized path exactly")
    }

    func testStreamingMultiRowOrder() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE nums (id INTEGER, label VARCHAR)")
        _ = try await driver.execute(query: "INSERT INTO nums SELECT i, 'row' || i FROM range(1, 2001) t(i)")
        let streamed = try await streamedRows(driver, "SELECT id, label FROM nums ORDER BY id")
        XCTAssertEqual(streamed.count, 2_000)
        XCTAssertEqual(streamed.first, ["1", "row1"])
        XCTAssertEqual(streamed.last, ["2000", "row2000"])
    }

    func testExecuteRendersComplexAndScalarTypes() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: """
            SELECT [1,2,3] AS lst, {'a':1,'b':2} AS strct, 12.34::DECIMAL(5,2) AS dec,
            '550e8400-e29b-41d4-a716-446655440000'::UUID AS uid, DATE '2024-03-09' AS dt,
            TIMESTAMP '2024-03-09 12:34:56' AS ts, 'abc'::BLOB AS payload
            """)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0][0], "[1, 2, 3]")
        XCTAssertEqual(result.rows[0][1], "{'a': 1, 'b': 2}")
        XCTAssertEqual(result.rows[0][2], "12.34")
        XCTAssertEqual(result.rows[0][3], "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(result.rows[0][4], "2024-03-09")
    }

    func testPing() async throws {
        let driver = try XCTUnwrap(driver)
        let alive = try await driver.ping()
        XCTAssertTrue(alive)
    }

    func testServerVersionIsReported() async throws {
        let driver = try XCTUnwrap(driver)
        XCTAssertNotNil(driver.serverVersion)
    }

    func testCreateInsertSelect() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE items (id INTEGER PRIMARY KEY, label VARCHAR, active BOOLEAN)")
        _ = try await driver.execute(query: "INSERT INTO items VALUES (1, 'first', true), (2, 'second', false)")

        let result = try await driver.execute(query: "SELECT id, label, active FROM items ORDER BY id")
        XCTAssertEqual(result.columns.map(\.name), ["id", "label", "active"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], ["1", "first", "true"])
        XCTAssertEqual(result.rows[1], ["2", "second", "false"])
    }

    func testTimestampTzRendersAsText() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT TIMESTAMPTZ '2024-01-02 03:04:05+00' AS ts")
        XCTAssertEqual(result.rows.count, 1)
        let value = try XCTUnwrap(result.rows[0][0])
        XCTAssertTrue(value.contains("2024-01-02"), "expected rendered timestamptz, got \(value)")
    }

    func testVariantRendersAsText() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT {'a': 42, 'b': [1, 2, 3]}::VARIANT AS v")
        XCTAssertEqual(result.rows.count, 1)
        let value = try XCTUnwrap(result.rows[0][0])
        XCTAssertTrue(value.contains("42"), "expected rendered variant text, got \(value)")
    }

    func testCancelWithoutRunningQueryIsSafe() async throws {
        let driver = try XCTUnwrap(driver)
        try await driver.cancelCurrentQuery()
        let alive = try await driver.ping()
        XCTAssertTrue(alive)
    }

    func testNullRendersAsNil() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT NULL AS value")
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertNil(result.rows[0][0])
    }

    func testFetchTablesAndColumns() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL)")

        let tables = try await driver.fetchTables(schema: "main")
        XCTAssertTrue(tables.contains { $0.name == "people" && $0.type == .table })

        let columns = try await driver.fetchColumns(table: "people", schema: "main")
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        let idColumn = try XCTUnwrap(columns.first { $0.name == "id" })
        XCTAssertTrue(idColumn.isPrimaryKey)
        let nameColumn = try XCTUnwrap(columns.first { $0.name == "name" })
        XCTAssertFalse(nameColumn.isNullable)
    }

    func testFetchSchemasIncludesMain() async throws {
        let driver = try XCTUnwrap(driver)
        let schemas = try await driver.fetchSchemas()
        XCTAssertTrue(schemas.contains("main"))
    }

    func testViewIsReportedAsView() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: "CREATE TABLE base (n INTEGER)")
        _ = try await driver.execute(query: "CREATE VIEW base_view AS SELECT n FROM base")

        let tables = try await driver.fetchTables(schema: "main")
        let view = try XCTUnwrap(tables.first { $0.name == "base_view" })
        XCTAssertEqual(view.type, .view)
    }

    func testBlobIsBase64Encoded() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT 'abc'::BLOB AS payload")
        XCTAssertEqual(result.rows[0][0], Data("abc".utf8).base64EncodedString())
    }
}
