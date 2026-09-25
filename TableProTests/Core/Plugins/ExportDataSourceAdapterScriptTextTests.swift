//
//  ExportDataSourceAdapterScriptTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ScriptTextStubDriver: PluginDatabaseDriver, @unchecked Sendable {
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
}

struct ExportDataSourceAdapterScriptTextTests {
    private func adapter(for type: DatabaseType) -> ExportDataSourceAdapter {
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: type), pluginDriver: ScriptTextStubDriver()
        )
        return ExportDataSourceAdapter(driver: driver, databaseType: type)
    }

    /// The same text a saved Compare & Sync script gets, so a dump and a sync script run the same
    /// way in the engine's own client.
    @Test("A dump writes each definition the way the engine's client ends it")
    func definitionsFollowTheEngine() {
        let unit = "CREATE OR REPLACE PROCEDURE P IS BEGIN NULL; END;"
        #expect(adapter(for: .oracle).scriptText(for: unit) == "\(unit)\n/")
        #expect(adapter(for: .oracle).scriptText(for: "DROP TRIGGER \"T\"") == "DROP TRIGGER \"T\";")

        let routine = "CREATE PROCEDURE p() BEGIN SELECT 1; END"
        #expect(adapter(for: .mysql).scriptText(for: routine) == "DELIMITER //\n\(routine) //\nDELIMITER ;")

        #expect(adapter(for: .postgresql).scriptText(for: "CREATE VIEW v AS SELECT 1") == "CREATE VIEW v AS SELECT 1;")
    }
}
