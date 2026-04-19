//
//  CreateTableGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate implementation for CreateTableView.
//  Differs from StructureGridDelegate in column mapping (includes PrimaryKey field).
//

import AppKit
import SwiftUI
import TableProPluginKit

@MainActor
final class CreateTableGridDelegate: DataGridViewDelegate {
    let structureChangeManager: StructureChangeManager
    var structureTab: StructureTab
    let connection: DatabaseConnection
    var selectedRows: Binding<Set<Int>>?

    init(
        structureChangeManager: StructureChangeManager,
        structureTab: StructureTab,
        connection: DatabaseConnection
    ) {
        self.structureChangeManager = structureChangeManager
        self.structureTab = structureTab
        self.connection = connection
    }

    // MARK: - DataGridViewDelegate

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        guard column >= 0 else { return }

        switch structureTab {
        case .columns:
            guard row < structureChangeManager.workingColumns.count else { return }
            var col = structureChangeManager.workingColumns[row]
            updateColumn(&col, at: column, with: newValue ?? "")
            structureChangeManager.updateColumn(id: col.id, with: col)

        case .indexes:
            guard row < structureChangeManager.workingIndexes.count else { return }
            var idx = structureChangeManager.workingIndexes[row]
            updateIndex(&idx, at: column, with: newValue ?? "")
            structureChangeManager.updateIndex(id: idx.id, with: idx)

        case .foreignKeys:
            guard row < structureChangeManager.workingForeignKeys.count else { return }
            var fk = structureChangeManager.workingForeignKeys[row]
            updateForeignKey(&fk, at: column, with: newValue ?? "")
            structureChangeManager.updateForeignKey(id: fk.id, with: fk)

        default:
            break
        }
    }

    func dataGridDeleteRows(_ rows: Set<Int>) {
        switch structureTab {
        case .columns:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingColumns.count else { continue }
                let column = structureChangeManager.workingColumns[row]
                structureChangeManager.deleteColumn(id: column.id)
            }
        case .indexes:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let index = structureChangeManager.workingIndexes[row]
                structureChangeManager.deleteIndex(id: index.id)
            }
        case .foreignKeys:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let fk = structureChangeManager.workingForeignKeys[row]
                structureChangeManager.deleteForeignKey(id: fk.id)
            }
        default:
            break
        }

        let newCount: Int
        switch structureTab {
        case .columns: newCount = structureChangeManager.workingColumns.count
        case .indexes: newCount = structureChangeManager.workingIndexes.count
        case .foreignKeys: newCount = structureChangeManager.workingForeignKeys.count
        default: newCount = 0
        }

        if newCount > 0 {
            let maxRow = rows.max() ?? 0
            let minRow = rows.min() ?? 0
            if maxRow < newCount {
                selectedRows?.wrappedValue = [maxRow]
            } else if minRow > 0 {
                selectedRows?.wrappedValue = [minRow - 1]
            } else {
                selectedRows?.wrappedValue = [0]
            }
        } else {
            selectedRows?.wrappedValue.removeAll()
        }
    }

    func dataGridUndo() {
        structureChangeManager.undo()
    }

    func dataGridRedo() {
        structureChangeManager.redo()
    }

    func dataGridAddRow() {
        switch structureTab {
        case .columns:
            structureChangeManager.addNewColumn()
        case .indexes:
            structureChangeManager.addNewIndex()
        case .foreignKeys:
            structureChangeManager.addNewForeignKey()
        default:
            break
        }
    }

    // MARK: - Column Mapping (includes PrimaryKey field)

    private func updateColumn(_ column: inout EditableColumnDefinition, at index: Int, with value: String) {
        if connection.type == .clickhouse {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.isPrimaryKey = value.uppercased() == "YES" || value == "1"
            case 5: column.comment = value.isEmpty ? nil : value
            default: break
            }
        } else {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.isPrimaryKey = value.uppercased() == "YES" || value == "1"
            case 5: column.autoIncrement = value.uppercased() == "YES" || value == "1"
            case 6: column.comment = value.isEmpty ? nil : value
            default: break
            }
        }
    }

    private func updateIndex(_ index: inout EditableIndexDefinition, at colIndex: Int, with value: String) {
        switch colIndex {
        case 0: index.name = value
        case 1: index.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2:
            if let indexType = EditableIndexDefinition.IndexType(rawValue: value.uppercased()) {
                index.type = indexType
            }
        case 3: index.isUnique = value.uppercased() == "YES" || value == "1"
        default: break
        }
    }

    private func updateForeignKey(_ fk: inout EditableForeignKeyDefinition, at index: Int, with value: String) {
        switch index {
        case 0: fk.name = value
        case 1: fk.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2: fk.referencedTable = value
        case 3: fk.referencedColumns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 4:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onDelete = action
            }
        case 5:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onUpdate = action
            }
        default: break
        }
    }
}
