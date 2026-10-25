//
//  DataGridCommands+Copy.swift
//  TablePro
//

import AppKit
import os
import TableProPluginKit

private let copyLogger = Logger(subsystem: "com.TablePro", category: "DataGridCopy")

extension DataGridCommands {
    var rowCopyFormat: RowCopyFormat {
        configuration.appliesRowCopyFormat ? AppSettingsManager.shared.dataGrid.rowCopyFormat : .rows
    }

    func canCopy(_ scope: DataGridCommandScope) -> Bool {
        !scope.selection.isEmpty && !rowIDs(scope).isEmpty
    }

    // Copies the cursor's cell when a click selected one row, rows in the Row Copy Format when rows were picked or
    // several are selected, and a range as typed fields.
    func copy(_ scope: DataGridCommandScope) {
        let selection = scope.selection
        guard !selection.isEmpty else { return }
        if !scope.isRowHeader, selection.mode == .cursor, selection.affectedRows.count == 1,
           let focus = scope.focus ?? selection.activeCell, let cell = commandCell(at: focus) {
            copyCellValue(cell)
            return
        }
        if scope.isRowHeader || isWholeRows(selection) {
            copyRows(scope, as: rowCopyFormat)
            return
        }
        if selection.uniqueCellCount == 1, let cell = cells(scope).first {
            copyCellValue(cell)
            return
        }
        copyRange(selection)
    }

    // MARK: - Rows

    // The ceiling each format's converter already puts on its text, taken first so the paste payload holds the same rows.
    private func capped(_ rowIDs: [RowID]) -> [RowID] {
        let limit = RowOperationsManager.maxClipboardRows
        guard rowIDs.count > limit else { return rowIDs }
        copyLogger.warning("Clipboard copy truncated: \(rowIDs.count) rows selected, capping at \(limit)")
        return Array(rowIDs.prefix(limit))
    }

    var visibleProjection: VisibleColumnProjection {
        VisibleColumnProjection(indices: model.columns.columns.map(\.dataIndex))
    }

    func selectedProjection(_ scope: DataGridCommandScope) -> VisibleColumnProjection {
        VisibleColumnProjection(indices: selectedColumns(scope).map(\.dataIndex))
    }

    func copyRows(_ scope: DataGridCommandScope, as format: RowCopyFormat) {
        let ids = rowIDs(scope)
        guard !ids.isEmpty else { return }
        guard loader.ensureLoaded(ids, columns: nil, in: model, retry: {
            // The scope names display positions, so it runs again only while they show the same records.
            guard rowIDs(scope) == ids else {
                NSSound.beep()
                return
            }
            copyRows(scope, as: format)
        }) else { return }
        switch format {
        case .rows:
            // An owner that writes its own pasteboard type (staged SQL, structure definitions) answers first.
            if model.actions?.gridCopyRows(ids) == true { return }
            writeTSV(ids, includeHeaders: false)
        case .rowsWithHeaders:
            writeTSV(ids, includeHeaders: true)
        case .json:
            writeJSON(ids, projection: selectedProjection(scope))
        case .csv:
            writeCSV(ids, projection: selectedProjection(scope), includeHeaders: false)
        case .csvWithHeaders:
            writeCSV(ids, projection: selectedProjection(scope), includeHeaders: true)
        case .markdown:
            writeMarkdown(ids, projection: selectedProjection(scope))
        }
    }

    private func copiedRows(_ ids: [RowID]) -> [Row] {
        let rows = model.rows
        return capped(ids).compactMap { rows.row(withID: $0) }
    }

    // Carried by every row copy, so a paste into a grid takes the rows rather than parsing the text.
    private func rowsPayload(_ rows: [Row], projection: VisibleColumnProjection) -> GridRowsClipboardPayload {
        let changeState = model.changeState
        return GridRowsClipboardPayload(
            columns: projection.columns(model.rows.columns),
            copying: rows,
            expressionColumns: rows.map { changeState?.expressionColumns(forRow: $0.id) ?? [] },
            projection: projection
        )
    }

