//
//  ObjectCopyServerSideInsertTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Quotes with backticks and takes the MySQL spelling of a row limit, which is enough to read the
/// statements back. The rules under test are about which name is used, not about how it is quoted.
private final class ServerSideInsertDriver: PluginDriverStub, @unchecked Sendable {
    private let injectsRowLimit: Bool

    init(injectsRowLimit: Bool = true) {
        self.injectsRowLimit = injectsRowLimit
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    func injectRowLimit(_ query: String, limit: Int) -> String? {
        injectsRowLimit ? "\(query) LIMIT \(limit)" : nil
    }
}

struct ObjectCopyServerSideInsertTests {
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
    @Test
    func twoConnectionsAreNeverEligible() {
        #expect(!(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop"),
            target: endpoint("shop_copy", connectionId: UUID())
        )))
    }

    @Test
    func oneConnectionAndOneDatabaseIsAlwaysEligible() {
        for type in [DatabaseType.mysql, .postgresql, .sqlite, .oracle, .duckdb] {
            #expect(ObjectCopyServerSideInsert.isEligible(
                    source: endpoint("shop", schema: "a", type: type),
                    target: endpoint("shop", schema: "b", type: type)
                ),
                "\(type.rawValue)")
        }
    }

    /// PostgreSQL cannot name a second database in one statement under any spelling, so a copy
    /// between two of them streams through the app as it always did.
    @Test
    func onlyTheEnginesThatCanNameASecondDatabaseCrossOne() {
        #expect(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .mysql), target: endpoint("shop_copy", type: .mysql)
        ))
        #expect(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .mssql), target: endpoint("shop_copy", type: .mssql)
        ))
        #expect(!(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .postgresql), target: endpoint("shop_copy", type: .postgresql)
        )))
        #expect(!(ObjectCopyServerSideInsert.isEligible(
            source: endpoint("shop", type: .duckdb), target: endpoint("shop_copy", type: .duckdb)
        )))
    }

    // MARK: - The statement

    @Test
    func aWithinDatabaseCopyNamesTheSchema() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop", schema: "old", type: .postgresql),
                target: endpoint("shop", schema: "new", type: .postgresql),
                sourceSchema: "old",
                targetSchema: "new"
            ),
            driver: ServerSideInsertDriver()
        )
        #expect(sql == "INSERT INTO `new`.`orders` (`id`, `name`) SELECT `id`, `name` FROM `old`.`orders`")
    }

    /// The statement runs in the target's database, so an unqualified source name would resolve
    /// there: the copy would read the table it was about to write.
    @Test
    func aCrossDatabaseCopyNamesTheDatabase() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(source: endpoint("shop"), target: endpoint("shop_copy")),
            driver: ServerSideInsertDriver()
        )
        #expect(sql == "INSERT INTO `orders` (`id`, `name`) SELECT `id`, `name` FROM `shop`.`orders`")
    }

    /// `Shop` and `shop` are one database on a case-insensitive server and two on a case-sensitive
    /// one, so the qualifier is written whenever the engine has one rather than when the strings
    /// look different.
    @Test
    func theDatabaseIsNamedEvenWhenBothSidesSpellItTheSame() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(source: endpoint("shop"), target: endpoint("shop")),
            driver: ServerSideInsertDriver()
        )
        #expect(sql?.contains("FROM `shop`.`orders`") == true)
    }

    @Test
    func sQLServerNamesTheDatabaseAndTheSchema() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop", schema: "sales", type: .mssql),
                target: endpoint("shop_copy", schema: "dbo", type: .mssql),
                sourceSchema: "sales",
                targetSchema: "dbo"
            ),
            driver: ServerSideInsertDriver()
        )
        #expect(sql?.contains("FROM `shop`.`sales`.`orders`") == true)
    }

    @Test
    func theRowScopeReachesTheStatement() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop"),
                target: endpoint("shop_copy"),
                scope: PluginExportRowScope(filter: "total > 10", rowLimit: 100)
            ),
            driver: ServerSideInsertDriver()
        )
        #expect(sql?.contains("WHERE total > 10") == true)
        #expect(sql?.hasSuffix("LIMIT 100") == true)
    }

    @Test
    func aRowLimitTheDriverCannotInjectIsSpelledForSQLServer() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop", schema: "sales", type: .mssql),
                target: endpoint("shop_copy", schema: "dbo", type: .mssql),
                sourceSchema: "sales",
                targetSchema: "dbo",
                scope: PluginExportRowScope(filter: "total > 10", rowLimit: 100)
            ),
            driver: ServerSideInsertDriver(injectsRowLimit: false)
        )
        #expect(sql == "INSERT INTO `dbo`.`orders` (`id`, `name`) SELECT TOP 100 `id`, `name` FROM `shop`.`sales`.`orders`"
                + " WHERE total > 10")
    }

    @Test
    func aRowLimitTheDriverCannotInjectIsSpelledForOracle() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("ORCL", schema: "HR", type: .oracle),
                target: endpoint("ORCL", schema: "ARCHIVE", type: .oracle),
                sourceSchema: "HR",
                targetSchema: "ARCHIVE",
                scope: PluginExportRowScope(rowLimit: 100)
            ),
            driver: ServerSideInsertDriver(injectsRowLimit: false)
        )
        #expect(sql == "INSERT INTO `ARCHIVE`.`orders` (`id`, `name`) SELECT `id`, `name` FROM `HR`.`orders`"
                + " FETCH FIRST 100 ROWS ONLY")
    }

    /// The same rule the streamed path follows: a filter is one expression, and text carrying a
    /// second statement is refused rather than spliced in.
    @Test
    func aFilterCarryingASecondStatementIsNotSpliced() {
        let sql = ObjectCopyServerSideInsert.statement(
            input(
                source: endpoint("shop"),
                target: endpoint("shop_copy"),
                scope: PluginExportRowScope(filter: "1=1; DROP TABLE orders")
            ),
            driver: ServerSideInsertDriver()
        )
        #expect(sql?.contains("DROP TABLE") == false)
        #expect(sql?.contains("WHERE") == false)
    }

    /// A mismatch means the plan and the statement disagree about which columns are written, which
    /// would put values in the wrong columns.
    @Test
    func mismatchedColumnListsProduceNoStatement() {
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
        #expect(ObjectCopyServerSideInsert.statement(mismatched, driver: ServerSideInsertDriver()) == nil)
    }
}
