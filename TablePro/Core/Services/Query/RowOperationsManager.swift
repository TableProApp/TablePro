import AppKit
import Foundation
import os
import TableProPluginKit

@MainActor
final class RowOperationsManager {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RowOperationsManager")

    static let maxClipboardRows = 50_000

    struct AddNewRowResult {
        let rowID: RowID
        let values: [PluginCellValue]
        let delta: Delta
    }

    struct DeleteRowsResult {
        let nextRowToSelect: Int
        let physicallyRemovedIndices: [Int]
        let delta: Delta
        var stagedRowCount: Int = 0
    }

    struct PastedRowInfo {
        let rowID: RowID
        let values: [PluginCellValue]
    }

    struct PasteRowsResult {
        let pastedRows: [PastedRowInfo]
        let delta: Delta
    }

    struct UndoApplicationResult {
        let adjustedSelection: Set<Int>?
        let delta: Delta
    }

    private let changeManager: DataChangeManager

    init(changeManager: DataChangeManager) {
        self.changeManager = changeManager
    }

    func addNewRow(tableRows: inout TableRows) -> AddNewRowResult? {
        var newRowValues: [PluginCellValue] = []
        for column in tableRows.columns {
            if tableRows.generatedColumns.contains(column) || tableRows.serverAssignsValue(forColumn: column) {
                newRowValues.append(.text("__DEFAULT__"))
            } else {
                newRowValues.append(.null)
            }
        }
        return appendInsertedRow(values: newRowValues, to: &tableRows)
    }

    func duplicateRow(
        sourceRowIndex: Int,
        tableRows: inout TableRows
    ) -> AddNewRowResult? {
        guard sourceRowIndex >= 0, sourceRowIndex < tableRows.count else { return nil }

        var newValues = Array(tableRows.rows[sourceRowIndex].values)

        /// An identity column is not always the primary key, and copying its value verbatim is
        /// what the server rejects.
        let resetColumns = changeManager.primaryKeyColumns
            + Array(tableRows.generatedColumns)
            + Array(tableRows.columnIdentity.keys)
        for resetColumn in resetColumns {
            if let index = tableRows.columns.firstIndex(of: resetColumn), index < newValues.count {
                newValues[index] = .text("__DEFAULT__")
            }
        }
        return appendInsertedRow(values: newValues, to: &tableRows)
    }

    private func appendInsertedRow(values: [PluginCellValue], to tableRows: inout TableRows) -> AddNewRowResult {
        let rowID = RowID.inserted(UUID())
        let delta = tableRows.appendInsertedRow(id: rowID, values: values)
        changeManager.recordRowInsertion(rowID: rowID, values: values)
        return AddNewRowResult(rowID: rowID, values: values, delta: delta)
    }

    func deleteSelectedRows(
        selectedIndices: Set<Int>,
        displayIDs: [RowID]? = nil,
        tableRows: inout TableRows
    ) -> DeleteRowsResult {
        guard !selectedIndices.isEmpty else {
            return DeleteRowsResult(nextRowToSelect: -1, physicallyRemovedIndices: [], delta: .none)
        }

        let displayCountBefore = displayIDs?.count ?? tableRows.count
        var insertedRowsToRemove: [InsertedRowLocation] = []
        var existingRowsToDelete: [(rowID: RowID, originalRow: [PluginCellValue])] = []

        for displayIndex in selectedIndices.sorted(by: >) {
            guard let storageIndex = DisplayRowMapping.rowIndex(
                forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows
            ) else { continue }
            let row = tableRows.rows[storageIndex]
            if row.id.isInserted {
                insertedRowsToRemove.append(InsertedRowLocation(rowID: row.id, storageIndex: storageIndex))
            } else if !changeManager.isRowDeleted(row.id) {
                existingRowsToDelete.append((rowID: row.id, originalRow: Array(row.values)))
            }
        }

        var delta: Delta = .none
        if !insertedRowsToRemove.isEmpty {
            delta = tableRows.remove(at: IndexSet(insertedRowsToRemove.map(\.storageIndex)))
            changeManager.undoBatchRowInsertion(rows: insertedRowsToRemove)
        }

        if !existingRowsToDelete.isEmpty {
            changeManager.recordBatchRowDeletion(rows: existingRowsToDelete)
        }

        return DeleteRowsResult(
            nextRowToSelect: Self.nextRowToSelect(
                afterDeleting: selectedIndices,
                removedCount: insertedRowsToRemove.count,
                displayCountAfter: displayCountBefore - insertedRowsToRemove.count
            ),
            physicallyRemovedIndices: insertedRowsToRemove.map(\.storageIndex),
            delta: delta,
            stagedRowCount: insertedRowsToRemove.count + existingRowsToDelete.count
        )
    }

