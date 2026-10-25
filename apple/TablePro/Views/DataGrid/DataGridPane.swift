//
//  DataGridPane.swift
//  TablePro
//

import AppKit

// One table of the grid: the main pane holds every column, the frozen pane the row numbers and frozen columns laid over it.
@MainActor
final class DataGridPane {
    enum Kind {
        case main
        case frozen
    }

    enum Slot: Equatable {
        case rowNumber
        case data(DataGridColumnID)
    }

    static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("DataGrid.rowNumber")

    let kind: Kind
    let scrollView: DataGridScrollView
    let tableView: DataGridTableView
    let headerView: DataGridHeaderView

    private var columnsByID: [DataGridColumnID: NSTableColumn] = [:]
    private var idByIdentifier: [NSUserInterfaceItemIdentifier: DataGridColumnID] = [:]
    private var rowNumberColumn: NSTableColumn?
    private var slotsByTableIndex: [Slot]?
    private var tableIndexByDisplayPosition: [Int: Int]?

    init(kind: Kind) {
        let table = DataGridTableView(frame: .zero)
        table.paneKind = kind
        Self.configure(table, kind: kind)
        // Read after the style is set: the stock header's height follows the table style.
        let header = DataGridHeaderView(frame: table.headerView?.frame ?? NSRect(x: 0, y: 0, width: 0, height: 28))
        header.paneKind = kind
        table.headerView = header
        if kind == .frozen {
            table.cornerView = nil
        }
        let scroll = DataGridScrollView(kind: kind)
        scroll.documentView = table
        self.kind = kind
        tableView = table
        headerView = header
        scrollView = scroll
    }

    private static func configure(_ tableView: DataGridTableView, kind: Kind) {
        tableView.style = .plain
        tableView.wantsLayer = true
        tableView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsTypeSelect = kind == .main
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        switch kind {
        case .main:
            tableView.setAccessibilityIdentifier("data-grid")
            tableView.setAccessibilityLabel(String(localized: "Data grid"))
            tableView.setAccessibilityRole(.table)
        case .frozen:
            tableView.setAccessibilityIdentifier("data-grid-frozen")
            tableView.setAccessibilityElement(false)
            tableView.verticalMotionCanBeginDrag = false
        }
    }

    var isMain: Bool { kind == .main }

    // MARK: - Columns

    func columnID(of column: NSTableColumn) -> DataGridColumnID? {
        idByIdentifier[column.identifier]
    }

    func isRowNumber(_ column: NSTableColumn) -> Bool {
        column.identifier == Self.rowNumberIdentifier
    }

    func tableColumn(for id: DataGridColumnID) -> NSTableColumn? {
        columnsByID[id]
    }

    var hasRowNumberColumn: Bool {
        tableView.tableColumns.first.map(isRowNumber) ?? false
    }

    var rowNumberTableColumn: NSTableColumn? {
        hasRowNumberColumn ? tableView.tableColumns.first : nil
    }

    // Reuses the NSTableColumn each column already had, so a re-run of the same result does not flicker (#951).
    func pooledColumn(for id: DataGridColumnID) -> NSTableColumn {
        if let existing = columnsByID[id] { return existing }
        let identifier = NSUserInterfaceItemIdentifier("DataGrid.column.\(id.stringValue)")
        let column = NSTableColumn(identifier: identifier)
        column.headerCell = ThemeTableHeaderCell()
        column.minWidth = DataGridMetrics.dataColumnMinWidth
        column.maxWidth = DataGridMetrics.dataColumnMaxWidth
        column.resizingMask = .userResizingMask
        columnsByID[id] = column
        idByIdentifier[identifier] = id
        return column
    }

    func pooledRowNumberColumn() -> NSTableColumn {
        if let rowNumberColumn { return rowNumberColumn }
        let column = NSTableColumn(identifier: Self.rowNumberIdentifier)
        column.headerCell = ThemeTableHeaderCell()
        column.title = "#"
        column.isEditable = false
        column.resizingMask = []
        let headerCell = column.headerCell
        headerCell.alignment = .right
        headerCell.setAccessibilityLabel(String(localized: "Row number"))
        rowNumberColumn = column
        return column
    }

    func forgetColumns(except kept: Set<DataGridColumnID>) {
        for (id, column) in columnsByID where !kept.contains(id) {
            columnsByID.removeValue(forKey: id)
            idByIdentifier.removeValue(forKey: column.identifier)
        }
    }

    // MARK: - Slots

    func invalidateSlots() {
        slotsByTableIndex = nil
        tableIndexByDisplayPosition = nil
    }

    // Read by every drawn cell, so it is built once per layout and rebuilt only when a column moves.
    func slot(atTableIndex index: Int, columns: DataGridColumnSet) -> Slot? {
        let slots = resolvedSlots(columns: columns)
        guard index >= 0, index < slots.count else { return nil }
        return slots[index]
    }

    func tableIndex(forDisplayPosition position: Int, columns: DataGridColumnSet) -> Int? {
        if tableIndexByDisplayPosition == nil {
            rebuildSlots(columns: columns)
        }
        return tableIndexByDisplayPosition?[position]
    }

    private func resolvedSlots(columns: DataGridColumnSet) -> [Slot] {
        if let slotsByTableIndex { return slotsByTableIndex }
        rebuildSlots(columns: columns)
        return slotsByTableIndex ?? []
    }

    private func rebuildSlots(columns: DataGridColumnSet) {
        var slots: [Slot] = []
        var positions: [Int: Int] = [:]
        slots.reserveCapacity(tableView.tableColumns.count)
        for (index, column) in tableView.tableColumns.enumerated() {
            if isRowNumber(column) {
                slots.append(.rowNumber)
            } else if let id = idByIdentifier[column.identifier] {
                slots.append(.data(id))
                if let position = columns.displayPosition(of: id) {
                    positions[position] = index
                }
            } else {
                slots.append(.rowNumber)
            }
        }
        slotsByTableIndex = slots
        tableIndexByDisplayPosition = positions
    }

    // The display positions this pane shows, in its own column order.
    func displayPositions(columns: DataGridColumnSet) -> [Int] {
        resolvedSlots(columns: columns).compactMap { slot in
            guard case .data(let id) = slot else { return nil }
            return columns.displayPosition(of: id)
        }
    }

    var columnsWidth: CGFloat {
        guard let last = tableView.tableColumns.indices.last else { return 0 }
        return tableView.rect(ofColumn: last).maxX
    }
}
