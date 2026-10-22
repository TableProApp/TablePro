//
//  DataGridView+RowActions.swift
//  TablePro
//

import AppKit
import os
import TableProAutocomplete
import TableProPluginKit

private let rowActionsLogger = Logger(subsystem: "com.TablePro", category: "DataGridView+RowActions")

// MARK: - Row Actions

extension TableViewCoordinator {
    @MainActor
    func undoDeleteRow(at index: Int) {
        guard let rowID = rowID(forDisplayRow: index) else { return }
        changeManager.undoRowDeletion(rowID: rowID)
        selectionSummaryTracker.dataDidChange()
        visualIndex.updateRow(rowID, from: changeManager)
        repaintRows(IndexSet(integer: index))
        refreshRowVisualState(at: index)
    }

    func addNewRow() {
        delegate?.dataGridAddRow()
    }

    func copyRows(at indices: Set<Int>, as format: RowCopyFormat) {
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRows(at: indices, as: format)
        }) else { return }
        switch format {
        case .rows: delegate?.dataGridCopyRows(indices)
        case .rowsWithHeaders: copyRowsWithHeaders(at: indices)
        case .json: copyRowsAsJson(at: indices)
        case .csv: copyRowsAsCsv(at: indices, includeHeaders: false)
        case .csvWithHeaders: copyRowsAsCsv(at: indices, includeHeaders: true)
        case .markdown: copyRowsAsMarkdown(at: indices)
        }
    }

    func copyRowsInCopyFormat(at indices: Set<Int>) {
        copyRows(at: indices, as: rowCopyFormat)
    }

    func copyRowsWithHeaders(at indices: Set<Int>) {
        copyRowsAsTSV(at: indices, includeHeaders: true)
    }

    func copyRowsAsTSV(at indices: Set<Int>, includeHeaders: Bool) {
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRowsAsTSV(at: indices, includeHeaders: includeHeaders)
        }) else { return }
        let sortedIndices = clipboardDisplayIndices(indices)
        let tableRows = tableRowsProvider()
        let projection = visibleColumnProjection
        let columnTypes = projection.columnTypes(tableRows.columnTypes)
        let columns = projection.columns(tableRows.columns)
        var tsvRows: [String] = includeHeaders ? [columns.joined(separator: "\t")] : []
        var htmlRows: [[String]] = []
        var copiedRows: [Row] = []

        for index in sortedIndices {
            guard let row = displayRow(at: index) else { continue }
            let formatted = formatRowValues(values: projection.values(Array(row.values)), columnTypes: columnTypes)
            tsvRows.append(formatted.joined(separator: "\t"))
            htmlRows.append(formatted)
            copiedRows.append(row)
        }
        guard !copiedRows.isEmpty else { return }

        let tsv = tsvRows.joined(separator: "\n")
        let html = includeHeaders ? HtmlTableEncoder.encode(rows: htmlRows, headers: columns) : nil
        ClipboardService.shared.writeRows(
            tsv: tsv,
            html: html,
            gridRows: rowsPayload(copiedRows, columns: columns, projection: projection)
        )
    }

    // The ceiling each format's converter already puts on its text, taken first so the paste payload holds the same rows.
    private func clipboardDisplayIndices(_ indices: Set<Int>) -> [Int] {
        let sorted = indices.sorted()
        let limit = RowOperationsManager.maxClipboardRows
        guard sorted.count > limit else { return sorted }
        rowActionsLogger.warning("Clipboard copy truncated: \(sorted.count) rows selected, capping at \(limit)")
        return Array(sorted.prefix(limit))
    }

    // Carried by every row copy, so a paste into a grid takes the rows rather than parsing the text.
    private func rowsPayload(
        _ rows: [Row],
        columns: [String],
        projection: VisibleColumnProjection
    ) -> GridRowsClipboardPayload {
        GridRowsClipboardPayload(
            columns: columns,
            copying: rows,
            expressionColumns: rows.map { changeManager.expressionColumns(forRow: $0.id) },
            projection: projection
        )
    }

    func copyCellValue(at rowIndex: Int, columnIndex: Int) {
        guard unloadedValuesAreLoaded(displayRows: [rowIndex], columns: IndexSet(integer: columnIndex), retry: { [weak self] in
            self?.copyCellValue(at: rowIndex, columnIndex: columnIndex)
        }) else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0 && columnIndex < tableRows.columns.count else { return }
        guard let row = displayRow(at: rowIndex), columnIndex < row.values.count else { return }

        let cell = row.values[columnIndex]
        if changeManager.isExpression(rowID: row.id, columnIndex: columnIndex), let sql = cell.asText {
            ClipboardService.shared.writeCells(
                GridCellsClipboardPayload(text: sql, fields: [[sql]], expressionFields: [0: [0]])
            )
            return
        }
        let columnTypes = tableRows.columnTypes
        let columnType = columnTypes.indices.contains(columnIndex) ? columnTypes[columnIndex] : nil
        let text = cellCopyText(cell, columnIndex: columnIndex, columnType: columnType)
        ClipboardService.shared.writeCells(GridCellsClipboardPayload(text: text, fields: [[cell.isNull ? nil : text]]))
    }

    private func cellCopyText(_ cell: PluginCellValue, columnIndex: Int, columnType: ColumnType?) -> String {
        if case .bytes(let data) = cell {
            let format = columnIndex < columnDisplayFormats.count ? columnDisplayFormats[columnIndex] : nil
            return format.flatMap { format in
                guard format.isApplicable(to: columnType, databaseType: databaseType) else { return nil }
                return ValueDisplayFormatter.apply(data, format: format, columnType: columnType)
            }
                ?? BlobFormattingService.shared.format(data, for: .copy)
                ?? ""
        }

        let value = cell.asText ?? "NULL"

        // A format saved before the column changed type is skipped here as the cell skips it.
        if columnIndex < columnDisplayFormats.count, let format = columnDisplayFormats[columnIndex], format != .raw,
           format.isApplicable(to: columnType, databaseType: databaseType),
           let formatted = ValueDisplayFormatter.apply(value, format: format, columnType: columnType) {
            return formatted
        }

        return BlobFormattingService.shared.formatIfNeeded(value, columnType: columnType, for: .copy)
    }

    // The statements leave out the columns the server owns, which only the schema names, so they wait for it as Duplicate does.
    var canCopyRowsAsInsert: Bool {
        guard let databaseType, databaseType != .mongodb, databaseType != .redis, tableName != nil else { return false }
        return tableRowsProvider().hasAuthoritativeSchema
    }

    // A table without a key is matched on every column, so one no match can compare leaves nothing to find the row by.
    var canCopyRowsAsUpdate: Bool {
        guard canCopyRowsAsInsert else { return false }
        return !primaryKeyColumns.isEmpty || tableRowsProvider().rowMatchPolicy.excludedColumns.isEmpty
    }

    func copyRowsAsInsert(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRowsAsInsert(at: indices)
        }) else { return }
        let tableRows = tableRowsProvider()
        let projection = selectedColumnProjection()
        let driver = resolveDriver()
        do {
            let converter = try SQLRowToStatementConverter(
                tableName: tableName,
                schemaName: schemaName,
                columns: projection.columns(tableRows.columns),
                primaryKeyColumns: primaryKeyColumns,
                databaseType: databaseType,
                unwritableColumns: unwritableColumns(in: tableRows),
                quoteIdentifier: driver?.quoteIdentifier,
                escapeStringLiteral: driver?.escapeStringLiteral,
                identifierSpelling: copiedIdentifierSpelling(for: databaseType)
            )
            let rows = indices.sorted().compactMap(displayRow(at:)).map { row in
                SQLRowToStatementConverter.SourceRow(
                    values: projection.values(Array(row.values)),
                    defaultedColumns: projection.positions(of: stagedDefaults(of: row)),
                    expressionColumns: projection.positions(of: stagedExpressions(of: row))
                )
            }
            writeCopiedStatements(converter.generateInserts(rows: rows))
        } catch {
            rowActionsLogger.error("copyRowsAsInsert failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    /// Every column takes part: SET is limited to the selected or visible ones, but the row is found by all of its
    /// key, or with no key by every column it has, hidden ones included, as it is stored rather than as edited.
    func copyRowsAsUpdate(at indices: Set<Int>) {
        guard let tableName, let databaseType else { return }
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRowsAsUpdate(at: indices)
        }) else { return }
        let tableRows = tableRowsProvider()
        let settable = selectionController.isEmpty ? visibleColumnProjection : selectedColumnProjection()
        let driver = resolveDriver()
        do {
            let converter = try SQLRowToStatementConverter(
                tableName: tableName,
                schemaName: schemaName,
                columns: tableRows.columns,
                primaryKeyColumns: primaryKeyColumns,
                databaseType: databaseType,
                unwritableColumns: unwritableColumns(in: tableRows),
                rowMatchPolicy: tableRows.rowMatchPolicy,
                settableColumns: settable.columns(tableRows.columns),
                quoteIdentifier: driver?.quoteIdentifier,
                escapeStringLiteral: driver?.escapeStringLiteral,
                identifierSpelling: copiedIdentifierSpelling(for: databaseType),
                rowUpdateStatement: driver?.rowUpdateStatement
            )
            let rows = indices.sorted().compactMap { displayRow(at: $0).map(copiedSourceRow) }
            writeCopiedStatements(converter.generateUpdates(rows: rows))
        } catch {
            rowActionsLogger.error("copyRowsAsUpdate failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func copiedIdentifierSpelling(for databaseType: DatabaseType) -> SQLIdentifierSpelling? {
        guard let rules = databaseType.identifierRules else { return nil }
        return SQLIdentifierSpelling(rules: rules, policy: SQLIdentifierCase.stored(for: connectionId))
    }

    private func unwritableColumns(in tableRows: TableRows) -> Set<String> {
        Set(tableRows.columns.filter { tableRows.generatedColumns.contains($0) || !isColumnWritable($0) })
    }

    private func copiedSourceRow(_ row: Row) -> SQLRowToStatementConverter.SourceRow {
        var stored = Array(row.values)
        let pendingUpdate = changeManager.rowChanges.first { $0.rowID == row.id && $0.type == .update }
        for cellChange in pendingUpdate?.cellChanges ?? [] where stored.indices.contains(cellChange.columnIndex) {
            stored[cellChange.columnIndex] = cellChange.oldValue
        }
        return SQLRowToStatementConverter.SourceRow(
            values: Array(row.values),
            storedValues: stored,
            isPendingInsert: changeManager.insertedRowIDs.contains(row.id),
            defaultedColumns: stagedDefaults(of: row),
            expressionColumns: stagedExpressions(of: row)
        )
    }

    /// The cells the grid itself set to the server's default: every marker in a row not saved yet, and in a saved row
    /// the cells a pending edit set to Default. Anything else that reads `__DEFAULT__` is what the table holds.
    private func stagedDefaults(of row: Row) -> Set<Int> {
        let marker = PluginCellValue.text("__DEFAULT__")
        if changeManager.insertedRowIDs.contains(row.id) {
            return Set(row.values.indices.filter { row.values[$0] == marker })
        }
        let pendingUpdate = changeManager.rowChanges.first { $0.rowID == row.id && $0.type == .update }
        return Set(pendingUpdate?.cellChanges.filter { $0.newValue == marker }.map(\.columnIndex) ?? [])
    }

    private func stagedExpressions(of row: Row) -> Set<Int> {
        changeManager.expressionColumns(forRow: row.id)
    }

    /// A copy that produced no statement leaves the clipboard as it was, rather than replacing it with nothing.
    private func writeCopiedStatements(_ statements: String) {
        guard !statements.isEmpty else { return }
        ClipboardService.shared.writeText(statements)
    }

    func copyRowsAsJson(at indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRowsAsJson(at: indices)
        }) else { return }
        let tableRows = tableRowsProvider()
        let projection = selectedColumnProjection()
        let displayIndices = clipboardDisplayIndices(indices)
        let output = ResultJsonSerializer.serialize(
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: Set(displayIndices),
            columns: projection
        )
        guard output.rowCount > 0 else { return }
        let copied = displayIndices.compactMap(displayRow(at:))
        ClipboardService.shared.writeText(
            output.json,
            gridRows: rowsPayload(copied, columns: projection.columns(tableRows.columns), projection: projection)
        )
    }

    func copyRowsAsCsv(at indices: Set<Int>, includeHeaders: Bool) {
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRowsAsCsv(at: indices, includeHeaders: includeHeaders)
        }) else { return }
        let projection = selectedColumnProjection()
        let copied = clipboardDisplayIndices(indices).compactMap(displayRow(at:))
        guard !copied.isEmpty else { return }
        let tableRows = tableRowsProvider()
        let columns = projection.columns(tableRows.columns)
        let converter = CsvRowConverter(columns: columns, columnTypes: projection.columnTypes(tableRows.columnTypes))
        ClipboardService.shared.writeCsv(
            converter.generateCsv(rows: copied.map { projection.values(Array($0.values)) }, includeHeaders: includeHeaders),
            gridRows: rowsPayload(copied, columns: columns, projection: projection)
        )
    }

    func copyRowsAsMarkdown(at indices: Set<Int>) {
        guard unloadedValuesAreLoaded(displayRows: indices, retry: { [weak self] in
            self?.copyRowsAsMarkdown(at: indices)
        }) else { return }
        let projection = selectedColumnProjection()
        let copied = clipboardDisplayIndices(indices).compactMap(displayRow(at:))
        guard !copied.isEmpty else { return }
        let tableRows = tableRowsProvider()
        let columns = projection.columns(tableRows.columns)
        let converter = MarkdownTableConverter(columns: columns, columnTypes: projection.columnTypes(tableRows.columnTypes))
        ClipboardService.shared.writeText(
            converter.generateMarkdown(rows: copied.map { projection.values(Array($0.values)) }),
            gridRows: rowsPayload(copied, columns: columns, projection: projection)
        )
    }

    func copyRowsAsInClause(at indices: Set<Int>, columnIndex: Int) {
        guard unloadedValuesAreLoaded(displayRows: indices, columns: IndexSet(integer: columnIndex), retry: { [weak self] in
            self?.copyRowsAsInClause(at: indices, columnIndex: columnIndex)
        }) else { return }
        let rows: [[PluginCellValue]] = indices.sorted().compactMap { displayRow(at: $0).map { Array($0.values) } }
        guard !rows.isEmpty else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let driver = resolveDriver()
        let converter = InClauseConverter(
            columnIndex: columnIndex,
            columnTypes: tableRows.columnTypes,
            escapeStringLiteral: driver?.escapeStringLiteral,
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType)
        )
        ClipboardService.shared.writeText(converter.generateInClause(rows: rows))
    }

    func copyColumnValues(columnIndex: Int) {
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let totalRows = displayIDs?.count ?? tableRows.rows.count
        let rowCount = min(totalRows, PluginRowLimits.emergencyMax)
        guard rowCount > 0 else { return }
        guard unloadedValuesAreLoaded(displayRows: 0..<rowCount, columns: IndexSet(integer: columnIndex), retry: { [weak self] in
            self?.copyColumnValues(columnIndex: columnIndex)
        }) else { return }

        let columnType = tableRows.columnTypes.indices.contains(columnIndex)
            ? tableRows.columnTypes[columnIndex]
            : nil

        var lines: [String] = []
        lines.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            guard let row = displayRow(at: rowIndex), row.values.indices.contains(columnIndex) else { continue }
            let text = RowValueCopyFormatter.copyText(cell: row.values[columnIndex], columnType: columnType) ?? "NULL"
            lines.append(text)
        }
        guard !lines.isEmpty else { return }
        ClipboardService.shared.writeText(lines.joined(separator: "\n"))
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

    private var visibleColumnProjection: VisibleColumnProjection {
        VisibleColumnProjection(indices: visibleColumnDataIndices())
    }

    /// The selection's columns as data indices, already in display order because that is the order
    /// its display positions run in.
    private func selectedColumnProjection() -> VisibleColumnProjection {
        guard !selectionController.isEmpty else { return visibleColumnProjection }
        let ordered = dataColumnIndices(in: selectionController.selection.affectedColumns)
        return ordered.isEmpty ? visibleColumnProjection : VisibleColumnProjection(indices: ordered)
    }

    func resolveDriver() -> (any DatabaseDriver)? {
        guard let connectionId else { return nil }
        return DatabaseManager.shared.driver(for: connectionId)
    }

    // MARK: - Row Drag and Drop

    private static let rowDragType = NSPasteboard.PasteboardType("com.TablePro.rowDrag")

    /// Writes the reorder type only where a reorder can actually run. The text and HTML flavours
    /// are written either way: dragging a row into another app is a copy, and it stays available on
    /// an engine whose columns cannot move.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard delegate != nil else { return nil }
        let item = NSPasteboardItem()
        if rowReorder.isEnabled {
            item.setString(String(row), forType: Self.rowDragType)
        }

        if let values = displayRow(at: row)?.values {
            let tableRows = tableRowsProvider()
            let projection = visibleColumnProjection
            let formatted = formatRowValues(
                values: projection.values(Array(values)),
                columnTypes: projection.columnTypes(tableRows.columnTypes)
            )
            item.setString(formatted.joined(separator: "\t"), forType: .string)
            item.setString(
                HtmlTableEncoder.encode(rows: [formatted], headers: projection.columns(tableRows.columns)),
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
        guard delegate != nil, rowReorder.isEnabled else { return [] }
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
        guard let delegate, rowReorder.isEnabled else { return false }
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowString = item.string(forType: Self.rowDragType),
              let fromRow = Int(rowString) else {
            return false
        }
        guard fromRow != row && fromRow != row - 1 else { return false }
        delegate.dataGridMoveRow(from: fromRow, to: row)
        return true
    }

    /// The header hands over the data index of the column it drew; a selection is built from
    /// display positions, so the two are translated here rather than inside the controller.
    func selectColumn(_ dataColumnIndex: Int) {
        guard let position = displayPosition(ofDataColumnIndex: dataColumnIndex) else { return }
        let totalRows = displayIDs?.count ?? tableRowsProvider().rows.count
        selectionController.selectEntireColumn(position, totalRows: totalRows)
        if let keyTableView = tableView as? KeyHandlingTableView {
            keyTableView.deselectAll(nil)
        }
    }

    func extendColumnSelection(_ dataColumnIndex: Int) {
        guard let position = displayPosition(ofDataColumnIndex: dataColumnIndex) else { return }
        let totalRows = displayIDs?.count ?? tableRowsProvider().rows.count
        selectionController.addEntireColumn(position, totalRows: totalRows)
        if let keyTableView = tableView as? KeyHandlingTableView {
            keyTableView.deselectAll(nil)
        }
    }

    /// Copies the selected block in the order the user is looking at it.
    ///
    /// The rect's column axis is display positions, so the walk is over positions and each one is
    /// resolved to its data index before a value is read. Walking the rect as though its bounds were
    /// data indices copied whatever slots happened to lie between them, which after a column reorder
    /// is not the block that was swept and can include a column the user hid.
    func copyGridSelection(_ selection: GridSelection) {
        guard let rect = selection.boundingRectangle else { return }
        if rect.rows.count == 1, rect.columns.count == 1,
           let dataColumn = dataColumnIndex(atDisplayPosition: rect.columns.lowerBound) {
            copyCellValue(at: rect.rows.lowerBound, columnIndex: dataColumn)
            return
        }

        let tableRows = tableRowsProvider()
        let columnTypes = tableRows.columnTypes
        let rowCount = displayIDs?.count ?? tableRows.rows.count

        /// The same ceiling the row copy has always had. Copy reads the cell selection first, so a
        /// Select All that keeps its rectangle now arrives here instead of on the row path, and
        /// without this a Fetch All over millions of rows builds the whole string on the main
        /// thread. (#2667)
        let maxRows = RowOperationsManager.maxClipboardRows
        let selectedRowCount = min(rect.rows.upperBound, rowCount - 1) - rect.rows.lowerBound + 1
        let lastRow = min(
            rect.rows.upperBound,
            max(0, rowCount - 1),
            rect.rows.lowerBound + maxRows - 1
        )
        let rowRange = rect.rows.lowerBound...lastRow
        let positions = Array(rect.columns.lowerBound...rect.columns.upperBound)
            .filter { $0 >= 0 && $0 < presentedColumnCount }
        guard rowRange.lowerBound <= rowRange.upperBound, !positions.isEmpty else { return }
        let copiedColumns = IndexSet(positions.compactMap { dataColumnIndex(atDisplayPosition: $0) })
        guard unloadedValuesAreLoaded(displayRows: rowRange, columns: copiedColumns, retry: { [weak self] in
            self?.copyGridSelection(selection)
        }) else { return }
        let isTruncated = selectedRowCount > maxRows
        if isTruncated {
            rowActionsLogger.warning("Clipboard copy truncated: \(selectedRowCount) rows selected, capping at \(maxRows)")
        }

        var copiedLines: [[String?]] = []
        copiedLines.reserveCapacity(rowRange.count)
        var expressionFields: [Int: Set<Int>] = [:]
        for rowIndex in rowRange {
            guard let row = displayRow(at: rowIndex) else {
                copiedLines.append(Array(repeating: "", count: positions.count))
                continue
            }
            let expressionColumns = changeManager.expressionColumns(forRow: row.id)
            var fields: [String?] = []
            fields.reserveCapacity(positions.count)
            for position in positions {
                guard selection.contains(row: rowIndex, displayColumn: position),
                      let columnIndex = dataColumnIndex(atDisplayPosition: position),
                      row.values.indices.contains(columnIndex) else {
                    fields.append("")
                    continue
                }
                let cell = row.values[columnIndex]
                if expressionColumns.contains(columnIndex), let sql = cell.asText {
                    expressionFields[copiedLines.count, default: []].insert(fields.count)
                    fields.append(sql)
                    continue
                }
                let columnType = columnTypes.indices.contains(columnIndex) ? columnTypes[columnIndex] : nil
                fields.append(RowValueCopyFormatter.copyText(cell: cell, columnType: columnType))
            }
            copiedLines.append(fields)
        }

        var text = copiedLines.map { $0.map { $0 ?? "NULL" }.joined(separator: "\t") }.joined(separator: "\n")
        if isTruncated {
            text.append("\n(truncated, showing first \(maxRows) of \(selectedRowCount) rows)")
        }
        ClipboardService.shared.writeCells(GridCellsClipboardPayload(
            text: text,
            fields: copiedLines,
            expressionFields: expressionFields.isEmpty ? nil : expressionFields
        ))
    }
}