    private func writeTSV(_ ids: [RowID], includeHeaders: Bool) {
        let copied = copiedRows(ids)
        guard !copied.isEmpty else { return }
        let tableRows = model.rows
        let projection = visibleProjection
        let columnTypes = projection.columnTypes(tableRows.columnTypes)
        let columns = projection.columns(tableRows.columns)
        var lines: [String] = includeHeaders ? [columns.joined(separator: "\t")] : []
        var htmlRows: [[String]] = []
        for row in copied {
            let formatted = Self.formatRowValues(projection.values(Array(row.values)), columnTypes: columnTypes)
            lines.append(formatted.joined(separator: "\t"))
            htmlRows.append(formatted)
        }
        let html = includeHeaders ? HtmlTableEncoder.encode(rows: htmlRows, headers: columns) : nil
        ClipboardService.shared.writeRows(
            tsv: lines.joined(separator: "\n"),
            html: html,
            gridRows: rowsPayload(copied, projection: projection)
        )
    }

    private func writeJSON(_ ids: [RowID], projection: VisibleColumnProjection) {
        let copied = copiedRows(ids)
        let displayIndices = Set(copied.compactMap { model.displayIndex(of: $0.id) })
        guard !displayIndices.isEmpty else { return }
        let output = ResultJsonSerializer.serialize(
            tableRows: model.rows,
            displayIDs: model.order.filteredIDs,
            selectedDisplayIndices: displayIndices,
            columns: projection
        )
        guard output.rowCount > 0 else { return }
        ClipboardService.shared.writeText(output.json, gridRows: rowsPayload(copied, projection: projection))
    }

    private func writeCSV(_ ids: [RowID], projection: VisibleColumnProjection, includeHeaders: Bool) {
        let copied = copiedRows(ids)
        guard !copied.isEmpty else { return }
        let tableRows = model.rows
        let converter = CsvRowConverter(
            columns: projection.columns(tableRows.columns),
            columnTypes: projection.columnTypes(tableRows.columnTypes)
        )
        ClipboardService.shared.writeCsv(
            converter.generateCsv(rows: copied.map { projection.values(Array($0.values)) }, includeHeaders: includeHeaders),
            gridRows: rowsPayload(copied, projection: projection)
        )
    }

    private func writeMarkdown(_ ids: [RowID], projection: VisibleColumnProjection) {
        let copied = copiedRows(ids)
        guard !copied.isEmpty else { return }
        let tableRows = model.rows
        let converter = MarkdownTableConverter(
            columns: projection.columns(tableRows.columns),
            columnTypes: projection.columnTypes(tableRows.columnTypes)
        )
        ClipboardService.shared.writeText(
            converter.generateMarkdown(rows: copied.map { projection.values(Array($0.values)) }),
            gridRows: rowsPayload(copied, projection: projection)
        )
    }

    static func formatRowValues(_ values: [PluginCellValue], columnTypes: [ColumnType]) -> [String] {
        values.enumerated().map { index, cell in
            switch cell {
            case .null:
                return "NULL"
            case .text(let value):
                let columnType = columnTypes.indices.contains(index) ? columnTypes[index] : nil
                return BlobFormattingService.shared.formatIfNeeded(value, columnType: columnType, for: .copy)
            case .bytes(let data):
                return BlobFormattingService.shared.format(data, for: .copy) ?? ""
            }
        }
    }

    // MARK: - Statements

    // The one column a cell selection covers, else the focus cell's: the clicked one in a menu, the active one elsewhere.
    func inClauseColumn(_ scope: DataGridCommandScope) -> DataGridColumn? {
        guard !scope.isRowHeader else { return nil }
        if !isWholeRows(scope.selection) {
            let positions = scope.selection.affectedColumns
            if positions.count == 1, let only = positions.first {
                return model.columns.column(at: only)
            }
        }
        return scope.focus.flatMap { model.columns.column(at: $0.displayColumn) }
    }