    private static func nextRowToSelect(
        afterDeleting selectedIndices: Set<Int>,
        removedCount: Int,
        displayCountAfter: Int
    ) -> Int {
        let minSelectedRow = selectedIndices.min() ?? 0
        let adjustedMaxRow = (selectedIndices.max() ?? 0) - removedCount
        if adjustedMaxRow + 1 < displayCountAfter {
            return adjustedMaxRow + 1
        }
        if minSelectedRow > 0 {
            return minSelectedRow - 1
        }
        return displayCountAfter > 0 ? 0 : -1
    }

    func applyUndoResult(_ result: UndoResult, tableRows: inout TableRows) -> UndoApplicationResult {
        switch result.action {
        case .cellEdit(let rowID, let columnIndex, _, let previousValue, _, _):
            guard let storageRow = tableRows.index(of: rowID) else {
                return UndoApplicationResult(adjustedSelection: nil, delta: .none)
            }
            let delta = tableRows.edit(row: storageRow, column: columnIndex, value: previousValue)
            return UndoApplicationResult(adjustedSelection: nil, delta: delta)

        case .rowInsertion(let rowID):
            if result.needsRowRemoval {
                let delta = tableRows.remove(rowIDs: [rowID])
                guard delta != .none else {
                    return UndoApplicationResult(adjustedSelection: nil, delta: .none)
                }
                return UndoApplicationResult(adjustedSelection: Set<Int>(), delta: delta)
            }
            if result.needsRowRestore {
                let values = result.restoreRow
                    ?? [PluginCellValue](repeating: .null, count: tableRows.columns.count)
                let delta = tableRows.appendInsertedRow(id: rowID, values: values)
                return UndoApplicationResult(adjustedSelection: nil, delta: delta)
            }
            return UndoApplicationResult(adjustedSelection: nil, delta: .none)

        case .rowDeletion, .batchRowDeletion:
            return UndoApplicationResult(adjustedSelection: nil, delta: result.delta)

        case .batchRowInsertion(let rows, let rowValues):
            if result.needsRowRemoval {
                let delta = tableRows.remove(rowIDs: Set(rows.map(\.rowID)))
                return UndoApplicationResult(adjustedSelection: nil, delta: delta)
            }
            if result.needsRowRestore {
                return UndoApplicationResult(
                    adjustedSelection: nil,
                    delta: restoreInsertedRows(rows, values: rowValues, into: &tableRows)
                )
            }
            return UndoApplicationResult(adjustedSelection: nil, delta: .none)
        }
    }

    private func restoreInsertedRows(
        _ rows: [InsertedRowLocation],
        values rowValues: [[PluginCellValue]],
        into tableRows: inout TableRows
    ) -> Delta {
        var insertedIndices = IndexSet()
        let ascending = zip(rows, rowValues).sorted { $0.0.storageIndex < $1.0.storageIndex }
        for (location, values) in ascending {
            let index = min(location.storageIndex, tableRows.count)
            guard tableRows.insertInsertedRow(at: index, id: location.rowID, values: values) != .none else {
                continue
            }
            insertedIndices.insert(index)
        }
        return insertedIndices.isEmpty ? .none : .rowsInserted(insertedIndices)
    }

    func copySelectedRowsToClipboard(
        selectedIndices: Set<Int>,
        tableRows: TableRows,
        displayIDs: [RowID]? = nil,
        includeHeaders: Bool = false,
        visibleColumnIndices: [Int]? = nil
    ) {
        guard !selectedIndices.isEmpty else { return }

        let sortedIndices = selectedIndices.sorted()
        let totalSelected = sortedIndices.count
        let isTruncated = totalSelected > Self.maxClipboardRows

        if isTruncated {
            Self.logger.warning(
                "Clipboard copy truncated: \(totalSelected) rows selected, capping at \(Self.maxClipboardRows)"
            )
        }

        let indicesToCopy = isTruncated ? Array(sortedIndices.prefix(Self.maxClipboardRows)) : sortedIndices

        let projection = VisibleColumnProjection(indices: visibleColumnIndices)
        let columns = projection.columns(tableRows.columns)
        let estimatedRowLength = max(columns.count, 1) * 12
        var result = ""
        result.reserveCapacity(indicesToCopy.count * estimatedRowLength)
        var structuredRows: [[PluginCellValue]] = []
        structuredRows.reserveCapacity(indicesToCopy.count)

        if includeHeaders, !columns.isEmpty {
            for (colIdx, col) in columns.enumerated() {
                if colIdx > 0 { result.append("\t") }
                result.append(col)
            }
        }

        for displayIndex in indicesToCopy {
            guard let row = DisplayRowMapping.row(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows)
            else { continue }
            if !result.isEmpty { result.append("\n") }
            let cells = projection.values(Array(row.values))
            structuredRows.append(cells)
            for (colIdx, cell) in cells.enumerated() {
                if colIdx > 0 { result.append("\t") }
                switch cell {
                case .null:
                    result.append("NULL")
                case .text(let s):
                    result.append(s)
                case .bytes(let data):
                    result.append(BlobFormattingService.shared.format(data, for: .copy) ?? "")
                }
            }
        }

        if isTruncated {
            result.append("\n(truncated, showing first \(Self.maxClipboardRows) of \(totalSelected) rows)")
        }

        let payload = GridRowsClipboardPayload(columns: columns, rows: structuredRows)
        ClipboardService.shared.writeRows(tsv: result, html: nil, gridRows: payload)
    }

