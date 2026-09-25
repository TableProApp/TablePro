//
//  PluginCreateTableStatementsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SingleStringDDLDriver: PluginDatabaseDriver, @unchecked Sendable {
    let createTableSQL: String?

    init(createTableSQL: String?) {
        self.createTableSQL = createTableSQL
    }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult { .empty }
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

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        createTableSQL
    }
}

struct PluginCreateTableStatementsTests {
    private let definition = PluginCreateTableDefinition(
        tableName: "t",
        columns: [
            PluginColumnDefinition(
                name: "a", dataType: "INT", isNullable: true, defaultValue: nil, isPrimaryKey: false,
                autoIncrement: false, comment: nil, unsigned: false, onUpdate: nil, charset: nil, collation: nil
            )
        ],
        primaryKeyColumns: []
    )

    /// A driver built before the requirement existed, or one whose DDL is one statement, keeps being
    /// sent the one string it writes.
    @Test("A driver that writes one string is sent that string whole")
    func defaultIsTheSingleString() {
        let ddl = "CREATE TABLE t (a INT);\n\nCREATE INDEX i ON t (a);"
        #expect(SingleStringDDLDriver(createTableSQL: ddl).generateCreateTableStatements(definition: definition) == [ddl])
        #expect(SingleStringDDLDriver(createTableSQL: nil).generateCreateTableStatements(definition: definition) == nil)
    }
}