    func copyRowsAsInClause(_ scope: DataGridCommandScope) {
        guard let column = inClauseColumn(scope) else { return }
        let ids = rowIDs(scope)
        guard !ids.isEmpty else { return }
        guard loader.ensureLoaded(ids, columns: IndexSet(integer: column.dataIndex), in: model, retry: {
            copyRowsAsInClause(scope)
        }) else { return }
        let tableRows = model.rows
        let values = ids.compactMap { tableRows.row(withID: $0)?[column.dataIndex] }
        guard !values.isEmpty else { return }
        // Without an owner's driver the engine's dialect escapes: MySQL and ClickHouse read a backslash as one.
        let text = model.actions?.gridSQLExporter?.inClause(values: values, column: column)
            ?? InClauseConverter(
                columnIndex: 0,
                columnTypes: [column.type ?? .text(rawType: nil)],
                escapeStringLiteral: configuration.traits.databaseType
                    .flatMap { try? resolveSQLDialect(for: $0) }
                    .map { escapeStringLiteralFromDialect($0) },
                stringLiteralPrefix: configuration.traits.stringLiteralPrefix
            ).generateInClause(rows: values.map { [$0] })
        guard !text.isEmpty else { return }
        ClipboardService.shared.writeText(text)
    }

    // The statements leave out the columns the server owns, which only the schema names.
    func canCopyAsInsert(_ scope: DataGridCommandScope) -> Bool {
        guard offers(.copyAsSQL), let exporter = model.actions?.gridSQLExporter else { return false }
        return exporter.canCopyAsInsert(model.rows) && !rowIDs(scope).isEmpty
    }

    func canCopyAsUpdate(_ scope: DataGridCommandScope) -> Bool {
        guard canCopyAsInsert(scope), let exporter = model.actions?.gridSQLExporter else { return false }
        return exporter.canCopyAsUpdate(model.rows)
    }

    // A copy that produced no statement leaves the clipboard as it was.
    func copyRowsAsStatements(_ scope: DataGridCommandScope, update: Bool) {
        guard update ? canCopyAsUpdate(scope) : canCopyAsInsert(scope),
              let exporter = model.actions?.gridSQLExporter else { return }
        let ids = rowIDs(scope)
        guard loader.ensureLoaded(ids, columns: nil, in: model, retry: {
            copyRowsAsStatements(scope, update: update)
        }) else { return }
        let columns = selectedColumns(scope)
        let statements = update
            ? exporter.updateStatements(for: ids, columns: columns, in: model.rows)
            : exporter.insertStatements(for: ids, columns: columns, in: model.rows)
        guard let statements, !statements.isEmpty else { return }
        ClipboardService.shared.writeText(statements)
    }

    // MARK: - Cells

    func copyCellValue(_ cell: DataGridCommandCell) {
        let dataIndex = cell.column.dataIndex
        guard loader.ensureLoaded([cell.rowID], columns: IndexSet(integer: dataIndex), in: model, retry: {
            copyCellValue(cell)
        }) else { return }
        guard let row = storedRow(cell.rowID), dataIndex < row.values.count else { return }
        let value = row.values[dataIndex]
        if model.changeState?.isExpression(rowID: row.id, columnIndex: dataIndex) == true, let sql = value.asText {
            ClipboardService.shared.writeCells(GridCellsClipboardPayload(text: sql, fields: [[sql]], expressionFields: [0: [0]]))
            return
        }
        let text = cellCopyText(value, column: cell.column)
        ClipboardService.shared.writeCells(GridCellsClipboardPayload(text: text, fields: [[value.isNull ? nil : text]]))
    }

    // One cell copies as the cell reads, its display format applied; a format saved before the column changed type is skipped.
    func cellCopyText(_ value: PluginCellValue, column: DataGridColumn) -> String {
        let format = model.displayFormat(for: column)
        let databaseType = configuration.traits.databaseType
        if case .bytes(let data) = value {
            return format.flatMap { format in
                guard format.isApplicable(to: column.type, databaseType: databaseType) else { return nil }
                return ValueDisplayFormatter.apply(data, format: format, columnType: column.type)
            }
                ?? BlobFormattingService.shared.format(data, for: .copy)
                ?? ""
        }
        let text = value.asText ?? "NULL"
        if let format, format != .raw,
           format.isApplicable(to: column.type, databaseType: databaseType),
           let formatted = ValueDisplayFormatter.apply(text, format: format, columnType: column.type) {
            return formatted
        }
        return BlobFormattingService.shared.formatIfNeeded(text, columnType: column.type, for: .copy)
    }

