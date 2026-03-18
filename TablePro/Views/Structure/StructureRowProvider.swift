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
        .name, .type, .nullable, .defaultValue, .autoIncrement, .comment
    ]

    private let changeManager: StructureChangeManager
    private let tab: StructureTab
    private let databaseType: DatabaseType

    // Computed properties that match InMemoryRowProvider interface
    var rows: [QueryResultRow] {
        switch tab {
        case .columns:
            let fields = PluginManager.shared.structureColumnFields(for: databaseType)
            let ordered = Self.canonicalFieldOrder.filter { fields.contains($0) }
            return changeManager.workingColumns.enumerated().map { index, column in
                let values: [String] = ordered.map { field in
                    switch field {
                    case .name: column.name
                    case .type: column.dataType
                    case .nullable: column.isNullable ? "YES" : "NO"
                    case .defaultValue: column.defaultValue ?? ""
                    case .autoIncrement: column.autoIncrement ? "YES" : "NO"
                    case .comment: column.comment ?? ""
                    }
                }
                return QueryResultRow(id: index, values: values)
            }
        case .indexes:
            return changeManager.workingIndexes.enumerated().map { index, indexInfo in
                QueryResultRow(id: index, values: [
                    indexInfo.name,
                    indexInfo.columns.joined(separator: ", "),
                    indexInfo.type.rawValue,
                    indexInfo.isUnique ? "YES" : "NO"
                ])
            }
        case .foreignKeys:
            return changeManager.workingForeignKeys.enumerated().map { index, fk in
                QueryResultRow(id: index, values: [
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

    var columns: [String] {
        switch tab {
        case .columns:
            let fields = PluginManager.shared.structureColumnFields(for: databaseType)
            let ordered = Self.canonicalFieldOrder.filter { fields.contains($0) }
            return ordered.map { $0.displayName }
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
        // All columns are text for structure editing
        Array(repeating: .text(rawType: nil), count: columns.count)
    }

    /// Column indices that should use YES/NO dropdowns instead of text fields
    var dropdownColumns: Set<Int> {
        switch tab {
        case .columns:
            let fields = PluginManager.shared.structureColumnFields(for: databaseType)
            let ordered = Self.canonicalFieldOrder.filter { fields.contains($0) }
            var result: Set<Int> = []
            if let i = ordered.firstIndex(of: .nullable) { result.insert(i) }
            if let i = ordered.firstIndex(of: .autoIncrement) { result.insert(i) }
            return result
        case .indexes:
            return [3] // Unique (index 3)
        case .foreignKeys:
            return [] // On Delete/Update use text for now (could add dropdown for CASCADE/SET NULL/etc later)
        case .ddl, .parts:
            return []
        }
    }

    /// Column indices that should use the type picker popover
    var typePickerColumns: Set<Int> {
        switch tab {
        case .columns:
            let fields = PluginManager.shared.structureColumnFields(for: databaseType)
            let ordered = Self.canonicalFieldOrder.filter { fields.contains($0) }
            if let i = ordered.firstIndex(of: .type) { return [i] }
            return []
        case .indexes, .foreignKeys, .ddl, .parts:
            return []
        }
    }

    var totalRowCount: Int {
        rows.count
    }

    init(changeManager: StructureChangeManager, tab: StructureTab, databaseType: DatabaseType = .mysql) {
        self.changeManager = changeManager
        self.tab = tab
        self.databaseType = databaseType
    }

    // MARK: - InMemoryRowProvider-compatible methods

    func row(at index: Int) -> QueryResultRow? {
        guard index < rows.count else { return nil }
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
