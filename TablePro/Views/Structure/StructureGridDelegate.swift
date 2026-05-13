//
//  StructureGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate implementation for TableStructureView and CreateTableView.
//

import AppKit
import TableProPluginKit

@MainActor
final class StructureGridDelegate: DataGridViewDelegate {
    let structureChangeManager: StructureChangeManager
    var selectedTab: StructureTab
    let connection: DatabaseConnection
    let tableName: String
    weak var coordinator: MainContentCoordinator?
    var onSelectedRowsChanged: ((Set<Int>) -> Void)?

    // Column reorder callback (set externally by the view when conditions allow)
    var moveRowHandler: ((Int, Int) -> Void)?

    // Sort callback (set by TableStructureView to update its @State)
    var sortHandler: ((Int, Bool) -> Void)?

    // Current provider for index translation (set each render by the view)
    var currentProvider: StructureRowProvider?

    // Ordered fields for column editing (updated when currentProvider is set)
    var orderedFields: [StructureColumnField] = []

    // Stored when DataGridView calls `dataGridAttach(tableViewCoordinator:)` on
    // every updateNSView. Lets us tell `NSTableView` which rows to reload after
    // an edit / soft-delete / undo so the displayed cell value and visual-state
    // tint stay in sync with the change manager. Without this, edits inside a
    // row that does not change the row count never trigger `reloadData` because
    // the SwiftUI re-render only invalidates layout-affecting properties.
    private weak var attachedCoordinator: TableViewCoordinator?

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

    // MARK: - Index Translation

    private func sourceRow(for displayRow: Int) -> Int {
        guard let provider = currentProvider,
              provider.filteredToSourceMap.indices.contains(displayRow) else {
            return displayRow
        }
        return provider.filteredToSourceMap[displayRow]
    }

    private func sourceRows(for displayRows: Set<Int>) -> Set<Int> {
        Set(displayRows.map { sourceRow(for: $0) })
    }

