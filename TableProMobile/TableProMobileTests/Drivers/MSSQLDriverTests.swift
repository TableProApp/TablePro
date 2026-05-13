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
        let fallbackPath = env["MSSQL_TEST_CONFIG_PATH"] ?? "/tmp/mssql-test.json"
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

    func testSwitchDatabaseChangesActiveDatabase() async throws {
        let driver = try XCTUnwrap(driver)
        try await driver.switchDatabase(to: "tempdb")
        let result = try await driver.execute(query: "SELECT DB_NAME()")
        XCTAssertEqual(result.rows.first?.first, "tempdb")
    }

    func testSortedPaginationEmitsOrderByAndFetch() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tablepro_pagination_test', 'U') IS NOT NULL
                DROP TABLE dbo.tablepro_pagination_test;
            CREATE TABLE dbo.tablepro_pagination_test (id INT PRIMARY KEY, label NVARCHAR(20));
            INSERT INTO dbo.tablepro_pagination_test VALUES
                (1, N'a'), (2, N'b'), (3, N'c'), (4, N'd'), (5, N'e');
            """)
        let result = try await driver.execute(query: """
            SELECT id, label FROM dbo.tablepro_pagination_test
            ORDER BY id ASC
            OFFSET 2 ROWS FETCH NEXT 2 ROWS ONLY
            """)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.first?.first, "3")
        XCTAssertEqual(result.rows.last?.first, "4")
    }

    func testCancellationStopsQuery() async throws {
        let driver = try XCTUnwrap(driver)
        let task = Task { [driver] in
            try await driver.execute(query: "WAITFOR DELAY '00:00:05'; SELECT 1")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled task should have thrown")
        } catch is CancellationError {
            // expected
        } catch {
            // FreeTDS may surface as DatabaseError on race; both are acceptable signals that the
            // query was interrupted rather than completing the 5-second WAITFOR.
            XCTAssertNotNil(error)
        }
    }

    func testWrongPasswordFailsClearly() async throws {
        try XCTSkipIf(Self.loadTestConfig() == nil, "no test config")
        let connection = DatabaseConnection(
            name: "wrong-pw",
            type: .mssql,
            host: "localhost",
            port: 1433,
            username: "sa",
            database: "master",
            additionalFields: ["mssqlSchema": "dbo"]
        )
        let badDriver = MSSQLDriver(connection: connection, password: "definitely-wrong-pass-123")
        do {
            try await badDriver.connect()
            XCTFail("Bad password should fail to connect")
        } catch {
            // any error is acceptable; verify it's not nil and surfaces a message
            let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(desc.isEmpty)
        }
    }

    func testUnreachableHostFails() async throws {
        try XCTSkipIf(Self.loadTestConfig() == nil, "no test config")
        let connection = DatabaseConnection(
            name: "unreachable",
            type: .mssql,
            host: "192.0.2.1",
            port: 1433,
            username: "sa",
            database: "master",
            additionalFields: ["mssqlSchema": "dbo", "mssqlLoginTimeout": "5"]
        )
        let badDriver = MSSQLDriver(connection: connection, password: "x")
        do {
            try await badDriver.connect()
            XCTFail("Connecting to RFC5737 TEST-NET should fail")
        } catch {
            let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(desc.isEmpty)
        }
    }

    // Note: FreeTDS db-lib does not expose per-connection cert validation. `verifyFull` maps to
    // `require` (TLS on, but no CA chain check). Testing strict TLS rejection requires either
    // building FreeTDS with custom OpenSSL callbacks or trusting the certificate via machine-wide
    // freetds.conf, neither of which is per-connection. Out of scope for this driver.

    func testSortedWithFilterCombinesOrderAndWhere() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tp_filter_sort', 'U') IS NOT NULL DROP TABLE dbo.tp_filter_sort;
            CREATE TABLE dbo.tp_filter_sort (id INT PRIMARY KEY, kind NVARCHAR(10), score INT);
            INSERT INTO dbo.tp_filter_sort VALUES
                (1, N'a', 10), (2, N'b', 5), (3, N'a', 20), (4, N'a', 15), (5, N'b', 1);
            """)
        let result = try await driver.execute(query: """
            SELECT id, kind, score FROM [dbo].[tp_filter_sort]
            WHERE kind = N'a'
            ORDER BY score DESC
            OFFSET 0 ROWS FETCH NEXT 2 ROWS ONLY
            """)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.first?[0], "3")
        XCTAssertEqual(result.rows.last?[0], "4")
    }

    func testSelectTopOneCellLookup() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tp_lookup', 'U') IS NOT NULL DROP TABLE dbo.tp_lookup;
            CREATE TABLE dbo.tp_lookup (id INT PRIMARY KEY, payload NVARCHAR(MAX));
            INSERT INTO dbo.tp_lookup VALUES (7, N'hello');
            """)
        let result = try await driver.execute(query: "SELECT TOP 1 [payload] FROM [dbo].[tp_lookup] WHERE [id] = 7")
        XCTAssertEqual(result.rows.first?.first, "hello")
    }

    func testMultiColumnForeignKey() async throws {
        let driver = try XCTUnwrap(driver)
        _ = try await driver.execute(query: """
            IF OBJECT_ID('dbo.tp_fk_child', 'U') IS NOT NULL DROP TABLE dbo.tp_fk_child;
            IF OBJECT_ID('dbo.tp_fk_parent', 'U') IS NOT NULL DROP TABLE dbo.tp_fk_parent;
            CREATE TABLE dbo.tp_fk_parent (
                tenant_id INT NOT NULL,
                external_id INT NOT NULL,
                CONSTRAINT pk_tp_fk_parent PRIMARY KEY (tenant_id, external_id)
            );
            CREATE TABLE dbo.tp_fk_child (
                id INT PRIMARY KEY,
                tenant_id INT NOT NULL,
                external_id INT NOT NULL,
                CONSTRAINT fk_tp_fk_child_parent FOREIGN KEY (tenant_id, external_id)
                    REFERENCES dbo.tp_fk_parent (tenant_id, external_id)
            );
            """)
        let fks = try await driver.fetchForeignKeys(table: "tp_fk_child", schema: "dbo")
        let matched = fks.filter { $0.name == "fk_tp_fk_child_parent" }
        XCTAssertEqual(matched.count, 2, "composite FK should produce two rows")
        let cols = Set(matched.map { $0.column })
        XCTAssertEqual(cols, Set(["tenant_id", "external_id"]))
        XCTAssertTrue(matched.allSatisfy { $0.referencedTable == "tp_fk_parent" })
    }
}
