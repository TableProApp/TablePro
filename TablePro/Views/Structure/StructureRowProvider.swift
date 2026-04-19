//
//  StructureRowProvider.swift
//  TablePro
//
//  Adapts structure entities (columns/indexes/FKs) to InMemoryRowProvider interface
//  Converts entity-based data to row-based format for DataGridView
//

import Foundation
import TableProPluginKit

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
    private let orderedColumnFields: [StructureColumnField]

    var rows: [[String?]] {
        switch tab {
        case .columns:
            return changeManager.workingColumns.map { column in
                orderedColumnFields.map { field -> String? in
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
            }
        case .indexes:
            return changeManager.workingIndexes.map { indexInfo in
                [
                    indexInfo.name,
                    indexInfo.columns.joined(separator: ", "),
                    indexInfo.type.rawValue,
                    indexInfo.isUnique ? "YES" : "NO"
                ]
            }
        case .foreignKeys:
            return changeManager.workingForeignKeys.map { fk in
                [
                    fk.name,
                    fk.columns.joined(separator: ", "),
                    fk.referencedTable,
                    fk.referencedColumns.joined(separator: ", "),
                    fk.onDelete.rawValue,
                    fk.onUpdate.rawValue
                ]
            }
        case .ddl, .parts:
            return []
        }
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
        rows.count
    }

    init(
        changeManager: StructureChangeManager,
        tab: StructureTab,
        databaseType: DatabaseType = .mysql,
        additionalFields: Set<StructureColumnField> = []
    ) {
        self.changeManager = changeManager
        self.tab = tab
        self.databaseType = databaseType
        self.additionalFields = additionalFields
        self.orderedColumnFields = Self.orderedFields(for: databaseType, additionalFields: additionalFields)
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
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    func updateValue(_ newValue: String?, at rowIndex: Int, columnIndex: Int) {
        // Updates are handled by the onCellEdit callback in TableStructureView
        // This method is called by DataGridView but we intercept edits earlier
    }

    func appendRow(_ row: [String?]) {
        // Handled by changeManager.addNewColumn/Index/ForeignKey
    }

    func removeRow(at index: Int) {
        // Handled by changeManager.deleteColumn/Index/ForeignKey
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
