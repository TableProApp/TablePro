//
//  CreateTableCommentCompositionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CreateCommentDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let writesComments: Bool
    private let createStatements: [String]?

    init(writesComments: Bool = true, createStatements: [String]? = nil) {
        self.writesComments = writesComments
        self.createStatements = createStatements
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName) (...)"
    }

    func generateCreateTableStatements(definition: PluginCreateTableDefinition) -> [String]? {
        createStatements ?? generateCreateTableSQL(definition: definition).map { [$0] }
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX \(index.name) ON \(table)"
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        guard writesComments else { return nil }
        return "COMMENT ON \(objectType) \(schema ?? "-").\(name) IS '\(comment ?? "")'"
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

@MainActor
struct CreateTableCommentCompositionTests {
    private func plan(comment: String?, indexes: [PluginIndexDefinition] = []) -> CreateTablePlan {
        CreateTablePlan(
            definition: PluginCreateTableDefinition(
                tableName: "orders",
                columns: [PluginColumnDefinition(name: "id", dataType: "INT")],
                primaryKeyColumns: []
            ),
            indexes: indexes,
            issues: [],
            tableComment: comment
        )
    }

    @Test("The comment follows the CREATE and every index, and names the schema and TABLE")
    func commentRunsLast() {
        let composed = CreateTableStatementComposer.compose(
            plan: plan(comment: "Customer orders", indexes: [PluginIndexDefinition(name: "ix_id", columns: ["id"])]),
            driver: CreateCommentDriver(),
            schema: "sales"
        )

        #expect(composed.statements == [
            "CREATE TABLE orders (...)",
            "CREATE INDEX ix_id ON orders",
            "COMMENT ON TABLE sales.orders IS 'Customer orders'"
        ])
        #expect(composed.issues.isEmpty)
    }

    @Test("A draft with no comment writes no comment statement")
    func noCommentNoStatement() {
        let composed = CreateTableStatementComposer.compose(
            plan: plan(comment: nil), driver: CreateCommentDriver(), schema: "sales"
        )

        #expect(composed.statements == ["CREATE TABLE orders (...)"])
        #expect(composed.issues.isEmpty)
    }

    @Test("A driver that cannot write the comment blocks Create instead of dropping it")
    func missingStatementBlocksCreate() {
        let composed = CreateTableStatementComposer.compose(
            plan: plan(comment: "Customer orders"), driver: CreateCommentDriver(writesComments: false), schema: nil
        )

        #expect(composed.issues.map(\.message) == ["This database cannot store a table comment."])
        #expect(composed.issues.first?.tab == .columns)
    }

    @Test("Every statement the driver creates the table with arrives in order, ahead of the indexes")
    func multiStatementCreateKeepsItsOrder() {
        let driver = CreateCommentDriver(createStatements: [
            "CREATE SEQUENCE orders_id_seq",
            "CREATE TABLE orders (...)",
            "COMMENT ON COLUMN orders.id IS 'key'"
        ])
        let composed = CreateTableStatementComposer.compose(
            plan: plan(comment: nil, indexes: [PluginIndexDefinition(name: "ix_id", columns: ["id"])]),
            driver: driver,
            schema: nil
        )

        #expect(composed.statements == [
            "CREATE SEQUENCE orders_id_seq",
            "CREATE TABLE orders (...)",
            "COMMENT ON COLUMN orders.id IS 'key'",
            "CREATE INDEX ix_id ON orders"
        ])
    }

    @Test("A driver that returns no create statements reports it cannot create the table")
    func emptyCreateIsRefused() {
        let composed = CreateTableStatementComposer.compose(
            plan: plan(comment: nil), driver: CreateCommentDriver(createStatements: []), schema: nil
        )

        #expect(composed.statements.isEmpty)
        #expect(composed.issues.map(\.message) == ["This database cannot create a table from the visual editor."])
    }
}