    func pasteRowsFromClipboard(
        columns: [String],
        primaryKeyColumns: [String],
        tableRows: inout TableRows,
        clipboard: ClipboardProvider? = nil,
        parser: RowDataParser? = nil
    ) -> PasteRowsResult {
        let clipboardProvider = clipboard ?? ClipboardService.shared
        let schema = TableSchema(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns
        )

        if parser == nil, let payload = clipboardProvider.readGridRows() {
            let parsedRows = Self.reconcileStructuredRows(payload, schema: schema)
            return insertParsedRows(parsedRows, into: &tableRows)
        }

        guard let clipboardText = clipboardProvider.readText() else {
            return PasteRowsResult(pastedRows: [], delta: .none)
        }

        let rowParser = parser ?? Self.detectParser(for: clipboardText)
        let parseResult = rowParser.parse(clipboardText, schema: schema)

        switch parseResult {
        case .success(let parsedRows):
            return insertParsedRows(parsedRows, into: &tableRows)

        case .failure(let error):
            Self.logger.warning("Paste failed: \(error.localizedDescription)")
            return PasteRowsResult(pastedRows: [], delta: .none)
        }
    }

    private static func reconcileStructuredRows(
        _ payload: GridRowsClipboardPayload,
        schema: TableSchema
    ) -> [ParsedRow] {
        let sourceForDestination = sourceColumnIndices(from: payload.columns, to: schema.columns)

        return payload.rows.enumerated().map { index, row in
            var values: [PluginCellValue] = sourceForDestination.map { sourceIndex in
                guard let sourceIndex, sourceIndex < row.count else { return .null }
                return row[sourceIndex]
            }

            if let pkIndex = schema.primaryKeyIndex, pkIndex < values.count {
                values[pkIndex] = .text("__DEFAULT__")
            }

            return ParsedRow(values: values, sourceLineNumber: index + 1)
        }
    }

    private static func sourceColumnIndices(from source: [String], to destination: [String]) -> [Int?] {
        var sourceIndexByName: [String: Int] = [:]
        for (index, name) in source.enumerated() where sourceIndexByName[name] == nil {
            sourceIndexByName[name] = index
        }

        let byName = destination.map { sourceIndexByName[$0] }
        guard byName.allSatisfy({ $0 == nil }) else { return byName }

        return destination.indices.map { $0 < source.count ? $0 : nil }
    }

    static func detectParser(for text: String) -> RowDataParser {
        var containsTab = false
        var containsComma = false

        for char in text {
            if char == "\t" {
                containsTab = true
                break
            }
            if char == "," { containsComma = true }
        }

        if containsTab {
            return TSVRowParser()
        }
        return containsComma ? CSVRowParser() : TSVRowParser()
    }

    private func insertParsedRows(
        _ parsedRows: [ParsedRow],
        into tableRows: inout TableRows
    ) -> PasteRowsResult {
        var pastedRowInfo: [PastedRowInfo] = []
        var insertedIndices = IndexSet()

        /// A pasted row arrives whole, so it carries values for columns the server owns too. They
        /// never reach the cell-edit boundary that refuses them, and the statement generator drops
        /// them silently, so the grid showed a pasted identity value the row was never saved with.
        let serverOwned = tableRows.columns.enumerated().filter { _, name in
            tableRows.generatedColumns.contains(name) || tableRows.columnIdentity[name] != nil
        }.map(\.offset)

        for parsedRow in parsedRows {
            var rowValues = parsedRow.values
            for index in serverOwned where index < rowValues.count {
                rowValues[index] = .text("__DEFAULT__")
            }
            insertedIndices.insert(tableRows.count)
            let inserted = appendInsertedRow(values: rowValues, to: &tableRows)
            pastedRowInfo.append(PastedRowInfo(rowID: inserted.rowID, values: rowValues))
        }

        let delta: Delta = insertedIndices.isEmpty ? .none : .rowsInserted(insertedIndices)
        return PasteRowsResult(pastedRows: pastedRowInfo, delta: delta)
    }
}
