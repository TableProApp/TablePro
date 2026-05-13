//
//  ExportModelsTests.swift
//  TableProTests
//
//  Created on 2026-02-17.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Export Models")
struct ExportModelsTests {

    @MainActor @Test("Export configuration default format is csv")
    func exportConfigurationDefaultFormat() {
        let config = ExportConfiguration()
        #expect(config.formatId == "csv")
    }

    @MainActor @Test("Export configuration default file name")
    func exportConfigurationDefaultFileName() {
        let config = ExportConfiguration()
        #expect(config.fileName == "export")
    }

    @Test("Export database item selected count with no tables")
    func exportDatabaseItemNoTables() {
        let item = ExportDatabaseItem(name: "testdb", tables: [])
        #expect(item.selectedCount == 0)
        #expect(item.allSelected == false)
        #expect(item.noneSelected == true)
    }

    @Test("Export database item selected count with all selected")
    func exportDatabaseItemAllSelected() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: true),
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        #expect(item.selectedCount == 2)
        #expect(item.allSelected == true)
        #expect(item.noneSelected == false)
    }

    @Test("Export database item selected count with partial selection")
    func exportDatabaseItemPartialSelection() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: false),
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        #expect(item.selectedCount == 1)
        #expect(item.allSelected == false)
        #expect(item.noneSelected == false)
    }

    @Test("Export database item selected count with none selected")
    func exportDatabaseItemNoneSelected() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: false),
            ExportTableItem(name: "posts", type: .table, isSelected: false),
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        #expect(item.selectedCount == 0)
        #expect(item.allSelected == false)
        #expect(item.noneSelected == true)
    }

    @Test("Export database item selected tables")
    func exportDatabaseItemSelectedTables() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: false),
            ExportTableItem(name: "comments", type: .table, isSelected: true),
        ]
        let item = ExportDatabaseItem(name: "testdb", tables: tables)
        let selectedTables = item.selectedTables
        #expect(selectedTables.count == 2)
        #expect(selectedTables.map(\.name) == ["users", "comments"])
    }

    @Test("Export table item qualified name without database name")
    func exportTableItemQualifiedNameWithoutDatabase() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true)
        #expect(table.qualifiedName == "users")
    }

    @Test("Export table item qualified name with database name")
    func exportTableItemQualifiedNameWithDatabase() {
        let table = ExportTableItem(name: "users", databaseName: "mydb", type: .table, isSelected: true)
        #expect(table.qualifiedName == "mydb.users")
    }

    @Test("Export table item option values default to empty")
    func exportTableItemOptionValuesDefault() {
        let table = ExportTableItem(name: "users", type: .table)
        #expect(table.optionValues.isEmpty)
    }

    @Test("Export table item with option values")
    func exportTableItemWithOptionValues() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true, optionValues: [true, false, true])
        #expect(table.optionValues == [true, false, true])
    }
}
