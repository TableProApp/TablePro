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

    /// Whether a column may be moved right now, and why not when it may not. Carried so the row's
    /// contextual menu can offer the same reorder the drag offers, and name the same reason.
    var columnReorder: DataGridRowReorder = .disabled

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

        case .checkConstraints:
            guard connection.type.supportsCheckConstraintEditing,
                  sourceRowIndex < structureChangeManager.workingCheckConstraints.count else { return }
            var constraint = structureChangeManager.workingCheckConstraints[sourceRowIndex]
            StructureEditingSupport.updateCheckConstraint(&constraint, at: column, with: newValue ?? "")
            structureChangeManager.updateCheckConstraint(id: constraint.id, with: constraint)

        case .ddl, .parts, .triggers:
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
            structureChangeManager.performAsOneUndoStep {
                for row in translated.sorted(by: >) {
                    guard row < structureChangeManager.workingColumns.count else { continue }
                    let column = structureChangeManager.workingColumns[row]
                    structureChangeManager.deleteColumn(id: column.id)
                }
            }
        case .indexes:
            guard connection.type.supportsDropIndex else { return }
            structureChangeManager.performAsOneUndoStep {
                for row in translated.sorted(by: >) {
                    guard row < structureChangeManager.workingIndexes.count else { continue }
                    let index = structureChangeManager.workingIndexes[row]
                    structureChangeManager.deleteIndex(id: index.id)
                }
            }
        case .foreignKeys:
            guard connection.type.supportsForeignKeys else { return }
            structureChangeManager.performAsOneUndoStep {
                for row in translated.sorted(by: >) {
                    guard row < structureChangeManager.workingForeignKeys.count else { continue }
                    let fk = structureChangeManager.workingForeignKeys[row]
                    structureChangeManager.deleteForeignKey(id: fk.id)
                }
            }
        case .checkConstraints:
            guard connection.type.supportsCheckConstraintEditing else { return }
            structureChangeManager.performAsOneUndoStep {
                for row in translated.sorted(by: >) {
                    guard row < structureChangeManager.workingCheckConstraints.count else { continue }
                    let constraint = structureChangeManager.workingCheckConstraints[row]
                    structureChangeManager.deleteCheckConstraint(id: constraint.id)
                }
            }
        case .parts, .ddl, .triggers:
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
        guard selectedTab != .ddl, selectedTab != .parts, selectedTab != .triggers, !indices.isEmpty else { return }
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
        case .checkConstraints:
            for row in translated.sorted() {
                guard row < structureChangeManager.workingCheckConstraints.count else { continue }
                copiedItems.append(structureChangeManager.workingCheckConstraints[row])
            }
        case .ddl, .parts, .triggers:
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
        } else if let constraints = copiedItems as? [EditableCheckConstraintDefinition],
                  let encoded = try? JSONEncoder().encode(constraints) {
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

    func dataGridCanPasteRows() -> Bool {
        TableStructureView.canPasteStructureRows
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
                structureChangeManager.addColumn(item.withNewIdentity())
            }

        case .indexes:
            guard let indexes = try? decoder.decode([EditableIndexDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in indexes {
                structureChangeManager.addIndex(item.withNewIdentity())
            }

        case .foreignKeys:
            guard let fks = try? decoder.decode([EditableForeignKeyDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in fks {
                structureChangeManager.addForeignKey(item.withNewIdentity())
            }

        case .checkConstraints:
            guard connection.type.supportsCheckConstraintEditing,
                  let constraints = try? decoder.decode(
                      [EditableCheckConstraintDefinition].self, from: Data(jsonString.utf8)
                  ) else {
                return
            }
            for item in constraints {
                structureChangeManager.addCheckConstraint(item.withNewIdentity())
            }

        case .ddl, .parts, .triggers:
            break
        }
    }

    func dataGridUndo() {
        guard selectedTab != .ddl, selectedTab != .triggers else { return }
        structureChangeManager.undo()
        // Undo can revert any row's content and visual state. The SwiftUI
        // re-render driven by `reloadVersion` only invalidates the snapshot;
        // ask `NSTableView` to redraw visible rows so the cell text and
        // modified-tint actually update on screen.
        reloadAllVisibleRows()
    }

    func dataGridRedo() {
        guard selectedTab != .ddl, selectedTab != .triggers else { return }
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
        case .checkConstraints:
            guard connection.type.supportsCheckConstraintEditing else { return }
            structureChangeManager.addNewCheckConstraint()
        case .ddl, .parts, .triggers:
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
        case .checkConstraints:
            guard sourceRow < structureChangeManager.workingCheckConstraints.count else { return [] }
            let working = structureChangeManager.workingCheckConstraints[sourceRow]
            guard let original = structureChangeManager.currentCheckConstraints
                .first(where: { $0.id == working.id }) else { return [] }
            return StructureEditingSupport.checkConstraintModifiedIndices(old: original, new: working)
        case .ddl, .parts, .triggers:
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

    /// Move Column Up and Move Column Down, for whichever of the grid's two contextual menus is
    /// asking. Dragging is the usual way to move a column and it is also the only way that needs a
    /// pointer; these give the same reorder to the keyboard and to VoiceOver, which reaches a menu
    /// but cannot perform a drag.
    ///
    /// Built here rather than in the row view because a column row raises two different menus.
    /// `KeyHandlingTableView.rightMouseDown` intercepts a click inside the selection and answers
    /// from `DataGridRowView.contextMenu(for:)`, which is this method's caller; a click outside it
    /// falls through to `StructureRowViewWithMenu.menu(for:)`, which asks for the same items. One
    /// builder, so select-then-right-click and right-click-elsewhere cannot offer different
    /// commands.
    func dataGridRowStructureMenuItems(forRow displayRow: Int) -> [NSMenuItem] {
        guard selectedTab == .columns else { return [] }
        guard columnReorder.isEnabled || columnReorder.unavailableReason != nil else { return [] }

        /// The working set, not the displayed rows: a reorder is withheld under a filter or a sort
        /// precisely so that the two are the same list, and the plan names every column.
        let count = structureChangeManager.workingColumns.count
        var items = [
            columnMoveItem(String(localized: "Move Column Up"), row: displayRow, .up, count: count),
            columnMoveItem(String(localized: "Move Column Down"), row: displayRow, .down, count: count),
        ]

        /// Spelled out under the two dead commands rather than left to the help tag on the row
        /// number. A menu the user opened because a drag did nothing is where the answer belongs.
        guard let reason = columnReorder.unavailableReason else { return items }
        let explanation = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
        explanation.isEnabled = false
        items.append(explanation)
        return items
    }

    /// A nil action is what disables the item: both menus autoenable, and neither the row view nor
    /// this delegate is in the responder chain to answer `validateMenuItem(_:)` for itself. The
    /// target is held by `representedObject` so it outlives the menu that is showing it.
    private func columnMoveItem(
        _ title: String,
        row: Int,
        _ direction: ColumnMove.Direction,
        count: Int
    ) -> NSMenuItem {
        let isEnabled = columnReorder.isEnabled
            && ColumnMove.isPossible(movingRow: row, direction, columnCount: count)
        guard isEnabled else {
            return NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(title: title, action: #selector(StructureMenuTarget.runAction), keyEquivalent: "")
        let target = StructureMenuTarget { [weak self] in
            self?.moveRowHandler?(row, ColumnMove.dropIndex(movingRow: row, direction))
        }
        item.target = target
        item.representedObject = target
        return item
    }

    private func makeEmptySpaceMenu() -> NSMenu? {
        guard selectedTab != .ddl, selectedTab != .parts, selectedTab != .triggers else { return nil }
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
        case .checkConstraints:
            guard connection.type.supportsCheckConstraintEditing else { return nil }
            label = String(localized: "Add Check Constraint")
        case .ddl, .parts, .triggers:
            return nil
        }

        let target = StructureMenuTarget { [weak self] in self?.dataGridAddRow() }
        let item = NSMenuItem(title: label, action: #selector(StructureMenuTarget.runAction), keyEquivalent: "")
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
            case .checkConstraints:
                guard row < structureChangeManager.workingCheckConstraints.count else { continue }
                let constraint = structureChangeManager.workingCheckConstraints[row]
                let quoted = driver.quoteIdentifier(constraint.name)
                definitions.append("CONSTRAINT \(quoted) CHECK (\(constraint.expression))")
            case .ddl, .parts, .triggers:
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
                structureChangeManager.addColumn(copy.withNewIdentity())
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
                structureChangeManager.addForeignKey(copy.withNewIdentity())
            case .checkConstraints:
                guard connection.type.supportsCheckConstraintEditing,
                      row < structureChangeManager.workingCheckConstraints.count else { continue }
                let copy = structureChangeManager.workingCheckConstraints[row]
                structureChangeManager.addCheckConstraint(copy.withNewIdentity())
            case .ddl, .parts, .triggers:
                break
            }
        }
    }

    private func handleNavigateToFK(_ row: Int) {
        guard row < structureChangeManager.workingForeignKeys.count else { return }
        let fk = structureChangeManager.workingForeignKeys[row]
        coordinator?.openTableTab(fk.referencedTable, schema: fk.referencedSchema)
    }
}
