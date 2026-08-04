//
//  StructureRowProvider.swift
//  TablePro
//
//  Adapts structure entities (columns/indexes/FKs) to TableRows for DataGridView
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
        .name, .type, .nullable, .defaultValue, .onUpdate, .primaryKey, .autoIncrement,
        .comment, .charset, .collation
    ]

    private static let booleanFields: [StructureColumnField] = [
        .nullable, .primaryKey, .autoIncrement, .onUpdate
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
                String(localized: "Unique"),
                String(localized: "Condition")
            ]
        case .foreignKeys:
            return [
                String(localized: "Name"),
                String(localized: "Columns"),
                String(localized: "Ref Table"),
                String(localized: "Ref Columns"),
                String(localized: "Ref Schema"),
                String(localized: "On Delete"),
                String(localized: "On Update")
            ]
        case .ddl, .parts, .triggers:
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
            for field in Self.booleanFields {
                guard let index = orderedColumnFields.firstIndex(of: field) else { continue }
                result.insert(index)
            }
            return result
        case .indexes:
            return [3]
        case .foreignKeys:
            return []
        case .ddl, .parts, .triggers:
            return []
        }
    }

    /// Explicit option lists for every dropdown column, keyed by column index.
    /// Structure flags are schema properties, not data values, so they always offer
    /// the same YES/NO pair the grid displays and never a NULL option.
    var customDropdownOptions: [Int: [String]] {
        switch tab {
        case .foreignKeys:
            let actions = EditableForeignKeyDefinition.ReferentialAction.allCases.map(\.rawValue)
            return [5: actions, 6: actions]
        case .indexes:
            let types = EditableIndexDefinition.IndexType.allCases.map(\.rawValue)
            return [2: types, 3: Self.booleanOptions]
        case .columns:
            var result: [Int: [String]] = [:]
            for field in Self.booleanFields {
                guard let index = orderedColumnFields.firstIndex(of: field) else { continue }
                result[index] = Self.booleanOptions
            }
            return result
        case .ddl, .parts, .triggers:
            return [:]
        }
    }

    static let booleanOptions = ["YES", "NO"]

    var typePickerColumns: Set<Int> {
        switch tab {
        case .columns:
            if let i = orderedColumnFields.firstIndex(of: .type) { return [i] }
            return []
        case .indexes, .foreignKeys, .ddl, .parts, .triggers:
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

    // MARK: - Row Access

    func row(at index: Int) -> [String?]? {
        guard index >= 0, index < cachedRows.count else { return nil }
        return cachedRows[index].row
    }

    func sourceIndex(atDisplay displayRow: Int) -> Int? {
        guard displayRow >= 0, displayRow < cachedRows.count else { return nil }
        return cachedRows[displayRow].sourceIndex
    }

    /// Fields whose working value differs from the value the schema was loaded with.
    /// An entity that does not exist on the server yet has nothing to compare against,
    /// so it reports no modified fields and the grid's inserted-row tint carries that state.
    func modifiedFieldIndices(atDisplay displayRow: Int) -> Set<Int> {
        guard let sourceIndex = sourceIndex(atDisplay: displayRow),
              let working = row(at: displayRow),
              let original = originalRow(atSource: sourceIndex) else { return [] }
        return Set(working.indices.filter { index in
            let originalValue = index < original.count ? original[index] : nil
            return working[index] != originalValue
        })
    }

    func isPendingDelete(atDisplay displayRow: Int) -> Bool {
        guard let sourceIndex = sourceIndex(atDisplay: displayRow) else { return false }
        return changeManager.deleteInsertState(for: sourceIndex, tab: tab).isDeleted
    }

    private func originalRow(atSource sourceIndex: Int) -> [String?]? {
        switch tab {
        case .columns:
            guard sourceIndex < changeManager.workingColumns.count else { return nil }
            let id = changeManager.workingColumns[sourceIndex].id
            guard let original = changeManager.currentColumns.first(where: { $0.id == id }) else { return nil }
            return Self.row(for: original, orderedColumnFields: orderedColumnFields)
        case .indexes:
            guard sourceIndex < changeManager.workingIndexes.count else { return nil }
            let id = changeManager.workingIndexes[sourceIndex].id
            guard let original = changeManager.currentIndexes.first(where: { $0.id == id }) else { return nil }
            return Self.row(for: original)
        case .foreignKeys:
            guard sourceIndex < changeManager.workingForeignKeys.count else { return nil }
            let id = changeManager.workingForeignKeys[sourceIndex].id
            guard let original = changeManager.currentForeignKeys.first(where: { $0.id == id }) else { return nil }
            return Self.row(for: original)
        case .ddl, .parts, .triggers:
            return nil
        }
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
                IndexedRow(sourceIndex: index, row: row(for: column, orderedColumnFields: orderedColumnFields))
            }
        case .indexes:
            return changeManager.workingIndexes.enumerated().map { index, indexInfo in
                IndexedRow(sourceIndex: index, row: row(for: indexInfo))
            }
        case .foreignKeys:
            return changeManager.workingForeignKeys.enumerated().map { index, fk in
                IndexedRow(sourceIndex: index, row: row(for: fk))
            }
        case .ddl, .parts, .triggers:
            return []
        }
    }

    private static func row(
        for column: EditableColumnDefinition,
        orderedColumnFields: [StructureColumnField]
    ) -> [String?] {
        orderedColumnFields.map { field -> String? in
            switch field {
            case .name: column.name
            case .type: column.dataType
            case .nullable: column.isNullable ? "YES" : "NO"
            case .defaultValue: column.defaultValue ?? ""
            case .onUpdate: column.onUpdate != nil ? "YES" : "NO"
            case .primaryKey: column.isPrimaryKey ? "YES" : "NO"
            case .autoIncrement: column.autoIncrement ? "YES" : "NO"
            case .comment: column.comment ?? ""
            case .charset: column.charset ?? ""
            case .collation: column.collation ?? ""
            @unknown default: nil
            }
        }
    }

    private static func row(for index: EditableIndexDefinition) -> [String?] {
        let columnsStr = index.columns.map { col in
            if let prefix = index.columnPrefixes[col] {
                return "\(col)(\(prefix))"
            }
            return col
        }.joined(separator: ", ")
        return [
            index.name,
            columnsStr,
            index.type.rawValue,
            index.isUnique ? "YES" : "NO",
            index.whereClause ?? ""
        ]
    }

    private static func row(for fk: EditableForeignKeyDefinition) -> [String?] {
        [
            fk.name,
            fk.columns.joined(separator: ", "),
            fk.referencedTable,
            fk.referencedColumns.joined(separator: ", "),
            fk.referencedSchema ?? "",
            fk.onDelete.rawValue,
            fk.onUpdate.rawValue
        ]
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

// MARK: - Helper to create TableRows

extension StructureRowProvider {
    /// Creates a TableRows snapshot from structure data
    func asTableRows() -> TableRows {
        let typedRows = rows.map { row in row.map(PluginCellValue.fromOptional) }
        return TableRows.from(
            queryRows: typedRows,
            columns: columns,
            columnTypes: columnTypes,
            columnNullable: Dictionary(uniqueKeysWithValues: columns.map { ($0, false) })
        )
    }
}
