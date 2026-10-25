//
//  DataGridCommands+SetValue.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension DataGridCommands {
    // Any cell's commands, so a selection over a date and a UUID column offers both kinds, in menu order.
    func setValueCommands(for cells: [DataGridCommandCell]) -> [SetValueCommand] {
        var resolver = DataGridSetValueResolver(commands: self)
        var seen: Set<SetValueCommand> = []
        var offered: [SetValueCommand] = []
        for cell in cells {
            for command in resolver.commands(for: cell) ?? [] where seen.insert(command).inserted {
                offered.append(command)
            }
        }
        return offered.enumerated()
            .sorted { (Self.menuRank($0.element), $0.offset) < (Self.menuRank($1.element), $1.offset) }
            .map { $0.element }
    }

    func isSetValueOffered(_ command: SetValueCommand, for cells: [DataGridCommandCell]) -> Bool {
        var resolver = DataGridSetValueResolver(commands: self)
        return cells.contains { resolver.commands(for: $0)?.contains(command) == true }
    }

    // A cell that does not take the command, such as NULL on a NOT NULL column or a deleted row, is skipped.
    func applySetValue(_ command: SetValueCommand, to cells: [DataGridCommandCell]) {
        guard !cells.isEmpty else { return }
        let columns = IndexSet(cells.map(\.column.dataIndex))
        guard loader.ensureLoaded(cells.map(\.rowID), columns: columns, in: model, retry: {
            applySetValue(command, to: cells)
        }) else { return }
        var resolver = DataGridSetValueResolver(commands: self)
        var edits: [DataGridCellEdit] = []
        for cell in cells {
            guard let context = resolver.context(for: cell),
                  resolver.commands(for: cell)?.contains(command) == true,
                  let staged = Self.stagedValue(for: command, context: context) else { continue }
            edits.append(DataGridCellEdit(
                rowID: cell.rowID,
                columnID: cell.column.id,
                value: .value(staged.value, isExpression: staged.isExpression)
            ))
        }
        guard !edits.isEmpty else { return }
        model.commit(edits, actionName: Self.undoActionName(for: command))
    }

    func setValueContext(for column: DataGridColumn, rowIsInserted: Bool) -> SetValueContext? {
        let rows = model.rows
        let dataIndex = column.dataIndex
        guard rows.columns.indices.contains(dataIndex) else { return nil }
        let name = rows.columns[dataIndex]
        let format = model.displayFormat(for: column)
        return SetValueContext(
            columnType: rows.editingColumnType(at: dataIndex),
            isNullable: rows.columnNullable[name] ?? true,
            serverAssignsValue: rows.serverAssignsValue(forColumn: name),
            isForeignKey: rows.columnForeignKeys[name] != nil,
            isWritable: model.isColumnWritable(column),
            displayFormat: format,
            sampleText: format == .uuid ? Self.sampleText(ofColumn: dataIndex, in: rows) : nil,
            declaredType: rows.declaredType(at: dataIndex),
            databaseType: configuration.traits.databaseType ?? Self.unknownDatabaseType,
            rowIsInserted: rowIsInserted,
            writer: writerSupport
        )
    }

    // A grid with no engine named gets nothing the vocabulary keys by engine.
    private static let unknownDatabaseType = DatabaseType(rawValue: "")

    // A MySQL CHAR(32) result has no length, so its values are the one sign it takes the compact UUID form.
    private static func sampleText(ofColumn dataIndex: Int, in rows: TableRows) -> String? {
        for row in rows.rows where dataIndex < row.values.count {
            guard let text = row.values[dataIndex].asText,
                  !text.isEmpty, text != PluginCellValue.defaultMarkerText else { continue }
            return text
        }
        return nil
    }

    static func stagedValue(for command: SetValueCommand, context: SetValueContext) -> StagedCellEntry? {
        switch command {
        case .empty:
            return (value: .text(""), isExpression: false)
        case .null:
            return (value: .null, isExpression: false)
        case .defaultValue:
            return (value: .text(PluginCellValue.defaultMarkerText), isExpression: false)
        case .expression(let expression):
            return (value: .text(expression.sql), isExpression: true)
        case .uuid(let version):
            guard let form = SetValueOptions.uuidForm(for: context) else { return nil }
            return (value: form.value(for: UUIDValueGenerator.shared.make(version)), isExpression: false)
        }
    }

    static func undoActionName(for command: SetValueCommand) -> String {
        guard case .uuid = command else { return String(localized: "Set Value") }
        return SetValueOptions.title(for: command)
    }

    // Placeholders, then the engine's functions, then UUIDs.
    static func menuGroup(_ command: SetValueCommand) -> Int {
        switch command {
        case .empty, .null, .defaultValue: 0
        case .expression: 1
        case .uuid: 2
        }
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

    // MARK: - Set Cells to Value

    func isSetCellsToValueOffered(for cells: [DataGridCommandCell]) -> Bool {
        cells.contains { typingCanEdit($0) }
    }

    func applyEnteredText(_ text: String, to cells: [DataGridCommandCell]) {
        applyEntry(to: cells, actionName: String(localized: "Set Cells to Value")) { column in
            enteredCell(text, column: column)
        }
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

    // MARK: - Remove Field

    // Only an engine that tells a missing field from NULL, on a cell that still has a field to remove.
    func canRemoveField(_ cell: DataGridCommandCell) -> Bool {
        guard configuration.traits.supportsFieldRemoval, model.isColumnWritable(cell.column), !isRowDeleted(cell.rowID),
              let row = storedRow(cell.rowID) else { return false }
        return cell.column.dataIndex < row.values.count && !row.isAbsent(cell.column.dataIndex)
    }

    func removeField(_ cell: DataGridCommandCell) {
        guard canRemoveField(cell) else { return }
        model.commit(
            [DataGridCellEdit(rowID: cell.rowID, columnID: cell.column.id, value: .removeField)],
            actionName: String(localized: "Remove Field")
        )
    }
}

// The records a Set Cells to Value sheet was opened over. A load that lands while the sheet is up can move or replace
// them, so the write finds the same records holding the same values, or is dropped.
@MainActor
struct DataGridCellRecords {
    private let cells: [(rowID: RowID, columnID: DataGridColumnID)]
    private let rows: [RowID: Row]

    init(_ cells: [DataGridCommandCell], in model: DataGridModel) {
        let tableRows = model.rows
        var rows: [RowID: Row] = [:]
        for cell in cells {
            rows[cell.rowID] = tableRows.row(withID: cell.rowID)
        }
        self.cells = cells.map { (rowID: $0.rowID, columnID: $0.column.id) }
        self.rows = rows
    }

    func current(in model: DataGridModel) -> [DataGridCommandCell]? {
        let tableRows = model.rows
        var resolved: [DataGridCommandCell] = []
        resolved.reserveCapacity(cells.count)
        for cell in cells {
            guard let row = tableRows.row(withID: cell.rowID), row == rows[cell.rowID],
                  let displayRow = model.displayIndex(of: cell.rowID),
                  let column = model.columns.column(id: cell.columnID) else { return nil }
            resolved.append(DataGridCommandCell(rowID: cell.rowID, row: displayRow, column: column))
        }
        return resolved
    }
}

// A context depends only on the column and whether the row is new, so a tall selection resolves a few, not one per cell.
@MainActor
struct DataGridSetValueResolver {
    private struct Key: Hashable {
        let columnID: DataGridColumnID
        let rowIsInserted: Bool
    }

    private let source: DataGridCommands
    private let insertedRowIDs: Set<RowID>
    private let deletedRowIDs: Set<RowID>
    private var resolved: [Key: (context: SetValueContext, commands: [SetValueCommand])?] = [:]

    init(commands: DataGridCommands) {
        source = commands
        insertedRowIDs = commands.model.changeState?.insertedRowIDs ?? []
        deletedRowIDs = commands.model.changeState?.deletedRowIDs ?? []
    }

    mutating func context(for cell: DataGridCommandCell) -> SetValueContext? {
        options(for: cell)?.context
    }

    mutating func commands(for cell: DataGridCommandCell) -> [SetValueCommand]? {
        options(for: cell)?.commands
    }

    private mutating func options(for cell: DataGridCommandCell) -> (context: SetValueContext, commands: [SetValueCommand])? {
        guard !deletedRowIDs.contains(cell.rowID) else { return nil }
        let key = Key(columnID: cell.column.id, rowIsInserted: insertedRowIDs.contains(cell.rowID))
        if let cached = resolved[key] { return cached }
        let options = source
            .setValueContext(for: cell.column, rowIsInserted: key.rowIsInserted)
            .map { (context: $0, commands: SetValueOptions.commands(for: $0)) }
        resolved[key] = .some(options)
        return options
    }
}
