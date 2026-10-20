//
//  DataGridView+SetCellsToValue.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// What one cell stages: a value, and whether it is SQL the engine runs.
typealias StagedCellEntry = (value: PluginCellValue, isExpression: Bool)

/// The records a Set Cells to Value sheet was opened over. A load that lands while the sheet is up can put other
/// records at the same display positions, so the write finds these records again or is dropped.
@MainActor
struct SetCellsToValueRecords {
    private let cells: [(rowID: RowID, columnIndex: Int)]
    private let rows: [RowID: Row]

    init(_ targets: [SetValueTarget], in coordinator: TableViewCoordinator) {
        let tableRows = coordinator.tableRowsProvider()
        var cells: [(rowID: RowID, columnIndex: Int)] = []
        var rows: [RowID: Row] = [:]
        for target in targets {
            guard let row = coordinator.displayRow(at: target.displayRow, in: tableRows) else { continue }
            cells.append((rowID: row.id, columnIndex: target.columnIndex))
            rows[row.id] = row
        }
        self.cells = cells
        self.rows = rows
    }

    /// Where the records are now, or nil when one of them is gone or no longer holds what it held.
    func targets(in coordinator: TableViewCoordinator) -> [SetValueTarget]? {
        let tableRows = coordinator.tableRowsProvider()
        var filteredPositions: [RowID: Int] = [:]
        if let displayIDs = coordinator.displayIDs {
            for (position, id) in displayIDs.enumerated() {
                filteredPositions[id] = position
            }
        }
        var targets: [SetValueTarget] = []
        targets.reserveCapacity(cells.count)
        for cell in cells {
            guard let row = tableRows.row(withID: cell.rowID), row == rows[cell.rowID] else { return nil }
            let position = coordinator.displayIDs == nil ? tableRows.index(of: cell.rowID) : filteredPositions[cell.rowID]
            guard let position else { return nil }
            targets.append(SetValueTarget(displayRow: position, columnIndex: cell.columnIndex))
        }
        return targets
    }
}

extension TableViewCoordinator {
    /// The targets are the ones every Set Value item takes. A window with its own command runs that instead.
    func setCellsToValue(_ targets: [SetValueTarget]) {
        if delegate?.dataGridSetCellsToValue(targets) == true { return }
        let cells = setCellsToValueCells(targets)
        guard !cells.isEmpty, let window = tableView?.window else { return }
        let records = SetCellsToValueRecords(cells, in: self)
        SetCellsToValuePrompt.present(
            informative: Self.setCellsToValueImpact(cells: cells.count, targets: targets.count),
            window: window
        ) { [weak self] text in
            guard let self, let text else { return }
            guard let current = records.targets(in: self) else {
                NSSound.beep()
                return
            }
            self.applyCellsToValue(text, to: self.setCellsToValueCells(current))
        }
    }

    func isSetCellsToValueOffered(for targets: [SetValueTarget]) -> Bool {
        targets.contains { canStartInlineEdit(row: $0.displayRow, columnIndex: $0.columnIndex) }
    }

    /// The cells typing could edit, so a read-only or server-owned column, a deleted row and a binary value stay out.
    func setCellsToValueCells(_ targets: [SetValueTarget]) -> [SetValueTarget] {
        targets.filter { canStartInlineEdit(row: $0.displayRow, columnIndex: $0.columnIndex) }
    }

    /// The text is read for each column the way a typed cell is: an empty date is NULL, a function the engine runs
    /// there is SQL.
    func applyCellsToValue(_ text: String, to cells: [SetValueTarget]) {
        stageEntry(into: cells, actionName: String(localized: "Set Cells to Value")) { columnIndex in
            enteredCell(text, columnIndex: columnIndex)
        }
    }

    /// One undo step for every cell. The entry is read once per column; a column that holds neither it nor NULL in
    /// its place keeps its cells, and the beep says the value was refused.
    @discardableResult
    func stageEntry(
        into cells: [SetValueTarget],
        actionName: String,
        entry: (Int) -> StagedCellEntry?
    ) -> Int {
        guard !cells.isEmpty else { return 0 }
        let undoManager = tableView?.window?.undoManager
        undoManager?.beginUndoGrouping()

        var entries: [Int: StagedCellEntry?] = [:]
        var edited: [SetValueTarget] = []
        var refused = false
        batchEdits(actionName: actionName) {
            for cell in cells where !isRowDeleted(displayRow: cell.displayRow) {
                let resolved: StagedCellEntry?
                if let cached = entries[cell.columnIndex] {
                    resolved = cached
                } else {
                    resolved = entry(cell.columnIndex)
                    entries[cell.columnIndex] = .some(resolved)
                }
                guard let resolved else {
                    refused = true
                    continue
                }
                guard recordCellEdit(
                    row: cell.displayRow,
                    columnIndex: cell.columnIndex,
                    newValue: resolved.value,
                    isExpression: resolved.isExpression
                ) != nil else { continue }
                edited.append(cell)
            }
        }

        // After the loop: each cell's own step names the open group "Edit Cell".
        if !edited.isEmpty {
            undoManager?.setActionName(actionName)
        }
        undoManager?.endUndoGrouping()

        if edited.count == 1, let only = edited.first {
            repaintEditedCell(row: only.displayRow, columnIndex: only.columnIndex)
        } else if !edited.isEmpty {
            invalidateAllDisplayCaches()
            tableView?.reloadData()
        }
        if refused {
            NSSound.beep()
        }
        return edited.count
    }

    func batchEdits(actionName: String, _ edits: () -> Void) {
        guard let delegate else {
            edits()
            return
        }
        delegate.dataGridBatchEdits(actionName: actionName, edits)
    }

    static func setCellsToValueImpact(cells: Int, targets: Int) -> String {
        if cells < targets {
            return String(
                format: String(localized: "This sets %1$lld of %2$lld cells. The others cannot be edited."),
                Int64(cells),
                Int64(targets)
            )
        }
        if cells == 1 {
            return String(localized: "This sets 1 cell.")
        }
        return String(format: String(localized: "This sets %lld cells."), Int64(cells))
    }
}
