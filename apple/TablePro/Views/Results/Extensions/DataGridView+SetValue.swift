//
//  DataGridView+SetValue.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// A display row and a data column.
struct SetValueTarget: Hashable {
    let displayRow: Int
    let columnIndex: Int
}

extension TableViewCoordinator {
    /// The cell selection, else the clicked column on every selected row, else the clicked cell. A context menu keeps
    /// the selection only when the click lands inside it; the menu bar passes nil while a selection exists.
    func setValueTargets(clicked: SetValueTarget?) -> [SetValueTarget] {
        let selection = selectionController.selection
        if !selection.isEmpty, clicked.map({ isTarget($0, inside: selection) }) ?? true {
            return cells(in: selection)
        }
        guard let clicked, clicked.displayRow >= 0, clicked.columnIndex >= 0 else { return [] }
        let selectedRows = tableView.map { Set($0.selectedRowIndexes) } ?? selectedRowIndices
        guard selectedRows.count > 1, selectedRows.contains(clicked.displayRow) else { return [clicked] }
        return selectedRows.sorted().map { SetValueTarget(displayRow: $0, columnIndex: clicked.columnIndex) }
    }

    /// Any target's commands, so a selection over a date and a UUID column offers both kinds.
    func setValueCommands(for targets: [SetValueTarget]) -> [SetValueCommand] {
        var resolver = SetValueResolver(coordinator: self)
        var seen: Set<SetValueCommand> = []
        var offered: [SetValueCommand] = []
        for target in targets {
            for command in resolver.commands(for: target) ?? [] where seen.insert(command).inserted {
                offered.append(command)
            }
        }
        return offered.enumerated()
            .sorted { (Self.menuRank($0.element), $0.offset) < (Self.menuRank($1.element), $1.offset) }
            .map { $0.element }
    }

    func isSetValueOffered(_ command: SetValueCommand, for targets: [SetValueTarget]) -> Bool {
        var resolver = SetValueResolver(coordinator: self)
        return targets.contains { resolver.commands(for: $0)?.contains(command) == true }
    }

    /// A target that does not take the command, such as NULL on a NOT NULL column or a deleted row, is skipped.
    func applySetValue(_ command: SetValueCommand, to targets: [SetValueTarget]) {
        guard !targets.isEmpty else { return }
        guard unloadedValuesAreLoaded(targets: targets, retry: { [weak self] in
            self?.applySetValue(command, to: targets)
        }) else { return }
        var resolver = SetValueResolver(coordinator: self)
        let undoManager = tableView?.window?.undoManager
        undoManager?.beginUndoGrouping()

        var edited: [SetValueTarget] = []
        for target in targets {
            guard let context = resolver.context(for: target),
                  resolver.commands(for: target)?.contains(command) == true,
                  let staged = Self.stagedValue(for: command, context: context),
                  recordCellEdit(
                      row: target.displayRow,
                      columnIndex: target.columnIndex,
                      newValue: staged.value,
                      isExpression: staged.isExpression
                  ) != nil else { continue }
            edited.append(target)
        }

        // After the loop: each cell's own step names the open group "Edit Cell".
        if !edited.isEmpty {
            undoManager?.setActionName(Self.undoActionName(for: command))
        }
        undoManager?.endUndoGrouping()

        if edited.count == 1, let only = edited.first {
            repaintEditedCell(row: only.displayRow, columnIndex: only.columnIndex)
        } else if !edited.isEmpty {
            invalidateAllDisplayCaches()
            tableView?.reloadData()
        }
    }

    func setValueContext(forColumn columnIndex: Int, rowIsInserted: Bool, in tableRows: TableRows) -> SetValueContext? {
        guard tableRows.columns.indices.contains(columnIndex) else { return nil }
        let name = tableRows.columns[columnIndex]
        let format = columnDisplayFormats.indices.contains(columnIndex) ? columnDisplayFormats[columnIndex] : nil
        return SetValueContext(
            columnType: tableRows.editingColumnType(at: columnIndex),
            isNullable: tableRows.columnNullable[name] ?? true,
            serverAssignsValue: tableRows.serverAssignsValue(forColumn: name),
            isForeignKey: tableRows.columnForeignKeys[name] != nil,
            isWritable: isEditable && isColumnWritable(name),
            displayFormat: format,
            sampleText: format == .uuid ? Self.sampleText(ofColumn: columnIndex, in: tableRows) : nil,
            declaredType: tableRows.declaredType(at: columnIndex),
            databaseType: databaseType ?? Self.unknownDatabaseType,
            rowIsInserted: rowIsInserted,
            writer: changeManager.cellWriterSupport
        )
    }

