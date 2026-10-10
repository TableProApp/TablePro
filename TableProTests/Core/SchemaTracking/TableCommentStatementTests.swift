//
//  TableCommentStatementTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct CommentRequest: Equatable {
    let name: String
    let objectType: String
    let schema: String?
    let comment: String?
}

private final class CommentDDLDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let writesComments: Bool
    private(set) var commentRequests: [CommentRequest] = []

    init(writesComments: Bool = true) {
        self.writesComments = writesComments
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        commentRequests.append(CommentRequest(name: name, objectType: objectType, schema: schema, comment: comment))
        guard writesComments else { return nil }
        let value = comment.map { "'\($0)'" } ?? "NULL"
        return "COMMENT ON \(objectType) \(schema ?? "-").\(name) IS \(value)"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD COLUMN \(column.name)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(table) DROP COLUMN \(columnName)"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX \(index.name) ON \(table)"
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

struct TableCommentStatementTests {
    private func column(_ name: String) -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = name
        column.dataType = "INT"
        return column
    }

    private func index(_ name: String) -> EditableIndexDefinition {
        var index = EditableIndexDefinition.placeholder()
        index.name = name
        index.columns = ["total"]
        return index
    }

    @Test("The driver is asked with the table, the tab's schema, the object kind and the new comment")
    func passesTableSchemaKindAndComment() throws {
        let driver = CommentDDLDriver()
        let statements = try SchemaStatementGenerator(tableName: "orders", schema: "sales", pluginDriver: driver)
            .generate(changes: [.modifyTableComment(old: "Old", new: "Customer orders")])

        #expect(driver.commentRequests == [
            CommentRequest(name: "orders", objectType: "TABLE", schema: "sales", comment: "Customer orders")
        ])
        #expect(statements.map(\.sql) == ["COMMENT ON TABLE sales.orders IS 'Customer orders';"])
    }

    @Test("Removing the comment asks the driver for a nil comment")
    func removalPassesNil() throws {
        let driver = CommentDDLDriver()
        _ = try SchemaStatementGenerator(tableName: "orders", schema: "sales", pluginDriver: driver)
            .generate(changes: [.modifyTableComment(old: "Old", new: nil)])

        #expect(driver.commentRequests.map(\.comment) == [nil])
    }

    @Test("A view's structure asks for a VIEW comment")
    func viewPassesItsKind() throws {
        let driver = CommentDDLDriver()
        _ = try SchemaStatementGenerator(tableName: "recent", schema: "sales", objectType: .view, pluginDriver: driver)
            .generate(changes: [.modifyTableComment(old: nil, new: "Last 30 days")])

        #expect(driver.commentRequests.map(\.objectType) == ["VIEW"])
    }

    @Test("The comment runs after every structural statement, whatever order it was staged in")
    func commentRunsLast() throws {
        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: CommentDDLDriver())
            .generate(changes: [
                .modifyTableComment(old: nil, new: "Orders"),
                .addIndex(index("ix_total")),
                .addColumn(column("total")),
                .deleteColumn(column("legacy"))
            ])

        #expect(statements.count == 4)
        #expect(statements.last?.sql == "COMMENT ON TABLE -.orders IS 'Orders';")
        #expect(statements.filter { $0.setsComment }.count == 1)
    }

    @Test("A driver with no comment statement refuses the save as unsupported")
    func driverWithoutStatementThrows() {
        let generator = SchemaStatementGenerator(
            tableName: "orders", pluginDriver: CommentDDLDriver(writesComments: false)
        )
        do {
            _ = try generator.generate(changes: [.modifyTableComment(old: nil, new: "Orders")])
            Issue.record("Expected the save to be refused")
        } catch {
            #expect(error.localizedDescription.contains("Change comment on table"))
        }
    }

    @Test("A comment carries no operation for the driver's save-level review")
    func commentHasNoOperation() {
        let generator = SchemaStatementGenerator(tableName: "orders", pluginDriver: CommentDDLDriver())
        #expect(generator.orderedOperations(for: [.modifyTableComment(old: nil, new: "Orders")]).isEmpty)
        #expect(SchemaOperationRefusal.operations(for: .modifyTableComment(old: nil, new: "Orders")).isEmpty)
    }

    @Test("A comment change loses no data and needs no migration")
    func commentIsNotDestructive() throws {
        let change = SchemaChange.modifyTableComment(old: "Old", new: nil)
        #expect(!change.isDestructive)
        #expect(!change.requiresDataMigration)
        #expect(!change.isDelete)

        let statements = try SchemaStatementGenerator(tableName: "orders", pluginDriver: CommentDDLDriver())
            .generate(changes: [change])
        #expect(statements.allSatisfy { !$0.isDestructive && $0.setsComment })
    }

    @Test("Compare sync orders a comment change after every other change")
    func syncOrderingPutsCommentLast() {
        let sorted = SchemaChangeOrdering.sorted([
            .modifyTableComment(old: nil, new: "Orders"),
            .addColumn(column("total")),
            .addIndex(index("ix_total"))
        ])

        #expect(sorted.last == .modifyTableComment(old: nil, new: "Orders"))
    }
}
