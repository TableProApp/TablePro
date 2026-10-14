// Maintenance used to be a list of bare operation names, so the app offered every one of them on
// every object: PostgreSQL skips a VACUUM on a view with a WARNING and still reports the success
// command tag VACUUM, and refuses a REINDEX on one outright. The kind sets below are what
// PostgreSQL 17.11 actually answered.

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLMaintenanceOperationTests {
    private static let current = PostgreSQLCapabilities(serverVersion: 170_011)

    private func postgres(
        _ name: String,
        capabilities: PostgreSQLCapabilities = current
    ) throws -> PluginMaintenanceOperation {
        try #require(PostgreSQLMaintenance.operations(capabilities: capabilities).first { $0.name == name })
    }

    private func postgresStatements(
        _ operation: String,
        table: String?,
        schema: String?,
        options: [String: String] = [:],
        serverVersion: Int32 = 170_011
    ) -> [String]? {
        PostgreSQLMaintenance.statements(
            operation: operation,
            table: table,
            schema: schema,
            options: options,
            connectedDatabase: "app",
            capabilities: PostgreSQLCapabilities(serverVersion: serverVersion)
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
        #expect(PostgreSQLMaintenance.operations(capabilities: Self.current).allSatisfy { !$0.applies(to: .view) })
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

    @Test("REINDEX offers VERBOSE only from PostgreSQL 9.5, and VACUUM keeps its own")
    func reindexVerboseIsOfferedFrom95() throws {
        let before = PostgreSQLCapabilities(serverVersion: 90_400)
        let from = PostgreSQLCapabilities(serverVersion: 90_500)
        #expect(try postgres("REINDEX", capabilities: before).options.isEmpty)
        #expect(try postgres("REINDEX", capabilities: from).options.map(\.key) == ["verbose"])
        #expect(try postgres("VACUUM", capabilities: before).options.map(\.key).contains("verbose"))
    }

    @Test("REINDEX writes no option list before PostgreSQL 9.5, where it does not parse")
    func reindexVerboseNeedsAnOptionList() {
        #expect(
            postgresStatements(
                "REINDEX", table: "orders", schema: "app", options: ["verbose": "true"], serverVersion: 90_400
            ) == ["REINDEX TABLE \"app\".\"orders\""]
        )
        #expect(
            postgresStatements("REINDEX", table: nil, schema: "app", options: ["verbose": "true"], serverVersion: 90_400)
                == ["REINDEX DATABASE \"app\""]
        )
    }

    @Test("REINDEX of the whole database keeps the VERBOSE it offers")
    func reindexDatabaseVerbose() {
        #expect(
            postgresStatements("REINDEX", table: nil, schema: "app", options: ["verbose": "true"])
                == ["REINDEX (VERBOSE) DATABASE CONCURRENTLY"]
        )
        #expect(
            postgresStatements("REINDEX", table: nil, schema: "app", options: ["verbose": "true"], serverVersion: 90_500)
                == ["REINDEX (VERBOSE) DATABASE \"app\""]
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

    /// An option the descriptor declares that the statement builder never reads is the hardcoding bug
    /// in its other direction: the sheet would show a control that changes nothing.
    @Test("Every option PostgreSQL declares changes the statement it is declared on")
    func everyDeclaredOptionIsRead() throws {
        for operation in PostgreSQLMaintenance.operations(capabilities: Self.current) {
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
    }

    private func alternative(to option: PluginMaintenanceOption) throws -> String {
        guard let choices = option.choices else {
            return option.defaultValue == "true" ? "false" : "true"
        }
        return try #require(choices.first { $0 != option.defaultValue })
    }
}
