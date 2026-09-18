import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import XCTest

/// Integration tests for the iOS Oracle driver against a real Oracle instance.
///
/// All tests skip unless `ORACLE_TEST_HOST` is set in the environment. To run locally:
/// ```
/// ORACLE_TEST_HOST=localhost ORACLE_TEST_USER=system ORACLE_TEST_PASSWORD='oracle' \
/// ORACLE_TEST_SERVICE=FREEPDB1 \
/// xcodebuild test -scheme TableProMobile -only-testing:TableProMobileTests/OracleDriverTests
/// ```
final class OracleDriverTests: XCTestCase {
    private var driver: OracleDriver?
    private var schema = ""

    private static func loadTestConfig() -> [String: String]? {
        let env = ProcessInfo.processInfo.environment
        if env["ORACLE_TEST_HOST"] != nil {
            return env
        }
        let fallbackPath = env["ORACLE_TEST_CONFIG_PATH"] ?? "/tmp/oracle-test.json"
        guard let data = FileManager.default.contents(atPath: fallbackPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return json
    }

    private static func makeConnection(from config: [String: String]) -> DatabaseConnection {
        let usesSID = config["ORACLE_TEST_SID"] != nil
        var additionalFields = [
            OracleConnectionOptions.AdditionalFieldKey.connectionType:
                usesSID ? OracleConnectionOptions.IdentifierMode.sid.rawValue
                        : OracleConnectionOptions.IdentifierMode.service.rawValue
        ]
        additionalFields[OracleConnectionOptions.AdditionalFieldKey.serviceName] =
            config["ORACLE_TEST_SERVICE"] ?? "FREEPDB1"
        additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] = config["ORACLE_TEST_SID"] ?? ""

        let mode: SSLConfiguration.SSLMode
        switch config["ORACLE_TEST_SSL_MODE"] ?? "disable" {
        case "require": mode = .require
        case "verifyCa": mode = .verifyCa
        case "verifyFull": mode = .verifyFull
        default: mode = .disable
        }

        return DatabaseConnection(
            name: "test",
            type: .oracle,
            host: config["ORACLE_TEST_HOST"] ?? "localhost",
            port: Int(config["ORACLE_TEST_PORT"] ?? "1521") ?? 1_521,
            username: config["ORACLE_TEST_USER"] ?? "system",
            database: "",
            additionalFields: additionalFields,
            sslEnabled: mode != .disable,
            sslConfiguration: SSLConfiguration(mode: mode)
        )
    }

    override func setUp() async throws {
        guard let config = Self.loadTestConfig() else {
            throw XCTSkip("ORACLE_TEST_HOST not set and /tmp/oracle-test.json not found, skipping integration tests")
        }
        let connection = Self.makeConnection(from: config)
        schema = (config["ORACLE_TEST_USER"] ?? "system").uppercased()
        let driver = OracleDriver(connection: connection, password: config["ORACLE_TEST_PASSWORD"] ?? "")
        try await driver.connect()
        self.driver = driver
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
        XCTAssertNotNil(driver.currentSchema)
    }

    func testSimpleQuery() async throws {
        let driver = try XCTUnwrap(driver)
        let result = try await driver.execute(query: "SELECT 1 AS one, 'hello' AS greeting FROM DUAL")
        XCTAssertEqual(result.columns.map(\.name), ["ONE", "GREETING"])
        XCTAssertEqual(result.rows.first?[0], "1")
        XCTAssertEqual(result.rows.first?[1], "hello")
    }

    func testPingRecoversAfterTheConnectionIsDropped() async throws {
        let driver = try XCTUnwrap(driver)
        try await driver.cancelCurrentQuery()
        let pong = try await driver.ping()
        XCTAssertTrue(pong, "ping must redial rather than report a dead connection as healthy")
    }

    func testFetchSchemasIncludesTheConnectedUser() async throws {
        let driver = try XCTUnwrap(driver)
        let names = try await driver.fetchSchemas()
        XCTAssertTrue(names.contains(schema))
    }

    func testFetchDatabasesMatchesSchemas() async throws {
        let driver = try XCTUnwrap(driver)
        let databases = try await driver.fetchDatabases()
        let schemas = try await driver.fetchSchemas()
        XCTAssertEqual(databases, schemas)
    }

    func testFetchTablesAndColumns() async throws {
        let driver = try XCTUnwrap(driver)
        try await recreateTable(
            "TP_MOBILE_TEST",
            body: "id NUMBER(10) PRIMARY KEY, name VARCHAR2(100)"
        )

        let tables = try await driver.fetchTables(schema: schema)
        XCTAssertTrue(tables.contains { $0.name == "TP_MOBILE_TEST" && $0.type == .table })

        let columns = try await driver.fetchColumns(table: "TP_MOBILE_TEST", schema: schema)
        XCTAssertEqual(columns.count, 2)
        let id = columns.first { $0.name == "ID" }
        XCTAssertEqual(id?.isPrimaryKey, true)
        XCTAssertEqual(id?.typeName, "number(10)")
        XCTAssertEqual(columns.first { $0.name == "NAME" }?.typeName, "varchar2(100)")
    }