    /// A grid with no engine named gets nothing the vocabulary keys by engine.
    private static let unknownDatabaseType = DatabaseType(rawValue: "")

    /// A MySQL `CHAR(32)` result has no length, so its values are the one sign it takes the compact UUID form.
    private static func sampleText(ofColumn columnIndex: Int, in tableRows: TableRows) -> String? {
        for row in tableRows.rows where columnIndex < row.values.count {
            guard let text = row.values[columnIndex].asText,
                  !text.isEmpty, text != PluginCellValue.defaultMarkerText else { continue }
            return text
        }
        return nil
    }

    private func isTarget(_ target: SetValueTarget, inside selection: GridSelection) -> Bool {
        guard let position = displayPosition(ofDataColumnIndex: target.columnIndex) else { return false }
        return selection.contains(row: target.displayRow, displayColumn: position)
    }

    /// Overlapping rectangles name a cell once.
    private func cells(in selection: GridSelection) -> [SetValueTarget] {
        let rowCount = displayIDs?.count ?? tableRowsProvider().count
        let presented = presentedDataColumns
        func dataColumns(_ positions: IndexSet) -> [Int] {
            positions.compactMap { presented.indices.contains($0) ? presented[$0] : nil }
        }
        var cells: [SetValueTarget] = []
        if selection.rectangles.count == 1, let only = selection.rectangles.first {
            let columns = dataColumns(IndexSet(integersIn: only.columns.lowerBound...only.columns.upperBound))
            for row in only.rows where row >= 0 && row < rowCount {
                cells += columns.map { SetValueTarget(displayRow: row, columnIndex: $0) }
            }
            return cells
        }
        for row in selection.affectedRows where row < rowCount {
            cells += dataColumns(selection.columns(in: row)).map { SetValueTarget(displayRow: row, columnIndex: $0) }
        }
        return cells
    }

    private static func stagedValue(
        for command: SetValueCommand,
        context: SetValueContext
    ) -> (value: PluginCellValue, isExpression: Bool)? {
        let value: PluginCellValue
        switch command {
        case .empty:
            value = .text("")
        case .null:
            value = .null
        case .defaultValue:
            value = .text(PluginCellValue.defaultMarkerText)
        case .expression(let expression):
            return (value: PluginCellValue.text(expression.sql), isExpression: true)
        case .uuid(let version):
            guard let form = SetValueOptions.uuidForm(for: context) else { return nil }
            value = form.value(for: UUIDValueGenerator.shared.make(version))
        }
        return (value: value, isExpression: false)
    }

    private static func undoActionName(for command: SetValueCommand) -> String {
        guard case .uuid = command else { return String(localized: "Set Value") }
        return SetValueOptions.title(for: command)
    }

    private static func menuRank(_ command: SetValueCommand) -> Int {
        switch command {
        case .empty: 0
        case .null: 1
        case .defaultValue: 2
        case .expression: 3
        case .uuid(.v4): 4
        case .uuid(.v7): 5
        }
    }
}

/// A context depends only on the column and whether the row is new, so a tall selection resolves a few, not one per cell.
@MainActor
private struct SetValueResolver {
    private struct Key: Hashable {
        let columnIndex: Int
        let rowIsInserted: Bool
    }

    private let coordinator: TableViewCoordinator
    private let tableRows: TableRows
    private let insertedRowIDs: Set<RowID>
    private let deletedRowIDs: Set<RowID>
    private var resolved: [Key: (context: SetValueContext, commands: [SetValueCommand])?] = [:]

    init(coordinator: TableViewCoordinator) {
        self.coordinator = coordinator
        tableRows = coordinator.tableRowsProvider()
        insertedRowIDs = coordinator.changeManager.insertedRowIDs
        deletedRowIDs = coordinator.changeManager.deletedRowIDs
    }

    mutating func context(for target: SetValueTarget) -> SetValueContext? {
        options(for: target)?.context
    }

    mutating func commands(for target: SetValueTarget) -> [SetValueCommand]? {
        options(for: target)?.commands
    }

    private mutating func options(for target: SetValueTarget) -> (context: SetValueContext, commands: [SetValueCommand])? {
        guard let row = coordinator.displayRow(at: target.displayRow, in: tableRows),
              !deletedRowIDs.contains(row.id) else { return nil }
        let key = Key(columnIndex: target.columnIndex, rowIsInserted: insertedRowIDs.contains(row.id))
        if let cached = resolved[key] { return cached }
        let options = coordinator
            .setValueContext(forColumn: key.columnIndex, rowIsInserted: key.rowIsInserted, in: tableRows)
            .map { (context: $0, commands: SetValueOptions.commands(for: $0)) }
        resolved[key] = .some(options)
        return options
    }
}
