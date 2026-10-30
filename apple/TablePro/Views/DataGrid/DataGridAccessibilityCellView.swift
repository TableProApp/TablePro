//
//  DataGridAccessibilityCellView.swift
//  TablePro
//

import AppKit

// The first question an assistive client asks is the only sign one is attached: NSWorkspace reports VoiceOver alone.
// One-way and process-wide, since nothing reports a client detaching either.
@MainActor
internal enum DataGridAccessibility {
    internal static let didActivateNotification = Notification.Name("com.TablePro.DataGridAccessibilityDidActivate")

    // Settable so a test can drive both shapes.
    internal static var isActive = false

    internal static func markActive() {
        guard !isActive else { return }
        isActive = true
        NotificationCenter.default.post(name: didActivateNotification, object: nil)
    }
}

// NSTableView builds its AXCell tree from cell views only (probe P6), so while a client is attached each on-screen
// cell of the main table mounts one of these. It draws nothing and takes no clicks.
@MainActor
final class DataGridAccessibilityCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("data-grid-cell")

    private weak var controller: DataGridViewController?
    private weak var table: NSTableView?
    private var slot: DataGridPane.Slot = .rowNumber
    private var seededRow = 0

    func configure(controller: DataGridViewController, table: NSTableView, row: Int, slot: DataGridPane.Slot) {
        self.controller = controller
        self.table = table
        self.slot = slot
        seededRow = row
        identifier = Self.reuseIdentifier
        setAccessibilityIdentifier(Self.reuseIdentifier.rawValue)
    }

    // Asked of the table rather than remembered: an insert or remove moves a mounted view without asking again.
    private var row: Int {
        guard let table else { return seededRow }
        let resolved = table.row(for: self)
        return resolved >= 0 ? resolved : seededRow
    }

    private var column: (model: DataGridColumn, position: Int)? {
        guard case .data(let id) = slot,
              let columns = controller?.model.columns,
              let position = columns.displayPosition(of: id),
              let column = columns.column(at: position) else { return nil }
        return (column, position)
    }

    private var rowModel: Row? {
        controller?.model.row(at: row)
    }

    // The row number the reader sees, page offset included.
    private var shownRowNumber: Int {
        (controller?.model.dataSource?.gridRowNumberOffset ?? 0) + row + 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityRowIndexRange() -> NSRange {
        NSRange(location: row, length: 1)
    }

    // A frozen column's cell is read where the frozen pane shows it, not at its home scrolled off to the left.
    override func accessibilityFrame() -> NSRect {
        guard let controller, let table, let window = table.window, let column,
              column.position < controller.effectiveFrozenCount else { return super.accessibilityFrame() }
        let offset = controller.main.scrollView.contentView.bounds.minX
        let shown = table.convert(bounds, from: self).offsetBy(dx: offset, dy: 0)
        return window.convertToScreen(table.convert(shown, to: nil))
    }

    override func isAccessibilityElement() -> Bool { true }

    // A cell with a list beside its text is a combo box, which is what NSComboBoxCell publishes.
    override func accessibilityRole() -> NSAccessibility.Role? {
        guard let column, let rowModel, let controller else { return .staticText }
        if checkboxMark(row: rowModel, column: column.model) != nil { return .checkBox }
        return controller.presenter.presentsComboBox(dataIndex: column.model.dataIndex) ? .comboBox : .staticText
    }

    override func accessibilityValue() -> Any? {
        guard let column, let rowModel else { return String(shownRowNumber) }
        if let mark = checkboxMark(row: rowModel, column: column.model) {
            return NSNumber(value: mark == .checked)
        }
        return controller?.presenter.accessibilityText(of: rowModel, column: column.model) ?? ""
    }

    override func accessibilityPerformPress() -> Bool {
        guard let controller, let column, let rowModel,
              controller.toggleCheckbox(rowID: rowModel.id, column: column.model, displayRow: row) else { return false }
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    // Whole sentences per combination, so a translator can order the parts; the pending change reads first.
    override func accessibilityLabel() -> String? {
        let rowNumber = shownRowNumber
        guard let controller, let column, let rowModel else {
            return String(format: String(localized: "Row %d"), rowNumber)
        }
        let presenter = controller.presenter
        let text = presenter.accessibilityText(of: rowModel, column: column.model)
        let columnNumber = column.position + 1
        let pendingChange = presenter.pendingChangeDescription(of: rowModel, dataIndex: column.model.dataIndex)
        let highlight = presenter.highlightDescription(of: rowModel, dataIndex: column.model.dataIndex)
        if let pendingChange, let highlight {
            return String(
                format: String(localized: "Row %d, column %d: %@, %@, highlighted where %@"),
                rowNumber, columnNumber, text, pendingChange, highlight
            )
        }
        if let pendingChange {
            return String(format: String(localized: "Row %d, column %d: %@, %@"), rowNumber, columnNumber, text, pendingChange)
        }
        if let highlight {
            return String(
                format: String(localized: "Row %d, column %d: %@, highlighted where %@"),
                rowNumber, columnNumber, text, highlight
            )
        }
        return String(format: String(localized: "Row %d, column %d: %@"), rowNumber, columnNumber, text)
    }

    private func checkboxMark(row: Row, column: DataGridColumn) -> DataGridCheckboxMark? {
        guard let controller else { return nil }
        return controller.presenter.checkboxMark(of: row, column: column, checkboxColumns: controller.model.configuration.checkboxColumns)
    }
}

extension DataGridViewController {
    // Only the viewport mounts: walking the tree prepares every row, and 9,000 views behind a 1,000-row page
    // starved the main thread (#2392).
    func mountsAccessibilityCell(forRow row: Int) -> Bool {
        let table = main.tableView
        return NSLocationInRange(row, table.rows(in: table.visibleRect))
    }

    func accessibilityCellView(for tableColumn: NSTableColumn, row: Int) -> NSView {
        let table = main.tableView
        let cell = (table.makeView(withIdentifier: DataGridAccessibilityCellView.reuseIdentifier, owner: nil)
            as? DataGridAccessibilityCellView) ?? DataGridAccessibilityCellView()
        let slot: DataGridPane.Slot = main.columnID(of: tableColumn).map { .data($0) } ?? .rowNumber
        cell.configure(controller: self, table: table, row: row, slot: slot)
        return cell
    }

    // A row prepared off screen was answered with no view and is never asked again, so an on-screen row without
    // its stand-in reloads. Asked of the rows themselves: a client's read prepares rows the grid never showed.
    func remountAccessibilityCells(force: Bool = false) {
        guard DataGridAccessibility.isActive, !isEditingCell else { return }
        let table = main.tableView
        let visible = table.rows(in: table.visibleRect)
        let upperBound = min(visible.location + visible.length, table.numberOfRows)
        guard visible.location >= 0, upperBound > visible.location, table.numberOfColumns > 0 else { return }
        let rows = IndexSet(integersIn: visible.location..<upperBound).filteredIndexSet { row in
            guard table.rowView(atRow: row, makeIfNecessary: false) != nil else { return false }
            return force || !(table.view(atColumn: 0, row: row, makeIfNecessary: false) is DataGridAccessibilityCellView)
        }
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // Rows also come on screen with no scroll: a fitted grid grows to its rows, a pane resizes, a page moves the
    // grid. Deferred past the layout pass or accessibility read that asks, which a reload inside would re-enter.
    func scheduleAccessibilityRemount() {
        guard DataGridAccessibility.isActive, !isAccessibilityRemountScheduled else { return }
        isAccessibilityRemountScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAccessibilityRemountScheduled = false
            self.remountAccessibilityCells()
        }
    }

    // Clamped to the visible rows: AppKit would otherwise ask for every cell of a million-row selection.
    func accessibilitySelectedCells() -> [Any]? {
        let table = main.tableView
        let selection = model.selection
        guard !selection.isEmpty else { return [] }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return [] }
        var cells: [Any] = []
        for rectangle in selection.rectangles {
            for row in rectangle.rows where NSLocationInRange(row, visible) {
                for position in rectangle.columns {
                    guard let index = main.tableIndex(forDisplayPosition: position, columns: model.columns),
                          let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? DataGridAccessibilityCellView
                    else { continue }
                    cells.append(cell)
                }
            }
        }
        return cells
    }

    func postSelectionAccessibility(from previous: GridSelection, to current: GridSelection) {
        guard DataGridAccessibility.isActive else { return }
        let table = main.tableView
        if current.hasMultipleCells || previous.hasMultipleCells {
            NSAccessibility.post(
                element: table,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: Self.accessibilityAnnouncement(for: current),
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
        NSAccessibility.post(element: table, notification: .selectedCellsChanged)
        guard let active = current.activeCell, active != previous.activeCell,
              let index = main.tableIndex(forDisplayPosition: active.displayColumn, columns: model.columns),
              active.row < table.numberOfRows,
              let cell = table.view(atColumn: index, row: active.row, makeIfNecessary: false) as? DataGridAccessibilityCellView
        else { return }
        NSAccessibility.post(element: cell, notification: .focusedUIElementChanged)
    }

    static func accessibilityAnnouncement(for selection: GridSelection) -> String {
        guard selection.hasMultipleCells, let rect = selection.boundingRectangle else {
            return String(localized: "Cell selection cleared")
        }
        return String(
            format: String(localized: "%d cells selected, rows %d to %d, columns %d to %d"),
            selection.uniqueCellCount,
            rect.rows.lowerBound + 1,
            rect.rows.upperBound + 1,
            rect.columns.lowerBound + 1,
            rect.columns.upperBound + 1
        )
    }

    // The frozen pane is hidden from accessibility, so a point over it answers with the main table's own cell.
    func accessibilityElement(atFrozenPanePoint point: NSPoint) -> NSView? {
        let frozenTable = frozen.tableView
        let row = frozenTable.row(at: point)
        let column = frozenTable.column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        DataGridAccessibility.markActive()
        let table = main.tableView
        return table.view(atColumn: column, row: row, makeIfNecessary: false)
            ?? table.rowView(atRow: row, makeIfNecessary: false)
    }
}
