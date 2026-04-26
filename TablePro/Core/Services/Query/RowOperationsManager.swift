//
//  RowOperationsManager.swift
//  TablePro
//
//  Service responsible for row operations: add, delete, duplicate.
//  Undo/redo is handled entirely by DataChangeManager's UndoManager closures.
//

import AppKit
import Foundation
import os

/// Manager for row operations in the data grid
@MainActor
final class RowOperationsManager {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowOperationsManager")

    /// Maximum number of rows that can be copied to clipboard to prevent OOM
    private static let maxClipboardRows = 50_000

    // MARK: - Dependencies

    private let changeManager: DataChangeManager

    // MARK: - Initialization

    init(changeManager: DataChangeManager) {
        self.changeManager = changeManager
    }

    // MARK: - Add Row

    func addNewRow(
        columns: [String],
        columnDefaults: [String: String?],
        rowBuffer: RowBuffer
    ) -> (rowIndex: Int, values: [String?])? {
        var newRowValues: [String?] = []
        for column in columns {
            if let defaultValue = columnDefaults[column], defaultValue != nil {
                newRowValues.append("__DEFAULT__")
            } else {
                newRowValues.append(nil)
            }
        }

        let newRowIndex = rowBuffer.rows.count
        rowBuffer.rows.append(newRowValues)

        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newRowValues)

        return (newRowIndex, newRowValues)
    }

    // MARK: - Duplicate Row

    func duplicateRow(
        sourceRowIndex: Int,
        columns: [String],
        rowBuffer: RowBuffer
    ) -> (rowIndex: Int, values: [String?])? {
        guard sourceRowIndex < rowBuffer.rows.count else { return nil }

        var newValues = rowBuffer.rows[sourceRowIndex]

        for pkColumn in changeManager.primaryKeyColumns {
            if let pkIndex = columns.firstIndex(of: pkColumn) {
                newValues[pkIndex] = "__DEFAULT__"
            }
        }

        let newRowIndex = rowBuffer.rows.count
        rowBuffer.rows.append(newValues)

        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newValues)

        return (newRowIndex, newValues)
    }

    // MARK: - Delete Rows

    func deleteSelectedRows(
        selectedIndices: Set<Int>,
        rowBuffer: RowBuffer
    ) -> Int {
        guard !selectedIndices.isEmpty else { return -1 }

        var insertedRowsToDelete: [Int] = []
        var existingRowsToDelete: [(rowIndex: Int, originalRow: [String?])] = []

        let minSelectedRow = selectedIndices.min() ?? 0
        let maxSelectedRow = selectedIndices.max() ?? 0

        for rowIndex in selectedIndices.sorted(by: >) {
            if changeManager.isRowInserted(rowIndex) {
                insertedRowsToDelete.append(rowIndex)
            } else if !changeManager.isRowDeleted(rowIndex) {
                if rowIndex < rowBuffer.rows.count {
                    existingRowsToDelete.append((rowIndex: rowIndex, originalRow: rowBuffer.rows[rowIndex]))
                }
            }
        }

        if !insertedRowsToDelete.isEmpty {
            let sortedInsertedRows = insertedRowsToDelete.sorted(by: >)

            for rowIndex in sortedInsertedRows {
                guard rowIndex < rowBuffer.rows.count else { continue }
                rowBuffer.rows.remove(at: rowIndex)
            }

            changeManager.undoBatchRowInsertion(rowIndices: sortedInsertedRows)
        }

        if !existingRowsToDelete.isEmpty {
            changeManager.recordBatchRowDeletion(rows: existingRowsToDelete)
        }

        let totalRows = rowBuffer.rows.count
        let rowsDeleted = insertedRowsToDelete.count
        let adjustedMaxRow = maxSelectedRow - rowsDeleted
        let adjustedMinRow = minSelectedRow - insertedRowsToDelete.count(where: { $0 < minSelectedRow })

        if adjustedMaxRow + 1 < totalRows {
            return min(adjustedMaxRow + 1, totalRows - 1)
        } else if adjustedMinRow > 0 {
            return adjustedMinRow - 1
        } else if totalRows > 0 {
            return 0
        } else {
            return -1
        }
    }

    // MARK: - Undo Insert Row

    func undoInsertRow(
        at rowIndex: Int,
        rowBuffer: RowBuffer,
        selectedIndices: Set<Int>
    ) -> Set<Int> {
        guard rowIndex >= 0 && rowIndex < rowBuffer.rows.count else { return selectedIndices }

        rowBuffer.rows.remove(at: rowIndex)

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

        return adjustedSelection
    }

    // MARK: - Copy Rows

    func copySelectedRowsToClipboard(
        selectedIndices: Set<Int>,
        resultRows: [[String?]],
        columns: [String] = [],
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

        let columnCount = resultRows.first?.count ?? 1
        let estimatedRowLength = columnCount * 12
        var result = ""
        result.reserveCapacity(indicesToCopy.count * estimatedRowLength)

        if includeHeaders, !columns.isEmpty {
            for (colIdx, col) in columns.enumerated() {
                if colIdx > 0 { result.append("\t") }
                result.append(col)
            }
        }

        for rowIndex in indicesToCopy {
            guard rowIndex < resultRows.count else { continue }
            if !result.isEmpty { result.append("\n") }
            for (colIdx, value) in resultRows[rowIndex].enumerated() {
                if colIdx > 0 { result.append("\t") }
                result.append(value ?? "NULL")
            }
        }

        if isTruncated {
            result.append("\n(truncated, showing first \(Self.maxClipboardRows) of \(totalSelected) rows)")
        }

        ClipboardService.shared.writeText(result)
    }

    // MARK: - Paste Rows

    @MainActor
    func pasteRowsFromClipboard(
        columns: [String],
        primaryKeyColumns: [String],
        rowBuffer: RowBuffer,
        clipboard: ClipboardProvider? = nil,
        parser: RowDataParser? = nil
    ) -> [(rowIndex: Int, values: [String?])] {
        let clipboardProvider = clipboard ?? ClipboardService.shared
        guard let clipboardText = clipboardProvider.readText() else {
            return []
        }

        let schema = TableSchema(
            columns: columns,
            primaryKeyColumns: primaryKeyColumns
        )

        let rowParser = parser ?? Self.detectParser(for: clipboardText)
        let parseResult = rowParser.parse(clipboardText, schema: schema)

        switch parseResult {
        case .success(let parsedRows):
            return insertParsedRows(parsedRows, into: rowBuffer)

        case .failure(let error):
            Self.logger.warning("Paste failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Parser Detection

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

        if tabLines > commaLines {
            return TSVRowParser()
        } else if commaLines > 0 {
            return CSVRowParser()
        }
        return TSVRowParser()
    }

    // MARK: - Private Helpers

    private func insertParsedRows(
        _ parsedRows: [ParsedRow],
        into rowBuffer: RowBuffer
    ) -> [(rowIndex: Int, values: [String?])] {
        var pastedRowInfo: [(Int, [String?])] = []

        for parsedRow in parsedRows {
            let rowValues = parsedRow.values

            rowBuffer.rows.append(rowValues)
            let newRowIndex = rowBuffer.rows.count - 1

            changeManager.recordRowInsertion(rowIndex: newRowIndex, values: rowValues)

            pastedRowInfo.append((newRowIndex, rowValues))
        }

        return pastedRowInfo
    }
}
