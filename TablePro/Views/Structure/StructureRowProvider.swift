//
//  StructureRowProvider.swift
//  TablePro
//
//  Adapts structure entities (columns/indexes/FKs) to InMemoryRowProvider interface
//  Converts entity-based data to row-based format for DataGridView
//

import Foundation
import TableProPluginKit

/// Sort descriptor for structure grid columns
struct StructureSortDescriptor {
    let column: Int
    let ascending: Bool
}

/// Provides structure entities as rows for DataGridView
@MainActor
final class StructureRowProvider {
    private static let canonicalFieldOrder: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .primaryKey, .autoIncrement, .comment
    ]

    private let changeManager: StructureChangeManager
    private let tab: StructureTab
    private let databaseType: DatabaseType
    private let additionalFields: Set<StructureColumnField>
    let orderedColumnFields: [StructureColumnField]
    private let filterText: String?
    private let sortDescriptor: StructureSortDescriptor?

    private let cachedRows: [IndexedRow]

    var filteredToSourceMap: [Int] {
        cachedRows.map { $0.sourceIndex }
    }

    var rows: [[String?]] {
        cachedRows.map { $0.row }
    }

    var columns: [String] {
        switch tab {
        case .columns:
            return orderedColumnFields.map { $0.displayName }
        case .indexes:
            return [
                String(localized: "Name"),
                String(localized: "Columns"),
                String(localized: "Type"),
                String(localized: "Unique")
            ]
        case .foreignKeys:
            return [
                String(localized: "Name"),
                String(localized: "Columns"),
                String(localized: "Ref Table"),
                String(localized: "Ref Columns"),
                String(localized: "On Delete"),
                String(localized: "On Update")
            ]
        case .ddl, .parts:
            return []
        }
    }

    var columnTypes: [ColumnType] {
        Array(repeating: .text(rawType: nil), count: columns.count)
    }

    var dropdownColumns: Set<Int> {
        switch tab {
        case .columns:
            var result: Set<Int> = []
            if let i = orderedColumnFields.firstIndex(of: .nullable) { result.insert(i) }
            if let i = orderedColumnFields.firstIndex(of: .primaryKey) { result.insert(i) }
            if let i = orderedColumnFields.firstIndex(of: .autoIncrement) { result.insert(i) }
            return result
        case .indexes:
            return [3]
        case .foreignKeys:
            return []
        case .ddl, .parts:
            return []
        }
    }

    /// Custom dropdown options for specific columns (non-YES/NO dropdowns)
    var customDropdownOptions: [Int: [String]] {
        switch tab {
        case .foreignKeys:
            let actions = EditableForeignKeyDefinition.ReferentialAction.allCases.map(\.rawValue)
            return [4: actions, 5: actions]
        case .indexes:
            let types = EditableIndexDefinition.IndexType.allCases.map(\.rawValue)
            return [2: types]
        case .columns, .ddl, .parts:
            return [:]
        }
    }

    var typePickerColumns: Set<Int> {
        switch tab {
        case .columns:
            if let i = orderedColumnFields.firstIndex(of: .type) { return [i] }
            return []
        case .indexes, .foreignKeys, .ddl, .parts:
            return []
        }
    }

    var totalRowCount: Int {
        cachedRows.count
    }

    init(
        changeManager: StructureChangeManager,
        tab: StructureTab,
        databaseType: DatabaseType = .mysql,
        additionalFields: Set<StructureColumnField> = [],
        filterText: String? = nil,
        sortDescriptor: StructureSortDescriptor? = nil
    ) {
        self.changeManager = changeManager
        self.tab = tab
        self.databaseType = databaseType
        self.additionalFields = additionalFields
        self.filterText = filterText
        self.sortDescriptor = sortDescriptor
        self.orderedColumnFields = Self.orderedFields(for: databaseType, additionalFields: additionalFields)

        let allRows = Self.buildAllRows(
            tab: tab, changeManager: changeManager, orderedColumnFields: self.orderedColumnFields
        )
        self.cachedRows = Self.applyFilterAndSort(
            allRows, filterText: filterText, sortDescriptor: sortDescriptor
        )
    }

    static func orderedFields(
        for databaseType: DatabaseType,
        additionalFields: Set<StructureColumnField> = []
    ) -> [StructureColumnField] {
        let pluginFields = Set(PluginManager.shared.structureColumnFields(for: databaseType))
        let fields = pluginFields.union(additionalFields)
        return canonicalFieldOrder.filter { fields.contains($0) }
    }

    // MARK: - InMemoryRowProvider-compatible methods

    func row(at index: Int) -> [String?]? {
        guard index >= 0, index < cachedRows.count else { return nil }
        return cachedRows[index].row
    }

    func updateValue(_ newValue: String?, at rowIndex: Int, columnIndex: Int) {
        // Updates are handled by the onCellEdit callback in TableStructureView
    }

    func appendRow(_ row: [String?]) {
        // Handled by changeManager.addNewColumn/Index/ForeignKey
    }

    func removeRow(at index: Int) {
        // Handled by changeManager.deleteColumn/Index/ForeignKey
    }

    // MARK: - Private Helpers

    private struct IndexedRow {
        let sourceIndex: Int
        let row: [String?]
    }

    private static func buildAllRows(
        tab: StructureTab,
        changeManager: StructureChangeManager,
        orderedColumnFields: [StructureColumnField]
    ) -> [IndexedRow] {
        switch tab {
        case .columns:
            return changeManager.workingColumns.enumerated().map { index, column in
                let row = orderedColumnFields.map { field -> String? in
                    switch field {
                    case .name: column.name
                    case .type: column.dataType
                    case .nullable: column.isNullable ? "YES" : "NO"
                    case .defaultValue: column.defaultValue ?? ""
                    case .primaryKey: column.isPrimaryKey ? "YES" : "NO"
                    case .autoIncrement: column.autoIncrement ? "YES" : "NO"
                    case .comment: column.comment ?? ""
                    }
                }
                return IndexedRow(sourceIndex: index, row: row)
            }
        case .indexes:
            return changeManager.workingIndexes.enumerated().map { index, indexInfo in
                IndexedRow(sourceIndex: index, row: [
                    indexInfo.name,
                    indexInfo.columns.joined(separator: ", "),
                    indexInfo.type.rawValue,
                    indexInfo.isUnique ? "YES" : "NO"
                ])
            }
        case .foreignKeys:
            return changeManager.workingForeignKeys.enumerated().map { index, fk in
                IndexedRow(sourceIndex: index, row: [
                    fk.name,
                    fk.columns.joined(separator: ", "),
                    fk.referencedTable,
                    fk.referencedColumns.joined(separator: ", "),
                    fk.onDelete.rawValue,
                    fk.onUpdate.rawValue
                ])
            }
        case .ddl, .parts:
            return []
        }
    }

    private static func applyFilterAndSort(
        _ rows: [IndexedRow],
        filterText: String?,
        sortDescriptor: StructureSortDescriptor?
    ) -> [IndexedRow] {
        var result = rows

        if let filterText, !filterText.isEmpty {
            result = result.filter { indexed in
                guard let name = indexed.row.first ?? nil else { return false }
                return name.localizedCaseInsensitiveContains(filterText)
            }
        }

        if let sortDescriptor, sortDescriptor.column >= 0 {
            result.sort { a, b in
                let aVal = (sortDescriptor.column < a.row.count ? a.row[sortDescriptor.column] : nil) ?? ""
                let bVal = (sortDescriptor.column < b.row.count ? b.row[sortDescriptor.column] : nil) ?? ""
                let comparison = aVal.localizedStandardCompare(bVal)
                return sortDescriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }

        return result
    }
}

// MARK: - Helper to create InMemoryRowProvider

extension StructureRowProvider {
    /// Creates an InMemoryRowProvider from structure data
    func asInMemoryProvider() -> InMemoryRowProvider {
        InMemoryRowProvider(
            rows: rows,
            columns: columns,
            columnTypes: columnTypes
        )
    }
}
