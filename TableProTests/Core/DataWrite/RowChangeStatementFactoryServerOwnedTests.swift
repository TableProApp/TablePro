//
//  RowChangeStatementFactoryServerOwnedTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ContextRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    private(set) var context: PluginRowWriteContext?
    private(set) var insertedRowData: [Int: [PluginCellValue]] = [:]
    private(set) var restoredColumns: [String] = []
    private(set) var restoredRows: [[PluginCellValue]] = []
    var preservesIdentity = false

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        guard preservesIdentity else { return nil }
        restoredColumns = columns
        restoredRows = rows
        return [(statement: "RESTORE", parameters: [])]
    }

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        self.context = context
        self.insertedRowData = insertedRowData
        return [PluginRowWrite(statement: "WRITE", rowIndices: changes.map(\.rowIndex))]
    }

    func quoteIdentifier(_ name: String) -> String { "[\(name)]" }
    func connect() async throws {}
    func disconnect() {}
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
struct RowChangeStatementFactoryServerOwnedTests {
    private let columns = ["ID", "Name", "Doubled"]

    private func factory(
        databaseType: DatabaseType = .mssql,
        schemaName: String? = "dbo",
        primaryKeyColumns: [String] = ["ID"],
        generatedColumns: Set<String> = ["ID", "Doubled"],
        rowMatchPolicy: RowMatchPolicy = .none,
        driver: (any PluginDatabaseDriver)? = nil,
        identityColumns: Set<String>? = ["ID"]
    ) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "Ord",
            schemaName: schemaName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            generatedColumns: generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            databaseType: databaseType,
            pluginDriver: driver,
            identityColumns: identityColumns
        )
    }

    private func edit(_ column: String, at index: Int) -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: index, columnName: column, oldValue: "1761", newValue: "1890")],
            originalRow: ["1761", "a", "3522"]
        )
    }

    @Test
    func anEditToAServerOwnedColumnIsRefusedWithTheColumnNamed() {
        let driver = ContextRecordingDriver()
        do {
            _ = try factory(driver: driver).statements(for: [edit("ID", at: 0)])
            Issue.record("An edit to an IDENTITY column was sent")
        } catch let DataWriteError.changeRefused(table, kind, reason) {
            #expect(table == "Ord")
            #expect(kind == .update)
            #expect(reason.contains("ID"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(driver.context == nil)
    }

    @Test
    func anEditToAnOrdinaryColumnReachesTheDriverWithTheContext() throws {
        let driver = ContextRecordingDriver()
        let policy = RowMatchPolicy(excludedColumns: ["Shape"], textColumns: ["Notes"])
        _ = try factory(rowMatchPolicy: policy, driver: driver).statements(for: [edit("Name", at: 1)])
        let context = try #require(driver.context)
        #expect(context.serverOwnedColumns == ["ID", "Doubled"])
        #expect(context.rowMatchExcludedColumns == ["Shape"])
        #expect(context.rowMatchTextColumns == ["Notes"])
    }

    @Test
    func aNewRowLeavesEveryServerOwnedColumnToTheServer() throws {
        let driver = ContextRecordingDriver()
        let rowID = RowID.inserted(UUID())
        let insert = RowChange(rowID: rowID, type: .insert, cellChanges: [], originalRow: nil)
        _ = try factory(driver: driver).statements(
            for: [insert], insertedRowData: [rowID: ["99", "b", "198"]], insertedRowIDs: [rowID]
        )
        #expect(driver.insertedRowData.values.first == [.text("__DEFAULT__"), .text("b"), .text("__DEFAULT__")])
    }

    @Test
    func aSQLServerRestoreWritesTheIdentityBackInsideIdentityInsert() throws {
        let restored = try factory().restoreStatements(rows: [["5", "a", "10"]])
        #expect(restored.prologue == ["SET IDENTITY_INSERT [dbo].[Ord] ON"])
        #expect(restored.epilogue == ["SET IDENTITY_INSERT [dbo].[Ord] OFF"])
        let sql = try #require(restored.statements.first?.sql)
        #expect(sql.hasPrefix("INSERT INTO [dbo].[Ord] ([ID], [Name]) VALUES ("))
        #expect(!sql.contains("Doubled"))
    }

    @Test
    func aPostgreSQLRestoreOverridesTheSystemValue() throws {
        let restored = try factory(databaseType: .postgresql, schemaName: "sales").restoreStatements(
            rows: [["5", "a", "10"]]
        )
        #expect(restored.prologue.isEmpty)
        let sql = try #require(restored.statements.first?.sql)
        #expect(sql.contains("OVERRIDING SYSTEM VALUE VALUES"))
        #expect(sql.contains("\"sales\".\"Ord\""))
    }

    @Test
    func anEngineWithNoExplicitIdentityFormRefusesTheRestore() {
        #expect(throws: DataWriteError.self) {
            _ = try factory(databaseType: .oracle).restoreStatements(rows: [["5", "a", "10"]])
        }
    }

    @Test
    func aRecordThatNeverSaidWhichColumnsAreIdentityRefusesAGeneratedKey() {
        #expect(throws: DataWriteError.self) {
            _ = try factory(identityColumns: nil).restoreStatements(rows: [["5", "a", "10"]])
        }
    }

    @Test
    func aRecordThatNeverSaidWhichColumnsAreIdentityRefusesAGeneratedColumnBesideANaturalKey() {
        #expect(throws: DataWriteError.self) {
            _ = try factory(primaryKeyColumns: ["Name"], identityColumns: nil).restoreStatements(rows: [["5", "a", "10"]])
        }
    }

    @Test
    func aRecordThatNeverSaidWhichColumnsAreIdentityRestoresATableWithNoGeneratedColumn() throws {
        let restored = try factory(generatedColumns: [], identityColumns: nil).restoreStatements(rows: [["5", "a", "10"]])
        #expect(restored.statements.count == 1)
    }

    @Test
    func aDriverThatRestoresItsOwnRowsIsHandedTheIdentityButNotTheComputedColumns() throws {
        let driver = ContextRecordingDriver()
        driver.preservesIdentity = true
        let restored = try factory(databaseType: DatabaseType(rawValue: "Spanner"), driver: driver)
            .restoreStatements(rows: [["5", "a", "10"]])
        #expect(restored.statements.map(\.sql) == ["RESTORE"])
        #expect(driver.restoredColumns == ["ID", "Name"])
        #expect(driver.restoredRows == [["5", "a"]])
    }

    @Test
    func aRestoreWithNoIdentityLeavesComputedColumnsOutAndNeedsNoSession() throws {
        let restored = try factory(generatedColumns: ["Doubled"], identityColumns: []).restoreStatements(
            rows: [["5", "a", "10"]]
        )
        #expect(restored.prologue.isEmpty)
        #expect(restored.epilogue.isEmpty)
        #expect(restored.statements.first?.sql.contains("Doubled") == false)
    }
}
