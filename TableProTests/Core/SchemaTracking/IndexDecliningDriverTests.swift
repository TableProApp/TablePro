//
//  IndexDecliningDriverTests.swift
//  TableProTests
//
//  What the structure editor does with a driver that writes no statement for an index row, the way
//  the ClickHouse driver declines every one (ClickHouseDriverTests pins that): it says so rather than
//  running half a change.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class IndexDecliningDriver: PluginDriverStub, @unchecked Sendable {
    func quoteIdentifier(_ name: String) -> String { "`\(name)`" }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? { nil }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP INDEX \(quoteIdentifier(indexName))"
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        let columns = definition.columns.map { "\(quoteIdentifier($0.name)) \($0.dataType)" }
        return "CREATE TABLE \(quoteIdentifier(definition.tableName)) (\(columns.joined(separator: ", ")))"
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

struct IndexDecliningDriverTests {
    /// Before, the rename ran `DROP INDEX` and then an `ADD INDEX … TYPE BTREE` the server refuses, and
    /// ClickHouse has no transaction to undo the drop.
    @Test("Renaming an index the driver cannot write stops before its DROP INDEX is built")
    func renameStopsBeforeTheDrop() {
        let read = EditableIndexDefinition.from(IndexInfo(
            name: "ix_user", columns: ["user_id"], isUnique: false, isPrimary: false, type: "DATA_SKIPPING"
        ))
        var renamed = read
        renamed.name = "ix_user_id"
        let generator = SchemaStatementGenerator(tableName: "events", pluginDriver: IndexDecliningDriver())

        #expect(throws: (any Error).self) {
            try generator.generate(changes: [.modifyIndex(old: read, new: renamed)])
        }
    }

    /// The issue used to say the database "does not create indexes with a statement", while the
    /// ClickHouse docs send the reader to `ALTER TABLE … ADD INDEX`, which is one.
    @Test("Create Table creates the table and says it cannot add the index")
    @MainActor
    func createTableNamesTheIndexItCannotAdd() {
        let plan = CreateTablePlan(
            definition: PluginCreateTableDefinition(
                tableName: "events",
                columns: [PluginColumnDefinition(name: "user_id", dataType: "UInt64", isNullable: false)],
                primaryKeyColumns: []
            ),
            indexes: [PluginIndexDefinition(name: "ix_user", columns: ["user_id"], indexType: "BTREE")],
            issues: []
        )

        let composed = CreateTableStatementComposer.compose(plan: plan, driver: IndexDecliningDriver(), schema: nil)

        #expect(composed.statements.count == 1)
        #expect(composed.issues.map(\.message) == ["Create Table cannot add an index on this database."])
        #expect(composed.issues.first?.tab == .indexes)
        #expect(composed.issues.first?.row == 0)
    }
}
