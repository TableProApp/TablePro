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