    // MARK: - DataGridViewDelegate

    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        attachedCoordinator = tableViewCoordinator
    }

    func dataGridDidEditCell(row displayRow: Int, column: Int, newValue: String?) {
        guard column >= 0 else { return }
        let sourceRowIndex = sourceRow(for: displayRow)

        switch selectedTab {
        case .columns:
            guard sourceRowIndex < structureChangeManager.workingColumns.count else { return }
            var col = structureChangeManager.workingColumns[sourceRowIndex]
            StructureEditingSupport.updateColumn(&col, at: column, with: newValue ?? "", orderedFields: orderedFields)
            structureChangeManager.updateColumn(id: col.id, with: col)

        case .indexes:
            guard sourceRowIndex < structureChangeManager.workingIndexes.count else { return }
            var idx = structureChangeManager.workingIndexes[sourceRowIndex]
            StructureEditingSupport.updateIndex(&idx, at: column, with: newValue ?? "")
            structureChangeManager.updateIndex(id: idx.id, with: idx)

        case .foreignKeys:
            guard sourceRowIndex < structureChangeManager.workingForeignKeys.count else { return }
            var fk = structureChangeManager.workingForeignKeys[sourceRowIndex]
            StructureEditingSupport.updateForeignKey(&fk, at: column, with: newValue ?? "")
            structureChangeManager.updateForeignKey(id: fk.id, with: fk)

        case .ddl, .parts:
            break
        }

        // Standard NSTableView contract after a data-source mutation: tell the
        // table view which row to redraw so the cell shows the new value AND
        // the modified-row visual state tint takes effect. The SwiftUI re-render
        // alone is not enough because `updateNSView` only triggers `reloadData`
        // when the row count or column schema changes.
        reloadDisplayRow(displayRow)
    }

    private func reloadDisplayRow(_ displayRow: Int) {
        attachedCoordinator?.reloadRowAndState(at: displayRow)
    }

    /// Repaint every visible cell + row view from the current change-manager
    /// state. `TableStructureView` calls this after save/discard, since those
    /// reset working state outside the delegate without changing row count, so
    /// `DataGridView.updateNSView` would otherwise leave cells and tints stale.
    /// Forwards to the shared `TableViewCoordinator` primitive so data tab and
    /// structure tab use the same Apple-blessed two-layer refresh
    /// (`reloadData(forRowIndexes:)` + `enumerateAvailableRowViews`).
    func reloadAllVisibleRows() {
        attachedCoordinator?.reloadVisibleRowsAndStates()
    }

    func dataGridDeleteRows(_ rows: Set<Int>) {
        let translated = sourceRows(for: rows)
        let minRow = rows.min() ?? 0
        let maxRow = rows.max() ?? 0

        switch selectedTab {
        case .columns:
            guard connection.type.supportsDropColumn else { return }
            for row in translated.sorted(by: >) {
                guard row < structureChangeManager.workingColumns.count else { continue }
                let column = structureChangeManager.workingColumns[row]
                structureChangeManager.deleteColumn(id: column.id)
            }
        case .indexes:
            guard connection.type.supportsDropIndex else { return }
            for row in translated.sorted(by: >) {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let index = structureChangeManager.workingIndexes[row]
                structureChangeManager.deleteIndex(id: index.id)
            }
        case .foreignKeys:
            guard connection.type.supportsForeignKeys else { return }
            for row in translated.sorted(by: >) {
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let fk = structureChangeManager.workingForeignKeys[row]
                structureChangeManager.deleteForeignKey(id: fk.id)
            }
        case .parts, .ddl:
            onSelectedRowsChanged?([])
            return
        }

        let displayCount = (currentProvider?.totalRowCount ?? 0) - rows.count
        if displayCount > 0 {
            if maxRow < displayCount {
                onSelectedRowsChanged?([maxRow])
            } else if minRow > 0 {
                onSelectedRowsChanged?([minRow - 1])
            } else {
                onSelectedRowsChanged?([0])
            }
        } else {
            onSelectedRowsChanged?([])
        }

        // Existing-column deletes leave the row in `workingColumns` and only
        // mark it as `pendingChanges[.deleteColumn]`, so the row count is
        // unchanged. Without a forced reload the row's deleted-state tint and
        // text color never paint on the live row view.
        reloadAllVisibleRows()
    }

    func dataGridCopyRows(_ indices: Set<Int>) {
        guard selectedTab != .ddl, selectedTab != .parts, !indices.isEmpty else { return }
        let translated = sourceRows(for: indices)

        var copiedItems: [Any] = []

        switch selectedTab {
        case .columns:
            for row in translated.sorted() {
                guard row < structureChangeManager.workingColumns.count else { continue }
                copiedItems.append(structureChangeManager.workingColumns[row])
            }
        case .indexes:
            for row in translated.sorted() {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                copiedItems.append(structureChangeManager.workingIndexes[row])
            }
        case .foreignKeys:
            for row in translated.sorted() {
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

        let displayProvider = currentProvider ?? StructureRowProvider(
            changeManager: structureChangeManager, tab: selectedTab, databaseType: connection.type
        )
        var lines: [String] = []
        for row in indices.sorted() {
            guard let rowData = displayProvider.row(at: row) else { continue }
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
                    comment: item.comment,
                    columnPrefixes: item.columnPrefixes,
                    whereClause: item.whereClause
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
                    referencedSchema: item.referencedSchema,
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
        // Undo can revert any row's content and visual state. The SwiftUI
        // re-render driven by `reloadVersion` only invalidates the snapshot;
        // ask `NSTableView` to redraw visible rows so the cell text and
        // modified-tint actually update on screen.
        reloadAllVisibleRows()
    }

    func dataGridRedo() {
        guard selectedTab != .ddl else { return }
        structureChangeManager.redo()
        reloadAllVisibleRows()
    }

    func dataGridAddRow() {
        switch selectedTab {
        case .columns:
            guard connection.type.supportsAddColumn else { return }
            structureChangeManager.addNewColumn()
        case .indexes:
            guard connection.type.supportsAddIndex else { return }
            structureChangeManager.addNewIndex()
        case .foreignKeys:
            guard connection.type.supportsForeignKeys else { return }
            structureChangeManager.addNewForeignKey()
        case .ddl, .parts:
            break
        }
    }

    func dataGridSortStateChanged(_ state: SortState) {
        guard let primary = state.columns.first else {
            sortHandler?(-1, true)
            return
        }
        sortHandler?(primary.columnIndex, primary.direction == .ascending)
    }

    func dataGridMoveRow(from source: Int, to destination: Int) {
        moveRowHandler?(source, destination)
    }

    func dataGridVisualState(forRow row: Int) -> RowVisualState? {
        let src = sourceRow(for: row)
        let (isDeleted, isInserted) = structureChangeManager.deleteInsertState(for: src, tab: selectedTab)
        let modified = isDeleted || isInserted ? [] : modifiedColumns(at: src)
        return RowVisualState(isDeleted: isDeleted, isInserted: isInserted, modifiedColumns: modified)
    }

    /// Diff the working entity against the original (`currentColumns` etc.) to
    /// find which display columns the user actually edited. Returning a real
    /// per-cell set lets the cell view tint only the touched cells, mirroring
    /// the data tab's behavior, instead of flagging the whole row when one
    /// field changed.
    private func modifiedColumns(at sourceRow: Int) -> Set<Int> {
        switch selectedTab {
        case .columns:
            guard sourceRow < structureChangeManager.workingColumns.count else { return [] }
            let working = structureChangeManager.workingColumns[sourceRow]
            guard let original = structureChangeManager.currentColumns.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.columnModifiedIndices(
                old: original, new: working, orderedFields: orderedFields
            )
        case .indexes:
            guard sourceRow < structureChangeManager.workingIndexes.count else { return [] }
            let working = structureChangeManager.workingIndexes[sourceRow]
            guard let original = structureChangeManager.currentIndexes.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.indexModifiedIndices(old: original, new: working)
        case .foreignKeys:
            guard sourceRow < structureChangeManager.workingForeignKeys.count else { return [] }
            let working = structureChangeManager.workingForeignKeys[sourceRow]
            guard let original = structureChangeManager.currentForeignKeys.first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.foreignKeyModifiedIndices(old: original, new: working)
        case .ddl, .parts:
            return []
        }
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

        let src = sourceRow(for: row)
        // Don't set `isDeleted` / visual state here. `DataGridView+Columns`
        // calls `applyVisualState(visualState(for: row))` on every row view it
        // returns from `tableView(_:rowViewForRow:)`. Setting it twice is a
        // smell that previously hid the bug: when `applyVisualState` was a
        // tint-only setter, this line was the only place the menu's
        // `isDeleted` flag was assigned, and it was assigned only on row-view
        // creation. Single source of truth now is `DataGridRowView.visualState`.

        if selectedTab == .foreignKeys, src < structureChangeManager.workingForeignKeys.count {
            rowView.referencedTableName = structureChangeManager.workingForeignKeys[src].referencedTable
        }

        rowView.onCopyName = { [weak self] indices in
            guard let self else { return }
            self.handleCopyName(self.sourceRows(for: indices))
        }
        rowView.onCopyDefinition = { [weak self] indices in
            guard let self else { return }
            self.handleCopyDefinition(self.sourceRows(for: indices))
        }
        rowView.onCopyAsCSV = { [weak self] indices in
            guard let self else { return }
            self.handleCopyAsCSV(self.sourceRows(for: indices))
        }
        rowView.onCopyAsJSON = { [weak self] indices in
            guard let self else { return }
            self.handleCopyAsJSON(self.sourceRows(for: indices))
        }
        rowView.onNavigateFK = { [weak self] idx in
            guard let self else { return }
            self.handleNavigateToFK(self.sourceRow(for: idx))
        }
        rowView.onDuplicate = { [weak self] indices in
            guard let self else { return }
            self.handleDuplicateItems(self.sourceRows(for: indices))
        }
        rowView.onDelete = { [weak self] indices in self?.dataGridDeleteRows(indices) }
        rowView.onUndoDelete = { [weak self] displayRow in
            guard let self else { return }
            let src = self.sourceRow(for: displayRow)
            self.structureChangeManager.undoDelete(for: self.selectedTab, at: src)
            self.attachedCoordinator?.reloadRowAndState(at: displayRow)
        }
        return rowView
    }

    private func makeEmptySpaceMenu() -> NSMenu? {
        guard selectedTab != .ddl, selectedTab != .parts else { return nil }
        guard connection.type.supportsSchemaEditing else { return nil }

        let menu = NSMenu()
        let label: String
        switch selectedTab {
        case .columns:
            guard connection.type.supportsAddColumn else { return nil }
            label = String(localized: "Add Column")
        case .indexes:
            guard connection.type.supportsAddIndex else { return nil }
            label = String(localized: "Add Index")
        case .foreignKeys:
            guard connection.type.supportsForeignKeys else { return nil }
            label = String(localized: "Add Foreign Key")
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

    // MARK: - Copy As CSV/JSON

    private func handleCopyAsCSV(_ indices: Set<Int>) {
        let provider = StructureRowProvider(
            changeManager: structureChangeManager, tab: selectedTab,
            databaseType: connection.type, additionalFields: [.primaryKey]
        )
        let headers = provider.columns
        guard !headers.isEmpty else { return }

        var lines: [String] = [headers.map { escapeCSVField($0) }.joined(separator: ",")]
        for row in indices.sorted() {
            guard let rowData = provider.row(at: row) else { continue }
            let line = rowData.map { escapeCSVField($0 ?? "") }.joined(separator: ",")
            lines.append(line)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func escapeCSVField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func handleCopyAsJSON(_ indices: Set<Int>) {
        let provider = StructureRowProvider(
            changeManager: structureChangeManager, tab: selectedTab,
            databaseType: connection.type, additionalFields: [.primaryKey]
        )
        let headers = provider.columns
        guard !headers.isEmpty else { return }

        var objects: [[String: String]] = []
        for row in indices.sorted() {
            guard let rowData = provider.row(at: row) else { continue }
            var obj: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < rowData.count {
                obj[header] = rowData[i] ?? ""
            }
            objects.append(obj)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .sortedKeys]
        ), let jsonString = String(data: data, encoding: .utf8) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(jsonString, forType: .string)
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
                    type: copy.type, isUnique: copy.isUnique, isPrimary: false, comment: copy.comment,
                    columnPrefixes: copy.columnPrefixes, whereClause: copy.whereClause
                ))
            case .foreignKeys:
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let copy = structureChangeManager.workingForeignKeys[row]
                structureChangeManager.addForeignKey(EditableForeignKeyDefinition(
                    id: UUID(), name: copy.name, columns: copy.columns,
                    referencedTable: copy.referencedTable, referencedColumns: copy.referencedColumns,
                    referencedSchema: copy.referencedSchema,
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
}
