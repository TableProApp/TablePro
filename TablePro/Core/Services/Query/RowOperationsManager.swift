import AppKit
import Foundation
import os
import TableProPluginKit

@MainActor
final class RowOperationsManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowOperationsManager")

    private static let maxClipboardRows = 50_000

    struct AddNewRowResult {
        let rowIndex: Int
        let values: [PluginCellValue]
        let delta: Delta
    }

    struct DeleteRowsResult {
        let nextRowToSelect: Int
        let physicallyRemovedIndices: [Int]
        let delta: Delta
    }

    struct PastedRowInfo {
        let rowIndex: Int
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

    struct UndoInsertRowResult {
        let adjustedSelection: Set<Int>
        let delta: Delta
    }

    private let changeManager: DataChangeManager

    init(changeManager: DataChangeManager) {
        self.changeManager = changeManager
    }

    func addNewRow(
        columns: [String],
        columnDefaults: [String: String?],
        tableRows: inout TableRows
    ) -> AddNewRowResult? {
        var newRowValues: [PluginCellValue] = []
        for column in columns {
            if let defaultValue = columnDefaults[column], defaultValue != nil {
                newRowValues.append(.text("__DEFAULT__"))
            } else {
                newRowValues.append(.null)
            }
        }

        let newRowIndex = tableRows.count
        let delta = tableRows.appendInsertedRow(values: newRowValues)

        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newRowValues)

        return AddNewRowResult(rowIndex: newRowIndex, values: newRowValues, delta: delta)
    }

    func duplicateRow(
        sourceRowIndex: Int,
        columns: [String],
        tableRows: inout TableRows
    ) -> AddNewRowResult? {
        guard sourceRowIndex >= 0, sourceRowIndex < tableRows.count else { return nil }

        var newValues = Array(tableRows.rows[sourceRowIndex].values)

        for pkColumn in changeManager.primaryKeyColumns {
            if let pkIndex = columns.firstIndex(of: pkColumn), pkIndex < newValues.count {
                newValues[pkIndex] = .text("__DEFAULT__")
            }
        }

        let newRowIndex = tableRows.count
        let delta = tableRows.appendInsertedRow(values: newValues)

        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newValues)

        return AddNewRowResult(rowIndex: newRowIndex, values: newValues, delta: delta)
    }

    func deleteSelectedRows(
        selectedIndices: Set<Int>,
        tableRows: inout TableRows
    ) -> DeleteRowsResult {
        guard !selectedIndices.isEmpty else {
            return DeleteRowsResult(nextRowToSelect: -1, physicallyRemovedIndices: [], delta: .none)
        }

        var insertedRowsToDelete: [Int] = []
        var existingRowsToDelete: [(rowIndex: Int, originalRow: [PluginCellValue])] = []

        let minSelectedRow = selectedIndices.min() ?? 0
        let maxSelectedRow = selectedIndices.max() ?? 0

        for rowIndex in selectedIndices.sorted(by: >) {
            if changeManager.isRowInserted(rowIndex) {
                insertedRowsToDelete.append(rowIndex)
            } else if !changeManager.isRowDeleted(rowIndex) {
                if rowIndex < tableRows.count {
                    existingRowsToDelete.append((rowIndex: rowIndex, originalRow: Array(tableRows.rows[rowIndex].values)))
                }
            }
        }

        let sortedInsertedRows = insertedRowsToDelete.sorted(by: >)

        var delta: Delta = .none
        if !sortedInsertedRows.isEmpty {
            delta = tableRows.remove(at: IndexSet(sortedInsertedRows))
            changeManager.undoBatchRowInsertion(rowIndices: sortedInsertedRows)
        }

        if !existingRowsToDelete.isEmpty {
            changeManager.recordBatchRowDeletion(rows: existingRowsToDelete)
        }

        let totalRows = tableRows.count
        let rowsDeleted = sortedInsertedRows.count
        let adjustedMaxRow = maxSelectedRow - rowsDeleted
        let adjustedMinRow = minSelectedRow - sortedInsertedRows.count(where: { $0 < minSelectedRow })

        let nextRow: Int
        if adjustedMaxRow + 1 < totalRows {
            nextRow = min(adjustedMaxRow + 1, totalRows - 1)
        } else if adjustedMinRow > 0 {
            nextRow = adjustedMinRow - 1
        } else if totalRows > 0 {
            nextRow = 0
        } else {
            nextRow = -1
        }

        return DeleteRowsResult(
            nextRowToSelect: nextRow,
            physicallyRemovedIndices: sortedInsertedRows,
            delta: delta
        )
    }

    func applyUndoResult(_ result: UndoResult, tableRows: inout TableRows) -> UndoApplicationResult {
        switch result.action {
        case .cellEdit(let rowIndex, let columnIndex, _, let previousValue, _, _):
            let delta = tableRows.edit(row: rowIndex, column: columnIndex, value: previousValue)
            return UndoApplicationResult(adjustedSelection: nil, delta: delta)

        case .rowInsertion(let rowIndex):
            if result.needsRowRemoval {
                guard rowIndex >= 0, rowIndex < tableRows.count else {
                    return UndoApplicationResult(adjustedSelection: nil, delta: .none)
                }
                let delta = tableRows.remove(at: IndexSet(integer: rowIndex))
                return UndoApplicationResult(adjustedSelection: Set<Int>(), delta: delta)
            } else if result.needsRowRestore {
                let columnCount = tableRows.columns.count
                let values = result.restoreRow ?? [PluginCellValue](repeating: .null, count: columnCount)
                let delta = tableRows.insertInsertedRow(at: rowIndex, values: values)
                return UndoApplicationResult(adjustedSelection: nil, delta: delta)
            }
            return UndoApplicationResult(adjustedSelection: nil, delta: .none)

        case .rowDeletion:
            return UndoApplicationResult(adjustedSelection: nil, delta: result.delta)

        case .batchRowDeletion:
            return UndoApplicationResult(adjustedSelection: nil, delta: result.delta)

        case .batchRowInsertion(let rowIndices, let rowValues):
            if result.needsRowRemoval {
                let validIndices = IndexSet(rowIndices.filter { $0 >= 0 && $0 < tableRows.count })
                guard !validIndices.isEmpty else {
                    return UndoApplicationResult(adjustedSelection: nil, delta: .none)
                }
                let delta = tableRows.remove(at: validIndices)
                return UndoApplicationResult(adjustedSelection: nil, delta: delta)
            } else if result.needsRowRestore {
                var insertedIndices = IndexSet()
                let pairs = zip(rowIndices, rowValues).sorted { $0.0 < $1.0 }
                for (rowIndex, values) in pairs {
                    guard rowIndex >= 0, rowIndex <= tableRows.count else { continue }
                    _ = tableRows.insertInsertedRow(at: rowIndex, values: values)
                    insertedIndices.insert(rowIndex)
                }
                guard !insertedIndices.isEmpty else {
                    return UndoApplicationResult(adjustedSelection: nil, delta: .none)
                }
                return UndoApplicationResult(adjustedSelection: nil, delta: .rowsInserted(insertedIndices))
            }
            return UndoApplicationResult(adjustedSelection: nil, delta: .none)
        }
    }

    func undoInsertRow(
        at rowIndex: Int,
        tableRows: inout TableRows,
        selectedIndices: Set<Int>
    ) -> UndoInsertRowResult {
        guard rowIndex >= 0 && rowIndex < tableRows.count else {
            return UndoInsertRowResult(adjustedSelection: selectedIndices, delta: .none)
        }

        let delta = tableRows.remove(at: IndexSet(integer: rowIndex))

        var adjustedSelection = Set<Int>()
        for idx in selectedIndices {
            if idx == rowIndex {
                continue
            } else if idx > rowIndex {
                adjustedSelection.insert(idx - 1)
            } else {
                adjustedSelection.insert(idx)
            }
        }

        return UndoInsertRowResult(adjustedSelection: adjustedSelection, delta: delta)
    }

    func copySelectedRowsToClipboard(
        selectedIndices: Set<Int>,
        tableRows: TableRows,
        includeHeaders: Bool = false
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

        let columnCount = tableRows.rows.first?.values.count ?? 1
        let estimatedRowLength = columnCount * 12
        var result = ""
        result.reserveCapacity(indicesToCopy.count * estimatedRowLength)

        if includeHeaders, !tableRows.columns.isEmpty {
            for (colIdx, col) in tableRows.columns.enumerated() {
                if colIdx > 0 { result.append("\t") }
                result.append(col)
            }
        }

        for rowIndex in indicesToCopy {
            guard rowIndex < tableRows.count else { continue }
            if !result.isEmpty { result.append("\n") }
            for (colIdx, cell) in tableRows.rows[rowIndex].values.enumerated() {
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

        ClipboardService.shared.writeRows(tsv: result, html: nil)
    }

    func pasteRowsFromClipboard(
        columns: [String],
        primaryKeyColumns: [String],
        tableRows: inout TableRows,
        clipboard: ClipboardProvider? = nil,
        parser: RowDataParser? = nil
    ) -> PasteRowsResult {
        let clipboardProvider = clipboard ?? ClipboardService.shared
        guard let clipboardText = clipboardProvider.readText() else {
            return PasteRowsResult(pastedRows: [], delta: .none)
        }

        let schema = TableSchema(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns
        )

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

    static func detectParser(for text: String) -> RowDataParser {
        var tabLines = 0
        var commaLines = 0
        var nonEmptyLines = 0
        var lineHasTab = false
        var lineHasComma = false
        var lineIsEmpty = true

        for char in text {
            if char.isNewline {
                if !lineIsEmpty {
                    nonEmptyLines += 1
                    if lineHasTab { tabLines += 1 }
                    if lineHasComma { commaLines += 1 }
                }
                lineHasTab = false
                lineHasComma = false
                lineIsEmpty = true
            } else {
                if !char.isWhitespace { lineIsEmpty = false }
                if char == "\t" { lineHasTab = true }
                if char == "," { lineHasComma = true }
            }
        }
        if !lineIsEmpty {
            nonEmptyLines += 1
            if lineHasTab { tabLines += 1 }
            if lineHasComma { commaLines += 1 }
        }

        guard nonEmptyLines > 0 else { return TSVRowParser() }

        let tabCount = tabLines
        let commaCount = commaLines

        if tabCount > commaCount {
            return TSVRowParser()
        } else if commaCount > 0 {
            return CSVRowParser()
        }
        return TSVRowParser()
    }

    private func insertParsedRows(
        _ parsedRows: [ParsedRow],
        into tableRows: inout TableRows
    ) -> PasteRowsResult {
        var pastedRowInfo: [PastedRowInfo] = []
        var insertedIndices = IndexSet()

        for parsedRow in parsedRows {
            let rowValues = parsedRow.values
            let newRowIndex = tableRows.count
            _ = tableRows.appendInsertedRow(values: rowValues)
            insertedIndices.insert(newRowIndex)

            changeManager.recordRowInsertion(rowIndex: newRowIndex, values: rowValues)

            pastedRowInfo.append(PastedRowInfo(rowIndex: newRowIndex, values: rowValues))
        }

        let delta: Delta = insertedIndices.isEmpty ? .none : .rowsInserted(insertedIndices)
        return PasteRowsResult(pastedRows: pastedRowInfo, delta: delta)
    }
}
