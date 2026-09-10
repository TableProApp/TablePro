//
//  ObjectCopyServerSideInsertTests.swift
//  TableProTests
//

import TableProPluginKit
import XCTest
@testable import TablePro

/// Quotes with backticks and takes the MySQL spelling of a row limit, which is enough to read the
/// statements back. The rules under test are about which name is used, not about how it is quoted.
private final class ServerSideInsertDriver: PluginDatabaseDriver, @unchecked Sendable {
    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    func injectRowLimit(_ query: String, limit: Int) -> String? {
        "\(query) LIMIT \(limit)"
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

final class ObjectCopyServerSideInsertTests: XCTestCase {
    private let connectionId = UUID()

    private func endpoint(
        _ database: String,
        schema: String? = nil,
        type: DatabaseType = .mysql,
        connectionId: UUID? = nil
    ) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(
                connectionId: connectionId ?? self.connectionId, database: database, schema: schema
            ),
            connectionName: "server",
            databaseType: type,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func input(
        source: DatabaseEndpoint,
        target: DatabaseEndpoint,
        sourceSchema: String? = nil,
        targetSchema: String? = nil,
        scope: PluginExportRowScope? = nil
    ) -> ObjectCopyServerSideInsert.Input {
        ObjectCopyServerSideInsert.Input(
            source: source,
            target: target,
            sourceTable: "orders",
            sourceSchema: sourceSchema,
            targetTable: "orders",
            targetSchema: targetSchema,
            sourceColumns: ["id", "name"],
            targetColumns: ["id", "name"],
            scope: scope
        )
    }

    // MARK: - Eligibility

    /// The whole point of the fast path is that one session can see both sides. Two connections
    /// cannot, whatever engine they run.
    func testTwoConnectionsAreNeverEligible() {
        XCTAssertFalse(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop"),
            target: endpoint("shop_copy", connectionId: UUID())
        ))
    }

    func testOneConnectionAndOneDatabaseIsAlwaysEligible() {
        for type in [DatabaseType.mysql, .postgresql, .sqlite, .oracle, .duckdb] {
            XCTAssertTrue(
                ObjectCopyServerSideInsert.isEligible(
                    source: endpoint("shop", schema: "a", type: type),
                    target: endpoint("shop", schema: "b", type: type)
                ),
                "\(type.rawValue)"
            )
        }
    }

    /// PostgreSQL cannot name a second database in one statement under any spelling, so a copy
    /// between two of them streams through the app as it always did.
    func testOnlyTheEnginesThatCanNameASecondDatabaseCrossOne() {
        XCTAssertTrue(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .mysql), target: endpoint("shop_copy", type: .mysql)
        ))
        XCTAssertTrue(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .mssql), target: endpoint("shop_copy", type: .mssql)
        ))
        XCTAssertFalse(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .postgresql), target: endpoint("shop_copy", type: .postgresql)
        ))
        XCTAssertFalse(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .duckdb), target: endpoint("shop_copy", type: .duckdb)
        ))
    }

    // MARK: - The statement

    func testAWithinDatabaseCopyNamesTheSchema() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop", schema: "old", type: .postgresql),
                target: endpoint("shop", schema: "new", type: .postgresql),
                sourceSchema: "old",
                targetSchema: "new"
            ),
            driver: ServerSideInsertDriver()
        )
        XCTAssertEqual(
            sql,
            "INSERT INTO `new`.`orders` (`id`, `name`) SELECT `id`, `name` FROM `old`.`orders`;"
        )
    }

    /// The statement runs in the target's database, so an unqualified source name would resolve
    /// there: the copy would read the table it was about to write.
    func testACrossDatabaseCopyNamesTheDatabase() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(source: endpoint("shop"), target: endpoint("shop_copy")),
            driver: ServerSideInsertDriver()
        )
        XCTAssertEqual(
            sql,
            "INSERT INTO `orders` (`id`, `name`) SELECT `id`, `name` FROM `shop`.`orders`;"
        )
    }

    /// `Shop` and `shop` are one database on a case-insensitive server and two on a case-sensitive
    /// one, so the qualifier is written whenever the engine has one rather than when the strings
    /// look different.
    func testTheDatabaseIsNamedEvenWhenBothSidesSpellItTheSame() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(source: endpoint("shop"), target: endpoint("shop")),
            driver: ServerSideInsertDriver()
        )
        XCTAssertEqual(sql?.contains("FROM `shop`.`orders`"), true)
    }

    func testSQLServerNamesTheDatabaseAndTheSchema() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop", schema: "sales", type: .mssql),
                target: endpoint("shop_copy", schema: "dbo", type: .mssql),
                sourceSchema: "sales",
                targetSchema: "dbo"
            ),
            driver: ServerSideInsertDriver()
        )
        XCTAssertEqual(sql?.contains("FROM `shop`.`sales`.`orders`"), true)
    }

    func testTheRowScopeReachesTheStatement() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop"),
                target: endpoint("shop_copy"),
                scope: PluginExportRowScope(filter: "total > 10", rowLimit: 100)
            ),
            driver: ServerSideInsertDriver()
        )
        XCTAssertEqual(sql?.contains("WHERE total > 10"), true)
        XCTAssertEqual(sql?.hasSuffix("LIMIT 100;"), true)
    }

    /// The same rule the streamed path follows: a filter is one expression, and text carrying a
    /// second statement is refused rather than spliced in.
    func testAFilterCarryingASecondStatementIsNotSpliced() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop"),
                target: endpoint("shop_copy"),
                scope: PluginExportRowScope(filter: "1=1; DROP TABLE orders")
            ),
            driver: ServerSideInsertDriver()
        )
        XCTAssertEqual(sql?.contains("DROP TABLE"), false)
        XCTAssertEqual(sql?.contains("WHERE"), false)
    }

    /// A mismatch means the plan and the statement disagree about which columns are written, which
    /// would put values in the wrong columns.
    func testMismatchedColumnListsProduceNoStatement() {
        let mismatched = ObjectCopyServerSideInsert.Input(
            source: endpoint("shop"),
            target: endpoint("shop_copy"),
            sourceTable: "orders",
            sourceSchema: nil,
            targetTable: "orders",
            targetSchema: nil,
            sourceColumns: ["id"],
            targetColumns: ["id", "name"],
            scope: nil
        )
        XCTAssertNil(ObjectCopyServerSideInsert.statement(mismatched, driver: ServerSideInsertDriver()))
    }
}
