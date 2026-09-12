//
//  MaintenanceOperationDescriptorTests.swift
//  TableProTests
//
//  Maintenance used to be a list of bare operation names, so the app offered every one of them on
//  every object: PostgreSQL skips a VACUUM on a view with a WARNING and still reports the success
//  command tag VACUUM, and refuses a REINDEX on one outright. The kind sets below are what
//  PostgreSQL 17.11 and SQLite 3.54.0 actually answered.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Maintenance operation descriptors")
struct MaintenanceOperationDescriptorTests {
    private func postgres(_ name: String) throws -> PluginMaintenanceOperation {
        try #require(PostgreSQLMaintenance.operations.first { $0.name == name })
    }

    private func sqlite(_ name: String) throws -> PluginMaintenanceOperation {
        try #require(SQLiteMaintenance.operations.first { $0.name == name })
    }

    private func mysql(_ name: String) throws -> PluginMaintenanceOperation {
        try #require(MySQLMaintenance.operations.first { $0.name == name })
    }

    private func postgresStatements(
        _ operation: String,
        table: String?,
        schema: String?,
        options: [String: String] = [:]
    ) -> [String]? {
        PostgreSQLMaintenance.statements(
            operation: operation,
            table: table,
            schema: schema,
            options: options,
            connectedDatabase: "app",
            capabilities: PostgreSQLCapabilities(serverVersion: 170_011)
        )
    }

    // MARK: - PostgreSQL kinds

    @Test("CLUSTER is offered on a table and a materialized view and on nothing else")
    func clusterKinds() throws {
        let cluster = try postgres("CLUSTER")

        #expect(cluster.applies(to: .table))
        #expect(cluster.applies(to: .materializedView))
        #expect(!cluster.applies(to: .partitionedTable))
        #expect(!cluster.applies(to: .view))
        #expect(!cluster.applies(to: .foreignTable))
    }

    @Test("ANALYZE reaches a foreign table and VACUUM does not")
    func foreignTableTakesAnalyzeOnly() throws {
        #expect(try postgres("ANALYZE").applies(to: .foreignTable))
        #expect(try !postgres("VACUUM").applies(to: .foreignTable))
    }

    @Test("Nothing PostgreSQL offers applies to a view")
    func noPostgresOperationAppliesToAView() {
        #expect(PostgreSQLMaintenance.operations.allSatisfy { !$0.applies(to: .view) })
    }

    @Test("REINDEX covers a partitioned table, which CLUSTER cannot")
    func partitionedTableKinds() throws {
        #expect(try postgres("REINDEX").applies(to: .partitionedTable))
        #expect(try postgres("VACUUM").applies(to: .partitionedTable))
        #expect(try postgres("ANALYZE").applies(to: .partitionedTable))
    }

    // MARK: - PostgreSQL statements

    @Test("A PostgreSQL target is qualified with the schema it was handed")
    func qualifiesTheSchema() {
        #expect(postgresStatements("REINDEX", table: "orders", schema: "app") == ["REINDEX TABLE \"app\".\"orders\""])
        #expect(postgresStatements("ANALYZE", table: "orders", schema: "app") == ["ANALYZE \"app\".\"orders\""])
        #expect(postgresStatements("VACUUM", table: "orders", schema: "app") == ["VACUUM \"app\".\"orders\""])
        #expect(postgresStatements("CLUSTER", table: "orders", schema: "app") == ["CLUSTER \"app\".\"orders\""])
    }

    @Test("A schema that is nil or empty leaves the name unqualified")
    func unqualifiedWithoutASchema() {
        #expect(postgresStatements("REINDEX", table: "orders", schema: nil) == ["REINDEX TABLE \"orders\""])
        #expect(postgresStatements("REINDEX", table: "orders", schema: "") == ["REINDEX TABLE \"orders\""])
    }