    // The block in the order the reader sees it, each field typed, NULL kept and staged SQL marked.
    func copyRange(_ selection: GridSelection) {
        guard let rect = selection.boundingRectangle else { return }
        let rowCount = model.rowCount
        let maxRows = RowOperationsManager.maxClipboardRows
        let lastRow = min(rect.rows.upperBound, max(0, rowCount - 1), rect.rows.lowerBound + maxRows - 1)
        let positions = Array(rect.columns).filter { $0 >= 0 && $0 < model.columns.count }
        guard rect.rows.lowerBound <= lastRow, !positions.isEmpty else { return }
        let rowRange = rect.rows.lowerBound...lastRow
        let selectedRowCount = min(rect.rows.upperBound, rowCount - 1) - rect.rows.lowerBound + 1
        let ids = rowRange.map { model.rowID(at: $0) }
        let copiedColumns = IndexSet(positions.compactMap { model.columns.dataIndex(atDisplayPosition: $0) })
        guard loader.ensureLoaded(ids.compactMap { $0 }, columns: copiedColumns, in: model, retry: {
            // The block names display positions, so it runs again only while they show the same records.
            guard rowRange.map({ model.rowID(at: $0) }) == ids else {
                NSSound.beep()
                return
            }
            copyRange(selection)
        }) else { return }

        let tableRows = model.rows
        let changeState = model.changeState
        let isTruncated = selectedRowCount > maxRows
        if isTruncated {
            copyLogger.warning("Clipboard copy truncated: \(selectedRowCount) rows selected, capping at \(maxRows)")
        }
        var lines: [[String?]] = []
        lines.reserveCapacity(rowRange.count)
        var expressionFields: [Int: Set<Int>] = [:]
        for displayRow in rowRange {
            guard let row = model.order.row(at: displayRow, in: tableRows) else {
                lines.append(Array(repeating: "", count: positions.count))
                continue
            }
            let expressions = changeState?.expressionColumns(forRow: row.id) ?? []
            var fields: [String?] = []
            fields.reserveCapacity(positions.count)
            for position in positions {
                guard selection.contains(row: displayRow, displayColumn: position),
                      let column = model.columns.column(at: position),
                      column.dataIndex < row.values.count else {
                    fields.append("")
                    continue
                }
                let cell = row.values[column.dataIndex]
                if expressions.contains(column.dataIndex), let sql = cell.asText {
                    expressionFields[lines.count, default: []].insert(fields.count)
                    fields.append(sql)
                    continue
                }
                fields.append(RowValueCopyFormatter.copyText(cell: cell, columnType: column.type))
            }
            lines.append(fields)
        }

        var text = lines.map { $0.map { $0 ?? "NULL" }.joined(separator: "\t") }.joined(separator: "\n")
        if isTruncated {
            text.append("\n(truncated, showing first \(maxRows) of \(selectedRowCount) rows)")
        }
        ClipboardService.shared.writeCells(GridCellsClipboardPayload(
            text: text,
            fields: lines,
            expressionFields: expressionFields.isEmpty ? nil : expressionFields
        ))
    }

    // MARK: - Columns

    func copyColumnValues(_ column: DataGridColumn) {
        let rowCount = min(model.rowCount, PluginRowLimits.emergencyMax)
        guard rowCount > 0 else { return }
        let tableRows = model.rows
        let ids = (0..<rowCount).compactMap { model.order.rowID(at: $0, in: tableRows) }
        guard loader.ensureLoaded(ids, columns: IndexSet(integer: column.dataIndex), in: model, retry: {
            copyColumnValues(column)
        }) else { return }
        let current = model.rows
        var lines: [String] = []
        lines.reserveCapacity(ids.count)
        for rowID in ids {
            guard let row = current.row(withID: rowID), column.dataIndex < row.values.count else { continue }
            lines.append(RowValueCopyFormatter.copyText(cell: row.values[column.dataIndex], columnType: column.type) ?? "NULL")
        }
        guard !lines.isEmpty else { return }
        ClipboardService.shared.writeText(lines.joined(separator: "\n"))
    }
}
