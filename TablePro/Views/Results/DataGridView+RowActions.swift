//
//  DataGridView+RowActions.swift
//  TablePro
//
//  Row action methods extracted from DataGridView for maintainability.
//

import AppKit
import os
import TableProPluginKit

private let rowActionsLogger = Logger(subsystem: "com.TablePro", category: "DataGridView+RowActions")

// MARK: - Row Actions

extension TableViewCoordinator {
    @MainActor
    func undoDeleteRow(at index: Int) {
        changeManager.undoRowDeletion(rowIndex: index)
        visualIndex.updateRow(index, from: changeManager, sortedIDs: sortedIDs)
        tableView?.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
        refreshRowVisualState(at: index)
    }

    func addNewRow() {
        delegate?.dataGridAddRow()
    }

    @MainActor
    func undoInsertRow(at index: Int) {
        delegate?.dataGridUndoInsert(at: index)
        changeManager.undoRowInsertion(rowIndex: index)
        var capturedDelta: Delta = .none
        tableRowsMutator { rows in
            capturedDelta = rows.remove(at: IndexSet(integer: index))
        }
        applyDelta(capturedDelta)
    }

    func copyRows(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        let tableRows = tableRowsProvider()
        let columnTypes = tableRows.columnTypes
        var tsvRows: [String] = []
        var htmlRows: [[String]] = []

        for index in sortedIndices {
            guard let values = displayRow(at: index)?.values else { continue }
            let formatted = formatRowValues(values: Array(values), columnTypes: columnTypes)
            tsvRows.append(formatted.joined(separator: "\t"))
            htmlRows.append(formatted)
        }

        let tsv = tsvRows.joined(separator: "\n")
        let html = HtmlTableEncoder.encode(rows: htmlRows)
        ClipboardService.shared.writeRows(tsv: tsv, html: html)
    }

    func copyRowsWithHeaders(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        let tableRows = tableRowsProvider()
        let columnTypes = tableRows.columnTypes
        let columns = tableRows.columns
        var tsvRows: [String] = [columns.joined(separator: "\t")]
        var htmlRows: [[String]] = []

        for index in sortedIndices {
            guard let values = displayRow(at: index)?.values else { continue }
            let formatted = formatRowValues(values: Array(values), columnTypes: columnTypes)
            tsvRows.append(formatted.joined(separator: "\t"))
            htmlRows.append(formatted)
        }

        let tsv = tsvRows.joined(separator: "\n")
        let html = HtmlTableEncoder.encode(rows: htmlRows, headers: columns)
        ClipboardService.shared.writeRows(tsv: tsv, html: html)
    }

    @MainActor
    func setCellValueAtColumn(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        commitCellEdit(row: rowIndex, columnIndex: columnIndex, newValue: value)
    }

    func copyCellValue(at rowIndex: Int, columnIndex: Int) {
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0 && columnIndex < tableRows.columns.count else { return }
        guard let row = displayRow(at: rowIndex), columnIndex < row.values.count else { return }

        let cell = row.values[columnIndex]
        let columnTypes = tableRows.columnTypes
        let columnType = columnTypes.indices.contains(columnIndex) ? columnTypes[columnIndex] : nil

        if case .bytes(let data) = cell {
            ClipboardService.shared.writeText(BlobFormattingService.shared.format(data, for: .copy) ?? "")
            return
        }

        let value = cell.asText ?? "NULL"

        if columnIndex < columnDisplayFormats.count, let format = columnDisplayFormats[columnIndex], format != .raw {
            let formatted = ValueDisplayFormatService.applyFormat(value, format: format)
            ClipboardService.shared.writeText(formatted)
            return
        }

        let copyValue = BlobFormattingService.shared.formatIfNeeded(value, columnType: columnType, for: .copy)
        ClipboardService.shared.writeText(copyValue)
    }

    func copyRowsAsInsert(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        let tableRows = tableRowsProvider()
        let driver = resolveDriver()
        do {
            let converter = try SQLRowToStatementConverter(
                tableName: tableName,
                columns: tableRows.columns,
                primaryKeyColumn: primaryKeyColumn,
                databaseType: databaseType,
                quoteIdentifier: driver?.quoteIdentifier,
                escapeStringLiteral: driver?.escapeStringLiteral
            )
            let typedRows: [[PluginCellValue]] = indices.sorted().compactMap { displayRow(at: $0).map { Array($0.values) } }
            guard !typedRows.isEmpty else { return }
            ClipboardService.shared.writeText(converter.generateInserts(rows: typedRows))
        } catch {
            rowActionsLogger.error("copyRowsAsInsert failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copyRowsAsUpdate(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        let tableRows = tableRowsProvider()
        let driver = resolveDriver()
        do {
            let converter = try SQLRowToStatementConverter(
                tableName: tableName,
                columns: tableRows.columns,
                primaryKeyColumn: primaryKeyColumn,
                databaseType: databaseType,
                quoteIdentifier: driver?.quoteIdentifier,
                escapeStringLiteral: driver?.escapeStringLiteral
            )
            let typedRows: [[PluginCellValue]] = indices.sorted().compactMap { displayRow(at: $0).map { Array($0.values) } }
            guard !typedRows.isEmpty else { return }
            ClipboardService.shared.writeText(converter.generateUpdates(rows: typedRows))
        } catch {
            rowActionsLogger.error("copyRowsAsUpdate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copyRowsAsJson(at indices: Set<Int>) {
        let rows: [[PluginCellValue]] = indices.sorted().compactMap { displayRow(at: $0).map { Array($0.values) } }
        guard !rows.isEmpty else { return }
        let tableRows = tableRowsProvider()
        let columnTypes = tableRows.columnTypes
        let converter = JsonRowConverter(columns: tableRows.columns, columnTypes: columnTypes)
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    private func formatRowValues(values: [PluginCellValue], columnTypes: [ColumnType]?) -> [String] {
        values.enumerated().map { index, cell in
            switch cell {
            case .null:
                return "NULL"
            case .text(let value):
                let columnType = columnTypes.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                return BlobFormattingService.shared.formatIfNeeded(value, columnType: columnType, for: .copy)
            case .bytes(let data):
                return BlobFormattingService.shared.format(data, for: .copy) ?? ""
            }
        }
    }

    private func resolveDriver() -> (any DatabaseDriver)? {
        guard let connectionId else { return nil }
        return DatabaseManager.shared.driver(for: connectionId)
    }

    // MARK: - Row Drag and Drop

    private static let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard delegate != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowDragType)

        if let values = displayRow(at: row)?.values {
            let tableRows = tableRowsProvider()
            let formatted = formatRowValues(values: Array(values), columnTypes: tableRows.columnTypes)
            item.setString(formatted.joined(separator: "\t"), forType: .string)
            item.setString(
                HtmlTableEncoder.encode(rows: [formatted], headers: tableRows.columns),
                forType: .html
            )
        }

        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard delegate != nil else { return [] }
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        guard info.draggingPasteboard.availableType(from: [Self.rowDragType]) != nil else { return [] }
        guard dropOperation == .above else {
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let delegate else { return false }
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowString = item.string(forType: Self.rowDragType),
              let fromRow = Int(rowString) else {
            return false
        }
        guard fromRow != row && fromRow != row - 1 else { return false }
        delegate.dataGridMoveRow(from: fromRow, to: row)
        return true
    }
}
