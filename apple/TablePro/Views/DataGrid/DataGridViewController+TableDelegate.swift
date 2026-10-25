//
//  DataGridViewController+TableDelegate.swift
//  TablePro
//

import AppKit

extension DataGridViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.rowCount
    }

    // MARK: - Views

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard let table = tableView as? DataGridTableView else { return nil }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? DataGridRowView) ?? DataGridRowView()
        rowView.identifier = Self.rowViewIdentifier
        rowView.controller = self
        rowView.gridTable = table
        rowView.redrawCells()
        return rowView
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.isEmphasized = gridHasFocus
    }

    // Nil for every drawn cell: only the edit cell and, while an assistive client is attached, the accessibility cells mount.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let pane = container.pane(of: tableView) else { return nil }
        if let editing = editingCellView(in: pane, tableColumn: tableColumn, row: row) {
            return editing
        }
        guard pane.isMain, DataGridAccessibility.isActive, mountsAccessibilityCell(forRow: row) else { return nil }
        return accessibilityCellView(for: tableColumn, row: row)
    }

    static let rowViewIdentifier = NSUserInterfaceItemIdentifier("DataGridRowView")

    // Answers from the active column only, so type-select matches what the reader is looking at.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableView === main.tableView,
              let tableColumn,
              let id = main.columnID(of: tableColumn),
              let column = model.columns.column(id: id),
              let position = model.columns.displayPosition(of: id),
              position == (model.selection.activeCell?.displayColumn ?? 0),
              let rowModel = model.row(at: row) else { return nil }
        return presenter.displayText(
            of: rowModel,
            dataIndex: column.dataIndex,
            type: column.type,
            formats: model.store.displayFormats,
            databaseType: model.configuration.traits.databaseType,
            columnCount: model.rows.columns.count
        )
    }

    // MARK: - Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, let pane = container.pane(of: table) else { return }
        tableSelectionDidChange(in: pane)
    }

    // MARK: - Header

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let pane = container.pane(of: tableView) else { return }
        sortDescriptorsDidChange(in: pane)
    }

    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        guard let pane = container.pane(of: tableView) else { return }
        headerPressed(tableColumn, in: pane)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let pane = container.pane(of: tableView) else { return }
        headerClicked(tableColumn, in: pane)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              let pane = container.pane(of: table),
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        columnDidResize(column, in: pane)
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              let pane = container.pane(of: table),
              let oldIndex = notification.userInfo?["NSOldColumn"] as? Int,
              let newIndex = notification.userInfo?["NSNewColumn"] as? Int else { return }
        columnDidMove(from: oldIndex, to: newIndex, in: pane)
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        guard let pane = container.pane(of: tableView) else { return false }
        return shouldReorderColumn(columnIndex, to: newColumnIndex, in: pane)
    }

    // The divider double-click, measured from the loaded display strings.
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard let pane = container.pane(of: tableView), column >= 0, column < tableView.tableColumns.count else { return 0 }
        let tableColumn = tableView.tableColumns[column]
        guard let id = pane.columnID(of: tableColumn), let dataColumn = model.columns.column(id: id) else {
            return tableColumn.width
        }
        return fittedWidth(for: dataColumn)
    }

    // MARK: - Row reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === frozen.tableView, canDragRows(fromRowNumberAt: row) else { return nil }
        return rowDragPasteboardItem(forRow: row)
    }

    // Every gap opens in one pane only, so the drop marks the row itself (.regular feedback, critic A M7).
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard model.configuration.rowReorder.isEnabled,
              info.draggingSource as? NSTableView === frozen.tableView,
              info.draggingPasteboard.availableType(from: [Self.rowDragType]) != nil else { return [] }
        if dropOperation != .above {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard model.configuration.rowReorder.isEnabled,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let fromRow = item.string(forType: Self.rowDragType).flatMap({ Int($0) }),
              fromRow != row, fromRow != row - 1,
              let rowID = model.rowID(at: fromRow),
              let actions = model.actions else { return false }
        actions.gridMoveRow(from: rowID, toDisplayIndex: row)
        return true
    }
}

extension DataGridViewController: NSMenuDelegate {
    // Built from clickedRow and clickedColumn, so AppKit draws the clicked-row ring and the selection does not move.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let pane = panes.first(where: { $0.tableView.menu === menu }) else { return }
        let table = pane.tableView
        let row = table.clickedRow
        let built: NSMenu?
        if row >= 0 {
            let column = table.clickedColumn
            var position: Int?
            if column >= 0, case .data(let id)? = pane.slot(atTableIndex: column, columns: model.columns) {
                position = model.columns.displayPosition(of: id)
            }
            built = rowMenu(forRow: row, displayColumn: position, in: pane.kind)
        } else {
            built = emptySpaceMenu()
        }
        guard let built else { return }
        let items = built.items
        built.removeAllItems()
        items.forEach(menu.addItem)
    }

    func headerMenu(forTableColumn tableColumn: NSTableColumn, in kind: DataGridPane.Kind) -> NSMenu? {
        let pane = container.pane(kind)
        guard let id = pane.columnID(of: tableColumn), let column = model.columns.column(id: id) else { return nil }
        return headerMenu(for: column)
    }
}
