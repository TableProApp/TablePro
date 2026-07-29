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

    @Test("Normalizing a preselected table with empty option values applies plugin defaults")
    func normalizedMaterializesDefaultsForPreselectedTable() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true)
        let normalized = table.normalized(forOptionColumnCount: 3, defaultOptionValues: [true, true, true])
        #expect(normalized.optionValues == [true, true, true])
        #expect(normalized.isSelected)
    }

    @Test("Normalizing preserves a partial option selection")
    func normalizedPreservesPartialSelection() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true, optionValues: [true, false, true])
        let normalized = table.normalized(forOptionColumnCount: 3, defaultOptionValues: [true, true, true])
        #expect(normalized.optionValues == [true, false, true])
    }

    @Test("Normalizing a selected table with all-false option values re-applies defaults")
    func normalizedRepairsAllFalseSelection() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true, optionValues: [false, false, false])
        let normalized = table.normalized(forOptionColumnCount: 3, defaultOptionValues: [true, true, true])
        #expect(normalized.optionValues == [true, true, true])
    }

    @Test("Normalizing an unselected table with all-false option values leaves them alone")
    func normalizedLeavesUnselectedAllFalseAlone() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: false, optionValues: [false, false, false])
        let normalized = table.normalized(forOptionColumnCount: 3, defaultOptionValues: [true, true, true])
        #expect(normalized.optionValues == [false, false, false])
    }

    @Test("Normalizing an unselected table with empty option values still fixes the shape")
    func normalizedFixesShapeForUnselectedTable() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: false)
        let normalized = table.normalized(forOptionColumnCount: 3, defaultOptionValues: [true, true, true])
        #expect(normalized.optionValues.count == 3)
    }

    @Test("Normalizing with zero option columns leaves option values untouched")
    func normalizedNoOpForFormatsWithoutOptionColumns() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true)
        let normalized = table.normalized(forOptionColumnCount: 0, defaultOptionValues: [])
        #expect(normalized.optionValues.isEmpty)
    }

    @Test("Normalizing falls back to all-true when plugin defaults have the wrong length")
    func normalizedFallsBackWhenDefaultsMismatched() {
        let table = ExportTableItem(name: "users", type: .table, isSelected: true)
        let normalized = table.normalized(forOptionColumnCount: 3, defaultOptionValues: [true])
        #expect(normalized.optionValues == [true, true, true])
    }

    @Test("Normalizing database items materializes every preselected table and preserves identity")
    func normalizingDatabaseItemsMatchesPreselectionFlow() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true),
            ExportTableItem(name: "posts", type: .table, isSelected: true),
            ExportTableItem(name: "logs", type: .table, isSelected: false),
        ]
        let original = [ExportDatabaseItem(name: "app_db", tables: tables)]
        let normalized = original.normalizingOptionValues(optionColumnCount: 3, defaultOptionValues: [true, true, true])
        #expect(normalized[0].id == original[0].id)
        #expect(normalized[0].tables[0].id == original[0].tables[0].id)
        let preselected = normalized[0].tables.filter(\.isSelected)
        #expect(preselected.count == 2)
        #expect(preselected.allSatisfy { $0.optionValues.contains(true) })
    }

    @Test("Resetting option values overwrites every table regardless of prior content")
    func resettingOptionValuesOverwritesAll() {
        let tables = [
            ExportTableItem(name: "users", type: .table, isSelected: true, optionValues: [true, false, true]),
            ExportTableItem(name: "posts", type: .table, isSelected: false, optionValues: [false, false, false]),
        ]
        let original = [ExportDatabaseItem(name: "app_db", tables: tables)]
        let reset = original.resettingOptionValues(to: [true, true, true])
        #expect(reset[0].tables.allSatisfy { $0.optionValues == [true, true, true] })
    }
}
