import XCTest
import TableProDatabase
import TableProModels
@testable import TableProMobile

/// Integration tests for the iOS MSSQL driver against a real SQL Server instance.
///
/// All tests skip unless `MSSQL_TEST_HOST` is set in the environment. To run locally:
/// ```
/// MSSQL_TEST_HOST=localhost MSSQL_TEST_USER=sa MSSQL_TEST_PASSWORD='YourStrong!Pass' \
/// xcodebuild test -scheme TableProMobile -only-testing:TableProMobileTests/MSSQLDriverTests
/// ```
final class MSSQLDriverTests: XCTestCase {
    private var driver: MSSQLDriver?

    private static func loadTestConfig() -> [String: String]? {
        let env = ProcessInfo.processInfo.environment
        if env["MSSQL_TEST_HOST"] != nil {
            return env
        }
        let fallbackPath = "/tmp/mssql-test.json"
        guard let data = FileManager.default.contents(atPath: fallbackPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return json
    }

    override func setUp() async throws {
        guard let config = Self.loadTestConfig() else {
            throw XCTSkip("MSSQL_TEST_HOST not set and /tmp/mssql-test.json not found, skipping integration tests")
        }
        let mode: SSLConfiguration.SSLMode
        switch config["MSSQL_TEST_SSL_MODE"] ?? "disable" {
        case "require": mode = .require
        case "verifyCa": mode = .verifyCa
        case "verifyFull": mode = .verifyFull
        default: mode = .disable
        }
        let connection = DatabaseConnection(
            name: "test",
            type: .mssql,
            host: config["MSSQL_TEST_HOST"] ?? "localhost",
            port: Int(config["MSSQL_TEST_PORT"] ?? "1433") ?? 1433,
            username: config["MSSQL_TEST_USER"] ?? "sa",
            database: config["MSSQL_TEST_DATABASE"] ?? "master",
            additionalFields: ["mssqlSchema": "dbo"],
            sslEnabled: mode != .disable,
            sslConfiguration: SSLConfiguration(mode: mode)
        )
        let password = config["MSSQL_TEST_PASSWORD"] ?? ""
        driver = MSSQLDriver(connection: connection, password: password)
        try await driver?.connect()
    }

    override func tearDown() async throws {
        try await driver?.disconnect()
        driver = nil
    }

    func testConnectAndPing() async throws {
        let driver = try XCTUnwrap(driver)
        let pong = try await driver.ping()
        XCTAssertTrue(pong)
        XCTAssertNotNil(driver.serverVersion)
    }

    func testSimpleQuery() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT 1 AS one, 'hello' AS greeting")
        XCTAssertEqual(result.columns.map { $0.name }, ["one", "greeting"])
        XCTAssertEqual(result.rows.first?[0], "1")
        XCTAssertEqual(result.rows.first?[1], "hello")
    }

    func testFetchDatabasesIncludesMaster() async throws {
        let driver = try XCTUnwrap(driver)
        let names = try await driver.fetchDatabases()
        XCTAssertTrue(names.contains("master"))
    }

    func testFetchSchemasExcludesSystemSchemas() async throws {
        let driver = try XCTUnwrap(driver)
        let names = try await driver.fetchSchemas()
        XCTAssertFalse(names.contains("sys"))
        XCTAssertFalse(names.contains("information_schema"))
    }

    func testFetchTablesReturnsResults() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tablepro_test_table', 'U') IS NULL
                CREATE TABLE dbo.tablepro_test_table (id INT PRIMARY KEY IDENTITY(1,1), name NVARCHAR(100))
            """)
        let tables = try await driver.fetchTables(schema: "dbo")
        XCTAssertTrue(tables.contains { $0.name == "tablepro_test_table" && $0.type == .table })
    }

    func testFetchColumnsReturnsTypeMetadata() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tablepro_test_table', 'U') IS NULL
                CREATE TABLE dbo.tablepro_test_table (id INT PRIMARY KEY IDENTITY(1,1), name NVARCHAR(100))
            """)
        let columns = try await driver.fetchColumns(table: "tablepro_test_table", schema: "dbo")
        XCTAssertEqual(columns.count, 2)
        let id = columns.first { $0.name == "id" }
        XCTAssertEqual(id?.isPrimaryKey, true)
        XCTAssertEqual(id?.typeName, "int")
        let name = columns.first { $0.name == "name" }
        XCTAssertEqual(name?.typeName, "nvarchar(100)")
    }

    func testExplicitTransactionRollback() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tablepro_tx_test', 'U') IS NULL
                CREATE TABLE dbo.tablepro_tx_test (v INT)
            """)
        _ = try await driver.execute(query: "DELETE FROM dbo.tablepro_tx_test")

        try await driver.beginTransaction()
        _ = try await driver.execute(query: "INSERT INTO dbo.tablepro_tx_test VALUES (42)")
        try await driver.rollbackTransaction()

        let result = try await driver.execute(query: "SELECT COUNT(*) FROM dbo.tablepro_tx_test")
        XCTAssertEqual(result.rows.first?.first, "0")
    }
}
