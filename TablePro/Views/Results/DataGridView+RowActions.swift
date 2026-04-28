//
//  DataGridView+RowActions.swift
//  TablePro
//
//  Row action methods extracted from DataGridView for maintainability.
//

import AppKit

// MARK: - Row Actions

extension TableViewCoordinator {
    @MainActor
    func undoDeleteRow(at index: Int) {
        changeManager.undoRowDeletion(rowIndex: index)
        tableView?.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integersIn: 0..<(tableView?.numberOfColumns ?? 0)))
    }

    func addNewRow() {
        delegate?.dataGridAddRow()
    }

    @MainActor
    func undoInsertRow(at index: Int) {
        delegate?.dataGridUndoInsert(at: index)
        changeManager.undoRowInsertion(rowIndex: index)
        rowProvider.removeRow(at: index)
        updateCache()
        tableView?.reloadData()
    }

    func copyRows(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        let columnTypes = rowProvider.columnTypes
        var tsvRows: [String] = []
        var htmlRows: [[String]] = []

        for index in sortedIndices {
            guard let values = rowProvider.rowValues(at: index) else { continue }
            let formatted = formatRowValues(values: values, columnTypes: columnTypes)
            tsvRows.append(formatted.joined(separator: "\t"))
            htmlRows.append(formatted)
        }

        let tsv = tsvRows.joined(separator: "\n")
        let html = HtmlTableEncoder.encode(rows: htmlRows)
        ClipboardService.shared.writeTabular(tsv: tsv, html: html)
    }

    func copyRowsWithHeaders(at indices: Set<Int>) {
        let sortedIndices = indices.sorted()
        let columnTypes = rowProvider.columnTypes
        let columns = rowProvider.columns
        var tsvRows: [String] = [columns.joined(separator: "\t")]
        var htmlRows: [[String]] = []

        for index in sortedIndices {
            guard let values = rowProvider.rowValues(at: index) else { continue }
            let formatted = formatRowValues(values: values, columnTypes: columnTypes)
            tsvRows.append(formatted.joined(separator: "\t"))
            htmlRows.append(formatted)
        }

        let tsv = tsvRows.joined(separator: "\n")
        let html = HtmlTableEncoder.encode(rows: htmlRows, headers: columns)
        ClipboardService.shared.writeTabular(tsv: tsv, html: html)
    }

    @MainActor
    func setCellValue(_ value: String?, at rowIndex: Int) {
        guard let tableView = tableView else { return }
        var columnIndex = max(0, tableView.selectedColumn - 1)
        if columnIndex < 0 { columnIndex = 0 }
        setCellValueAtColumn(value, at: rowIndex, columnIndex: columnIndex)
    }

    @MainActor
    func setCellValueAtColumn(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        commitCellEdit(row: rowIndex, columnIndex: columnIndex, newValue: value)
    }

    func copyCellValue(at rowIndex: Int, columnIndex: Int) {
        guard columnIndex >= 0 && columnIndex < rowProvider.columns.count else { return }

        let value = rowProvider.value(atRow: rowIndex, column: columnIndex) ?? "NULL"
        let columnTypes = rowProvider.columnTypes
        let columnType = columnTypes.indices.contains(columnIndex) ? columnTypes[columnIndex] : nil

        // Use formatted value when a display format is active
        let formats = rowProvider.columnDisplayFormats
        if columnIndex < formats.count, let format = formats[columnIndex], format != .raw {
            let formatted = ValueDisplayFormatService.applyFormat(value, format: format)
            ClipboardService.shared.writeText(formatted)
            return
        }

        let copyValue = BlobFormattingService.shared.formatIfNeeded(value, columnType: columnType, for: .copy)
        ClipboardService.shared.writeText(copyValue)
    }

    func copyRowsAsInsert(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        let driver = resolveDriver()
        let converter = SQLRowToStatementConverter(
            tableName: tableName,
            columns: rowProvider.columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            quoteIdentifier: driver?.quoteIdentifier,
            escapeStringLiteral: driver?.escapeStringLiteral
        )
        let rows = indices.sorted().compactMap { rowProvider.rowValues(at: $0) }
        guard !rows.isEmpty else { return }
        ClipboardService.shared.writeText(converter.generateInserts(rows: rows))
    }

    func copyRowsAsUpdate(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        let driver = resolveDriver()
        let converter = SQLRowToStatementConverter(
            tableName: tableName,
            columns: rowProvider.columns,
            primaryKeyColumn: primaryKeyColumn,
            databaseType: databaseType,
            quoteIdentifier: driver?.quoteIdentifier,
            escapeStringLiteral: driver?.escapeStringLiteral
        )
        let rows = indices.sorted().compactMap { rowProvider.rowValues(at: $0) }
        guard !rows.isEmpty else { return }
        ClipboardService.shared.writeText(converter.generateUpdates(rows: rows))
    }

    func copyRowsAsJson(at indices: Set<Int>) {
        let rows = indices.sorted().compactMap { rowProvider.rowValues(at: $0) }
        guard !rows.isEmpty else { return }
        let columnTypes = rowProvider.columnTypes
        let converter = JsonRowConverter(columns: rowProvider.columns, columnTypes: columnTypes)
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    private func formatRowValues(values: [String?], columnTypes: [ColumnType]?) -> [String] {
        values.enumerated().map { index, value in
            guard let value else { return "NULL" }
            let columnType = columnTypes.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            return BlobFormattingService.shared.formatIfNeeded(value, columnType: columnType, for: .copy)
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

        if let values = rowProvider.rowValues(at: row) {
            let formatted = formatRowValues(values: values, columnTypes: rowProvider.columnTypes)
            item.setString(formatted.joined(separator: "\t"), forType: .string)
            item.setString(
                HtmlTableEncoder.encode(rows: [formatted], headers: rowProvider.columns),
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
