//
//  StructureGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate implementation for TableStructureView and CreateTableView.
//

import AppKit
import SwiftUI
import TableProPluginKit

@MainActor
final class StructureGridDelegate: DataGridViewDelegate {
    let structureChangeManager: StructureChangeManager
    var selectedTab: StructureTab
    let connection: DatabaseConnection
    let tableName: String
    weak var coordinator: MainContentCoordinator?
    var selectedRows: Binding<Set<Int>>?

    // Column reorder callback (set externally by the view when conditions allow)
    var moveRowHandler: ((Int, Int) -> Void)?

    init(
        structureChangeManager: StructureChangeManager,
        selectedTab: StructureTab,
        connection: DatabaseConnection,
        tableName: String,
        coordinator: MainContentCoordinator?
    ) {
        self.structureChangeManager = structureChangeManager
        self.selectedTab = selectedTab
        self.connection = connection
        self.tableName = tableName
        self.coordinator = coordinator
    }

    // MARK: - DataGridViewDelegate

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        guard column >= 0 else { return }

        switch selectedTab {
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

        case .ddl, .parts:
            break
        }
    }

    func dataGridDeleteRows(_ rows: Set<Int>) {
        let minRow = rows.min() ?? 0
        let maxRow = rows.max() ?? 0

        switch selectedTab {
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
        case .parts, .ddl:
            selectedRows?.wrappedValue.removeAll()
            return
        }

        let newCount: Int
        switch selectedTab {
        case .columns: newCount = structureChangeManager.workingColumns.count
        case .indexes: newCount = structureChangeManager.workingIndexes.count
        case .foreignKeys: newCount = structureChangeManager.workingForeignKeys.count
        case .ddl, .parts: newCount = 0
        }

        if newCount > 0 {
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

    func dataGridCopyRows(_ indices: Set<Int>) {
        guard selectedTab != .ddl, selectedTab != .parts, !indices.isEmpty else { return }

        var copiedItems: [Any] = []

        switch selectedTab {
        case .columns:
            for row in indices.sorted() {
                guard row < structureChangeManager.workingColumns.count else { continue }
                copiedItems.append(structureChangeManager.workingColumns[row])
            }
        case .indexes:
            for row in indices.sorted() {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                copiedItems.append(structureChangeManager.workingIndexes[row])
            }
        case .foreignKeys:
            for row in indices.sorted() {
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                copiedItems.append(structureChangeManager.workingForeignKeys[row])
            }
        case .ddl, .parts:
            break
        }

        guard !copiedItems.isEmpty else { return }

        var jsonString: String?
        if let columns = copiedItems as? [EditableColumnDefinition],
           let encoded = try? JSONEncoder().encode(columns) {
            jsonString = String(data: encoded, encoding: .utf8)
        } else if let indexes = copiedItems as? [EditableIndexDefinition],
                  let encoded = try? JSONEncoder().encode(indexes) {
            jsonString = String(data: encoded, encoding: .utf8)
        } else if let fks = copiedItems as? [EditableForeignKeyDefinition],
                  let encoded = try? JSONEncoder().encode(fks) {
            jsonString = String(data: encoded, encoding: .utf8)
        }

        let provider = StructureRowProvider(
            changeManager: structureChangeManager, tab: selectedTab, databaseType: connection.type
        )
        var lines: [String] = []
        for row in indices.sorted() {
            guard let rowData = provider.row(at: row) else { continue }
            let line = rowData.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }
        let tsvString = lines.joined(separator: "\n")

        let item = NSPasteboardItem()
        if let json = jsonString {
            item.setString(json, forType: TableStructureView.structurePasteboardType)
        }
        if !tsvString.isEmpty {
            item.setString(tsvString, forType: .string)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func dataGridPasteRows() {
        guard let data = NSPasteboard.general.data(forType: TableStructureView.structurePasteboardType),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        let decoder = JSONDecoder()

        switch selectedTab {
        case .columns:
            guard let columns = try? decoder.decode([EditableColumnDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in columns {
                let newColumn = EditableColumnDefinition(
                    id: UUID(),
                    name: item.name,
                    dataType: item.dataType,
                    isNullable: item.isNullable,
                    defaultValue: item.defaultValue,
                    autoIncrement: item.autoIncrement,
                    unsigned: item.unsigned,
                    comment: item.comment,
                    collation: item.collation,
                    onUpdate: item.onUpdate,
                    charset: item.charset,
                    extra: item.extra,
                    isPrimaryKey: item.isPrimaryKey
                )
                structureChangeManager.addColumn(newColumn)
            }

        case .indexes:
            guard let indexes = try? decoder.decode([EditableIndexDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in indexes {
                let newIndex = EditableIndexDefinition(
                    id: UUID(),
                    name: item.name,
                    columns: item.columns,
                    type: item.type,
                    isUnique: item.isUnique,
                    isPrimary: item.isPrimary,
                    comment: item.comment
                )
                structureChangeManager.addIndex(newIndex)
            }

        case .foreignKeys:
            guard let fks = try? decoder.decode([EditableForeignKeyDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in fks {
                let newFK = EditableForeignKeyDefinition(
                    id: UUID(),
                    name: item.name,
                    columns: item.columns,
                    referencedTable: item.referencedTable,
                    referencedColumns: item.referencedColumns,
                    onDelete: item.onDelete,
                    onUpdate: item.onUpdate
                )
                structureChangeManager.addForeignKey(newFK)
            }

        case .ddl, .parts:
            break
        }
    }

    func dataGridUndo() {
        guard selectedTab != .ddl else { return }
        structureChangeManager.undo()
    }

    func dataGridRedo() {
        guard selectedTab != .ddl else { return }
        structureChangeManager.redo()
    }

    func dataGridAddRow() {
        switch selectedTab {
        case .columns:
            structureChangeManager.addNewColumn()
        case .indexes:
            structureChangeManager.addNewIndex()
        case .foreignKeys:
            structureChangeManager.addNewForeignKey()
        case .ddl, .parts:
            break
        }
    }

    func dataGridMoveRow(from source: Int, to destination: Int) {
        moveRowHandler?(source, destination)
    }

    func dataGridVisualState(forRow row: Int) -> RowVisualState? {
        structureChangeManager.getVisualState(for: row, tab: selectedTab)
    }

    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView? {
        makeStructureRowView(tableView, row, coordinator)
    }

    func dataGridEmptySpaceMenu() -> NSMenu? {
        makeEmptySpaceMenu()
    }

    // MARK: - Row View & Context Menu

    private static let structureRowViewId = NSUserInterfaceItemIdentifier("StructureRowView")

    private func makeStructureRowView(
        _ tableView: NSTableView, _ row: Int, _ coordinator: TableViewCoordinator
    ) -> NSTableRowView {
        let rowView = (tableView.makeView(withIdentifier: Self.structureRowViewId, owner: nil)
            as? StructureRowViewWithMenu) ?? StructureRowViewWithMenu()
        rowView.identifier = Self.structureRowViewId
        rowView.coordinator = coordinator
        rowView.rowIndex = row
        rowView.structureTab = selectedTab
        rowView.isStructureEditable = connection.type.supportsSchemaEditing
        rowView.isRowDeleted = structureChangeManager.getVisualState(for: row, tab: selectedTab).isDeleted

        if selectedTab == .foreignKeys, row < structureChangeManager.workingForeignKeys.count {
            rowView.referencedTableName = structureChangeManager.workingForeignKeys[row].referencedTable
        }

        rowView.onCopyName = { [weak self] indices in self?.handleCopyName(indices) }
        rowView.onCopyDefinition = { [weak self] indices in self?.handleCopyDefinition(indices) }
        rowView.onNavigateFK = { [weak self] idx in self?.handleNavigateToFK(idx) }
        rowView.onDuplicate = { [weak self] indices in self?.handleDuplicateItems(indices) }
        rowView.onDelete = { [weak self] indices in self?.dataGridDeleteRows(indices) }
        rowView.onUndoDelete = { [weak self] _ in self?.dataGridUndo() }
        return rowView
    }

    private func makeEmptySpaceMenu() -> NSMenu? {
        guard selectedTab != .ddl, selectedTab != .parts else { return nil }
        guard connection.type.supportsSchemaEditing else { return nil }

        let menu = NSMenu()
        let label: String
        switch selectedTab {
        case .columns: label = String(localized: "Add Column")
        case .indexes: label = String(localized: "Add Index")
        case .foreignKeys: label = String(localized: "Add Foreign Key")
        case .ddl, .parts: return nil
        }

        let target = StructureMenuTarget { [weak self] in self?.dataGridAddRow() }
        let item = NSMenuItem(title: label, action: #selector(StructureMenuTarget.addNewItem), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        menu.addItem(item)
        return menu
    }

    // MARK: - Context Menu Helpers

    private func handleCopyName(_ indices: Set<Int>) {
        let provider = StructureRowProvider(
            changeManager: structureChangeManager, tab: selectedTab, databaseType: connection.type
        )
        let names = indices.sorted().compactMap { provider.row(at: $0)?.first ?? nil }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    private func handleCopyDefinition(_ indices: Set<Int>) {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }
        var definitions: [String] = []

        for row in indices.sorted() {
            switch selectedTab {
            case .columns:
                guard row < structureChangeManager.workingColumns.count else { continue }
                let col = structureChangeManager.workingColumns[row]
                if let sql = driver.generateColumnDefinitionSQL(column: col.toPlugin()) {
                    definitions.append(sql)
                }
            case .indexes:
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let idx = structureChangeManager.workingIndexes[row]
                if let sql = driver.generateIndexDefinitionSQL(index: idx.toPlugin(), tableName: tableName) {
                    definitions.append(sql)
                }
            case .foreignKeys:
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let fk = structureChangeManager.workingForeignKeys[row]
                if let sql = driver.generateForeignKeyDefinitionSQL(fk: fk.toPlugin()) {
                    definitions.append(sql)
                }
            case .ddl, .parts:
                break
            }
        }

        guard !definitions.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(definitions.joined(separator: "\n"), forType: .string)
    }

    private func handleDuplicateItems(_ indices: Set<Int>) {
        for row in indices.sorted() {
            switch selectedTab {
            case .columns:
                guard row < structureChangeManager.workingColumns.count else { continue }
                let copy = structureChangeManager.workingColumns[row]
                structureChangeManager.addColumn(EditableColumnDefinition(
                    id: UUID(), name: copy.name, dataType: copy.dataType, isNullable: copy.isNullable,
                    defaultValue: copy.defaultValue, autoIncrement: copy.autoIncrement, unsigned: copy.unsigned,
                    comment: copy.comment, collation: copy.collation, onUpdate: copy.onUpdate,
                    charset: copy.charset, extra: copy.extra, isPrimaryKey: copy.isPrimaryKey
                ))
            case .indexes:
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let copy = structureChangeManager.workingIndexes[row]
                structureChangeManager.addIndex(EditableIndexDefinition(
                    id: UUID(), name: copy.name, columns: copy.columns,
                    type: copy.type, isUnique: copy.isUnique, isPrimary: false, comment: copy.comment
                ))
            case .foreignKeys:
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let copy = structureChangeManager.workingForeignKeys[row]
                structureChangeManager.addForeignKey(EditableForeignKeyDefinition(
                    id: UUID(), name: copy.name, columns: copy.columns,
                    referencedTable: copy.referencedTable, referencedColumns: copy.referencedColumns,
                    onDelete: copy.onDelete, onUpdate: copy.onUpdate
                ))
            case .ddl, .parts:
                break
            }
        }
    }

    private func handleNavigateToFK(_ row: Int) {
        guard row < structureChangeManager.workingForeignKeys.count else { return }
        let fk = structureChangeManager.workingForeignKeys[row]
        coordinator?.openTableTab(fk.referencedTable, showStructure: false, isView: false)
    }

    // MARK: - Column/Index/FK Update Helpers

    private func updateColumn(_ column: inout EditableColumnDefinition, at index: Int, with value: String) {
        if connection.type == .clickhouse {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.comment = value.isEmpty ? nil : value
            default: break
            }
        } else {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.autoIncrement = value.uppercased() == "YES" || value == "1"
            case 5: column.comment = value.isEmpty ? nil : value
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