    func testFetchIndexesReportsThePrimaryKey() async throws {
        let driver = try XCTUnwrap(driver)
        try await recreateTable("TP_MOBILE_IDX", body: "id NUMBER(10) PRIMARY KEY, label VARCHAR2(20)")
        let indexes = try await driver.fetchIndexes(table: "TP_MOBILE_IDX", schema: schema)
        XCTAssertTrue(indexes.contains { $0.isPrimary && $0.columns == ["ID"] })
    }

    func testFetchForeignKeysResolvesTheReference() async throws {
        let driver = try XCTUnwrap(driver)
        try await recreateTable("TP_MOBILE_PARENT", body: "id NUMBER(10) PRIMARY KEY")
        try await recreateTable(
            "TP_MOBILE_CHILD",
            body: """
                id NUMBER(10) PRIMARY KEY, \
                parent_id NUMBER(10), \
                CONSTRAINT fk_tp_mobile_child FOREIGN KEY (parent_id) REFERENCES TP_MOBILE_PARENT (id)
                """
        )
        let keys = try await driver.fetchForeignKeys(table: "TP_MOBILE_CHILD", schema: schema)
        let match = try XCTUnwrap(keys.first { $0.name.uppercased() == "FK_TP_MOBILE_CHILD" })
        XCTAssertEqual(match.column, "PARENT_ID")
        XCTAssertEqual(match.referencedTable, "TP_MOBILE_PARENT")
        XCTAssertEqual(match.referencedColumn, "ID")
    }

    func testOffsetFetchPaginationOrdersDeterministically() async throws {
        let driver = try XCTUnwrap(driver)
        try await recreateTable("TP_MOBILE_PAGE", body: "id NUMBER(10) PRIMARY KEY, label VARCHAR2(20)")
        for (id, label) in [(1, "a"), (2, "b"), (3, "c"), (4, "d"), (5, "e")] {
            _ = try await driver.execute(query: "INSERT INTO TP_MOBILE_PAGE VALUES (\(id), '\(label)')")
        }
        try await driver.commitTransaction()

        let result = try await driver.execute(query: """
            SELECT id, label FROM TP_MOBILE_PAGE
            ORDER BY id ASC
            OFFSET 2 ROWS FETCH NEXT 2 ROWS ONLY
            """)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows.first?.first, "3")
        XCTAssertEqual(result.rows.last?.first, "4")
    }

    func testRollbackDiscardsInsertedRows() async throws {
        let driver = try XCTUnwrap(driver)
        try await recreateTable("TP_MOBILE_TX", body: "v NUMBER(10)")
        try await driver.beginTransaction()
        _ = try await driver.execute(query: "INSERT INTO TP_MOBILE_TX VALUES (42)")
        try await driver.rollbackTransaction()

        let result = try await driver.execute(query: "SELECT COUNT(*) FROM TP_MOBILE_TX")
        XCTAssertEqual(result.rows.first?.first, "0")
    }

    func testStreamingYieldsColumnsThenRows() async throws {
        let driver = try XCTUnwrap(driver)
        try await recreateTable("TP_MOBILE_STREAM", body: "id NUMBER(10) PRIMARY KEY")
        for id in 1...3 {
            _ = try await driver.execute(query: "INSERT INTO TP_MOBILE_STREAM VALUES (\(id))")
        }
        try await driver.commitTransaction()

        var sawColumns = false
        var rowCount = 0
        for try await element in driver.executeStreaming(
            query: "SELECT id FROM TP_MOBILE_STREAM ORDER BY id",
            options: .default
        ) {
            switch element {
            case .columns(let columns):
                sawColumns = true
                XCTAssertEqual(columns.map(\.name), ["ID"])
            case .row:
                rowCount += 1
            default:
                break
            }
        }
        XCTAssertTrue(sawColumns)
        XCTAssertEqual(rowCount, 3)
    }

    func testWrongIdentifierModeReportsTheListenerCode() async throws {
        let config = try XCTUnwrap(Self.loadTestConfig())
        var connection = Self.makeConnection(from: config)
        connection.additionalFields[OracleConnectionOptions.AdditionalFieldKey.connectionType] =
            OracleConnectionOptions.IdentifierMode.sid.rawValue
        connection.additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] = "DEFINITELY_NOT_A_SID"

        let badDriver = OracleDriver(connection: connection, password: config["ORACLE_TEST_PASSWORD"] ?? "")
        do {
            try await badDriver.connect()
            XCTFail("An unknown SID should be refused by the listener")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                description.contains("ORA-12505") || description.contains("ORA-12514"),
                "expected a listener refusal code, got \(description)"
            )
        }
    }

    private func recreateTable(_ name: String, body: String) async throws {
        let driver = try XCTUnwrap(driver)
        _ = try? await driver.execute(query: "DROP TABLE \(name) CASCADE CONSTRAINTS")
        _ = try await driver.execute(query: "CREATE TABLE \(name) (\(body))")
    }
}