    @Test("A quote in a schema or table name is doubled rather than closing the identifier")
    func quotesAreEscaped() {
        #expect(
            postgresStatements("ANALYZE", table: "or\"ders", schema: "a\"pp")
                == ["ANALYZE \"a\"\"pp\".\"or\"\"ders\""]
        )
    }

    @Test("VACUUM renders the flags the descriptor declares")
    func vacuumFlags() {
        #expect(
            postgresStatements(
                "VACUUM",
                table: "orders",
                schema: "app",
                options: ["full": "true", "analyze": "true", "verbose": "true"]
            ) == ["VACUUM (FULL, ANALYZE, VERBOSE) \"app\".\"orders\""]
        )
        #expect(
            postgresStatements("VACUUM", table: "orders", schema: "app", options: ["analyze": "true"])
                == ["VACUUM (ANALYZE) \"app\".\"orders\""]
        )
        #expect(
            postgresStatements("VACUUM", table: "orders", schema: "app", options: ["full": "false"])
                == ["VACUUM \"app\".\"orders\""]
        )
    }

    @Test("REINDEX renders its own VERBOSE flag before the TABLE keyword")
    func reindexVerbose() {
        #expect(
            postgresStatements("REINDEX", table: "orders", schema: "app", options: ["verbose": "true"])
                == ["REINDEX (VERBOSE) TABLE \"app\".\"orders\""]
        )
    }

    @Test("A PostgreSQL operation with no table falls back to the database-wide form")
    func databaseWideForms() {
        #expect(postgresStatements("VACUUM", table: nil, schema: "app") == ["VACUUM"])
        #expect(
            postgresStatements("VACUUM", table: nil, schema: "app", options: ["analyze": "true"])
                == ["VACUUM (ANALYZE)"]
        )
        #expect(postgresStatements("ANALYZE", table: nil, schema: "app") == ["ANALYZE"])
        /// From PostgreSQL 16 the database name is optional and the statement reindexes the one it is
        /// connected to, which is what `PostgreSQLVersionedStatements.reindexDatabase` emits and what
        /// 17.11 accepted when this was measured. The named form is the 12 to 15 arm, pinned by
        /// `PostgreSQLVersionedStatementsTests`.
        #expect(postgresStatements("REINDEX", table: nil, schema: "app") == ["REINDEX DATABASE CONCURRENTLY"])
        #expect(postgresStatements("CLUSTER", table: nil, schema: "app") == nil)
    }

    @Test("An operation PostgreSQL does not have produces nothing")
    func unknownPostgresOperation() {
        #expect(postgresStatements("OPTIMIZE TABLE", table: "orders", schema: "app") == nil)
    }

    // MARK: - SQLite

    @Test("SQLite VACUUM and Integrity Check name no object and ignore one")
    func sqliteDatabaseScoped() throws {
        let vacuum = try sqlite("VACUUM")
        let integrity = try sqlite("Integrity Check")

        #expect(vacuum.scope == .database)
        #expect(integrity.scope == .database)
        #expect(vacuum.appliesTo.isEmpty)
        #expect(integrity.appliesTo.isEmpty)
        #expect(vacuum.target("orders") == nil)
        #expect(integrity.target("orders") == nil)
        #expect(SQLiteMaintenance.statements(operation: "VACUUM", table: "orders") == ["VACUUM"])
        #expect(SQLiteMaintenance.statements(operation: "Integrity Check", table: "orders") == ["PRAGMA integrity_check"])
    }

    @Test("SQLite ANALYZE and REINDEX are offered on a table and not on a view")
    func sqliteObjectScoped() throws {
        for name in ["ANALYZE", "REINDEX"] {
            let operation = try sqlite(name)
            #expect(operation.applies(to: .table))
            #expect(!operation.applies(to: .view))
            #expect(operation.scope == .objectOrDatabase)
        }
        #expect(SQLiteMaintenance.statements(operation: "ANALYZE", table: "orders") == ["ANALYZE `orders`"])
        #expect(SQLiteMaintenance.statements(operation: "REINDEX", table: nil) == ["REINDEX"])
    }

    @Test("A backtick in a SQLite object name is doubled")
    func sqliteQuoting() {
        #expect(SQLiteMaintenance.statements(operation: "ANALYZE", table: "or`ders") == ["ANALYZE `or``ders`"])
    }

    // MARK: - MySQL

    @Test("CHECK TABLE is the only MySQL operation offered on a view")
    func mysqlViewKinds() throws {
        #expect(try mysql("CHECK TABLE").applies(to: .view))
        #expect(try !mysql("OPTIMIZE TABLE").applies(to: .view))
        #expect(try !mysql("ANALYZE TABLE").applies(to: .view))
        #expect(try !mysql("REPAIR TABLE").applies(to: .view))
    }

    @Test("CHECK TABLE declares its mode, defaulting to MEDIUM")
    func mysqlCheckMode() throws {
        let check = try mysql("CHECK TABLE")
        let mode = try #require(check.options.first)

        #expect(check.options.count == 1)
        #expect(mode.key == "mode")
        #expect(mode.defaultValue == "MEDIUM")
        #expect(mode.choices == ["QUICK", "FAST", "MEDIUM", "EXTENDED", "CHANGED"])
        #expect(!mode.isToggle)
    }

    @Test("A MySQL target is backtick-quoted and qualified only when a schema is handed over")
    func mysqlStatements() {
        #expect(
            MySQLMaintenance.statements(
                operation: "OPTIMIZE TABLE", table: "orders", schema: nil, options: [:], flavor: .mysql
            ) == ["OPTIMIZE TABLE `orders`"]
        )
        #expect(
            MySQLMaintenance.statements(
                operation: "OPTIMIZE TABLE", table: "orders", schema: "shop", options: [:], flavor: .mysql
            ) == ["OPTIMIZE TABLE `shop`.`orders`"]
        )
        #expect(
            MySQLMaintenance.statements(
                operation: "CHECK TABLE", table: "orders", schema: nil, options: [:], flavor: .mysql
            ) == ["CHECK TABLE `orders` MEDIUM"]
        )
        #expect(
            MySQLMaintenance.statements(
                operation: "CHECK TABLE", table: "orders", schema: nil, options: ["mode": "EXTENDED"], flavor: .mysql
            ) == ["CHECK TABLE `orders` EXTENDED"]
        )
    }

    /// The mode lands in the statement text unquoted and reaches here from an MCP client as well as
    /// from the sheet's picker, so anything that is not a declared choice falls back to the default.
    @Test("A check mode outside the declared choices falls back to the default")
    func mysqlRejectsAnUndeclaredMode() {
        #expect(
            MySQLMaintenance.statements(
                operation: "CHECK TABLE",
                table: "orders",
                schema: nil,
                options: ["mode": "EXTENDED; DROP TABLE orders"],
                flavor: .mysql
            ) == ["CHECK TABLE `orders` MEDIUM"]
        )
    }

    @Test("A MySQL operation with no table produces nothing, because the engine has no such form")
    func mysqlNeedsATable() {
        #expect(MySQLMaintenance.operations.allSatisfy { $0.scope == .object })
        #expect(
            MySQLMaintenance.statements(
                operation: "ANALYZE TABLE", table: nil, schema: "shop", options: [:], flavor: .mysql
            ) == nil
        )
    }

    @Test("TiDB and Databend refuse an operation their flavor does not offer")
    func flavorGatesTheStatement() {
        for flavor in [MySQLServerFlavor.tidb(version: nil), .databend] {
            #expect(
                MySQLMaintenance.statements(
                    operation: "REPAIR TABLE", table: "orders", schema: nil, options: [:], flavor: flavor
                ) == nil
            )
            #expect(
                MySQLMaintenance.statements(
                    operation: "ANALYZE TABLE", table: "orders", schema: nil, options: [:], flavor: flavor
                ) != nil
            )
        }
    }

    // MARK: - Every declared option is read

    /// An option the descriptor declares that the statement builder never reads is the hardcoding bug
    /// in its other direction: the sheet would show a control that changes nothing.
    @Test("Every option a driver declares changes the statement it is declared on")
    func everyDeclaredOptionIsRead() throws {
        for operation in PostgreSQLMaintenance.operations {
            let base = try #require(postgresStatements(
                operation.name, table: "orders", schema: "app", options: operation.defaultOptionValues
            ))
            for option in operation.options {
                var changed = operation.defaultOptionValues
                changed[option.key] = try alternative(to: option)
                let result = try #require(postgresStatements(
                    operation.name, table: "orders", schema: "app", options: changed
                ))
                #expect(result != base, "\(operation.name) ignores its own '\(option.key)' option")
            }
        }

        for operation in MySQLMaintenance.operations {
            let base = try #require(MySQLMaintenance.statements(
                operation: operation.name,
                table: "orders",
                schema: nil,
                options: operation.defaultOptionValues,
                flavor: .mysql
            ))
            for option in operation.options {
                var changed = operation.defaultOptionValues
                changed[option.key] = try alternative(to: option)
                let result = try #require(MySQLMaintenance.statements(
                    operation: operation.name, table: "orders", schema: nil, options: changed, flavor: .mysql
                ))
                #expect(result != base, "\(operation.name) ignores its own '\(option.key)' option")
            }
        }
    }

    private func alternative(to option: PluginMaintenanceOption) throws -> String {
        guard let choices = option.choices else {
            return option.defaultValue == "true" ? "false" : "true"
        }
        return try #require(choices.first { $0 != option.defaultValue })
    }
}
