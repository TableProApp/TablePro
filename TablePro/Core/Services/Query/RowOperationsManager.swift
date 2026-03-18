//
//  RowOperationsManager.swift
//  TablePro
//
//  Service responsible for row operations: add, delete, duplicate, undo/redo.
//  Extracted from MainContentView for better separation of concerns.
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

    /// Add a new row to a table tab
    /// - Parameters:
    ///   - columns: Column names
    ///   - columnDefaults: Column default values
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Tuple of (newRowIndex, newRowValues) or nil if failed
    func addNewRow(
        columns: [String],
        columnDefaults: [String: String?],
        resultRows: inout [QueryResultRow]
    ) -> (rowIndex: Int, values: [String?])? {
        // Create new row values with DEFAULT markers
        var newRowValues: [String?] = []
        for column in columns {
            if let defaultValue = columnDefaults[column], defaultValue != nil {
                // Use __DEFAULT__ marker so generateInsertSQL skips this column
                newRowValues.append("__DEFAULT__")
            } else {
                // NULL for columns without defaults
                newRowValues.append(nil)
            }
        }

        // Add to resultRows
        let newRowIndex = resultRows.count
        let newRow = QueryResultRow(id: newRowIndex, values: newRowValues)
        resultRows.append(newRow)

        // Record in change manager as pending INSERT
        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newRowValues)

        return (newRowIndex, newRowValues)
    }

    // MARK: - Duplicate Row

    /// Duplicate a row with new primary key
    /// - Parameters:
    ///   - sourceRowIndex: Index of row to duplicate
    ///   - columns: Column names
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Tuple of (newRowIndex, newRowValues) or nil if failed
    func duplicateRow(
        sourceRowIndex: Int,
        columns: [String],
        resultRows: inout [QueryResultRow]
    ) -> (rowIndex: Int, values: [String?])? {
        guard sourceRowIndex < resultRows.count else { return nil }

        // Copy values from selected row
        let sourceRow = resultRows[sourceRowIndex]
        var newValues = sourceRow.values

        // Set primary key column to DEFAULT so DB auto-generates
        if let pkColumn = changeManager.primaryKeyColumn,
           let pkIndex = columns.firstIndex(of: pkColumn) {
            newValues[pkIndex] = "__DEFAULT__"
        }

        // Add the duplicated row
        let newRowIndex = resultRows.count
        let newRow = QueryResultRow(id: newRowIndex, values: newValues)
        resultRows.append(newRow)

        // Record in change manager as pending INSERT
        changeManager.recordRowInsertion(rowIndex: newRowIndex, values: newValues)

        return (newRowIndex, newValues)
    }

    // MARK: - Delete Rows

    /// Delete selected rows
    /// - Parameters:
    ///   - selectedIndices: Indices of rows to delete
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Next row index to select after deletion, or -1 if no rows left
    func deleteSelectedRows(
        selectedIndices: Set<Int>,
        resultRows: inout [QueryResultRow]
    ) -> Int {
        guard !selectedIndices.isEmpty else { return -1 }

        // Separate inserted rows from existing rows
        var insertedRowsToDelete: [Int] = []
        var existingRowsToDelete: [(rowIndex: Int, originalRow: [String?])] = []

        // Find the lowest selected row index for selection movement
        let minSelectedRow = selectedIndices.min() ?? 0
        let maxSelectedRow = selectedIndices.max() ?? 0

        // Categorize rows (process in descending order to maintain correct indices)
        for rowIndex in selectedIndices.sorted(by: >) {
            if changeManager.isRowInserted(rowIndex) {
                insertedRowsToDelete.append(rowIndex)
            } else if !changeManager.isRowDeleted(rowIndex) {
                if rowIndex < resultRows.count {
                    let originalRow = resultRows[rowIndex].values
                    existingRowsToDelete.append((rowIndex: rowIndex, originalRow: originalRow))
                }
            }
        }

        // Process inserted rows deletion
        if !insertedRowsToDelete.isEmpty {
            let sortedInsertedRows = insertedRowsToDelete.sorted(by: >)

            // Remove from resultRows first (descending order)
            for rowIndex in sortedInsertedRows {
                guard rowIndex < resultRows.count else { continue }
                resultRows.remove(at: rowIndex)
            }

            // Update changeManager for ALL deleted inserted rows at once
            changeManager.undoBatchRowInsertion(rowIndices: sortedInsertedRows)
        }

        // Record batch deletion for existing rows (single undo action for all rows)
        if !existingRowsToDelete.isEmpty {
            changeManager.recordBatchRowDeletion(rows: existingRowsToDelete)
        }

        // Calculate next row selection, accounting for deleted inserted rows
        let totalRows = resultRows.count
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

    // MARK: - Undo/Redo

    /// Undo the last change
    /// - Parameter resultRows: Current rows (will be mutated)
    /// - Returns: Updated selection indices
    func undoLastChange(resultRows: inout [QueryResultRow]) -> Set<Int>? {
        guard let result = changeManager.undoLastChange() else { return nil }

        var adjustedSelection: Set<Int>?

        switch result.action {
        case .cellEdit(let rowIndex, let columnIndex, _, let previousValue, _):
            if rowIndex < resultRows.count {
                resultRows[rowIndex].values[columnIndex] = previousValue
            }

        case .rowInsertion(let rowIndex):
            if rowIndex < resultRows.count {
                resultRows.remove(at: rowIndex)
                adjustedSelection = Set<Int>()
            }

        case .rowDeletion:
            // Row is restored in changeManager - visual indicator will be removed
            break

        case .batchRowDeletion:
            // All rows are restored in changeManager
            break

        case .batchRowInsertion(let rowIndices, let rowValues):
            // Restore deleted inserted rows - add them back to resultRows
            for (index, rowIndex) in rowIndices.enumerated().reversed() {
                guard index < rowValues.count else { continue }
                guard rowIndex <= resultRows.count else { continue }

                let values = rowValues[index]
                let newRow = QueryResultRow(id: rowIndex, values: values)
                resultRows.insert(newRow, at: rowIndex)
            }
        }

        return adjustedSelection
    }

    /// Redo the last undone change
    /// - Parameters:
    ///   - resultRows: Current rows (will be mutated)
    ///   - columns: Column names for new row creation
    /// - Returns: Updated selection indices
    func redoLastChange(resultRows: inout [QueryResultRow], columns: [String]) -> Set<Int>? {
        guard let result = changeManager.redoLastChange() else { return nil }

        switch result.action {
        case .cellEdit(let rowIndex, let columnIndex, _, _, let newValue):
            if rowIndex < resultRows.count {
                resultRows[rowIndex].values[columnIndex] = newValue
            }

        case .rowInsertion(let rowIndex):
            let newValues = [String?](repeating: nil, count: columns.count)
            let newRow = QueryResultRow(id: rowIndex, values: newValues)
            if rowIndex <= resultRows.count {
                resultRows.insert(newRow, at: rowIndex)
            }

        case .rowDeletion:
            // Row is re-marked as deleted in changeManager
            break

        case .batchRowDeletion:
            // Rows are re-marked as deleted
            break

        case .batchRowInsertion(let rowIndices, _):
            // Redo the deletion - remove the rows from resultRows again
            for rowIndex in rowIndices.sorted(by: >) {
                guard rowIndex < resultRows.count else { continue }
                resultRows.remove(at: rowIndex)
            }
        }

        return nil
    }

    // MARK: - Undo Insert Row

    /// Remove a row that was inserted (called by undo context menu)
    /// - Parameters:
    ///   - rowIndex: Index of the inserted row
    ///   - resultRows: Current rows (will be mutated)
    ///   - selectedIndices: Current selection (will be adjusted)
    /// - Returns: Adjusted selection indices
    func undoInsertRow(
        at rowIndex: Int,
        resultRows: inout [QueryResultRow],
        selectedIndices: Set<Int>
    ) -> Set<Int> {
        guard rowIndex >= 0 && rowIndex < resultRows.count else { return selectedIndices }

        // Remove the row from resultRows
        resultRows.remove(at: rowIndex)

        // Adjust selection indices
        var adjustedSelection = Set<Int>()
        for idx in selectedIndices {
            if idx == rowIndex {
                continue  // Skip the removed row
            } else if idx > rowIndex {
                adjustedSelection.insert(idx - 1)
            } else {
                adjustedSelection.insert(idx)
            }
        }

        return adjustedSelection
    }

    // MARK: - Copy Rows

    /// Copy selected rows to clipboard as tab-separated values
    /// - Parameters:
    ///   - selectedIndices: Indices of rows to copy
    ///   - resultRows: Current rows
    ///   - columns: Column names (used when includeHeaders is true)
    ///   - includeHeaders: Whether to prepend column headers as the first TSV line
    func copySelectedRowsToClipboard(
        selectedIndices: Set<Int>,
        resultRows: [QueryResultRow],
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

        let columnCount = resultRows.first?.values.count ?? 1
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
            let row = resultRows[rowIndex]
            if !result.isEmpty { result.append("\n") }
            for (colIdx, value) in row.values.enumerated() {
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

    /// Paste rows from clipboard (TSV format) and insert into table
    /// - Parameters:
    ///   - columns: Column names for the table
    ///   - primaryKeyColumn: Primary key column name (will be set to __DEFAULT__)
    ///   - resultRows: Current rows (will be mutated)
    ///   - clipboard: Clipboard provider (injectable for testing)
    ///   - parser: Row data parser (injectable for testing)
    /// - Returns: Array of (rowIndex, values) for pasted rows, or empty array on failure
    @MainActor
    func pasteRowsFromClipboard(
        columns: [String],
        primaryKeyColumn: String?,
        resultRows: inout [QueryResultRow],
        clipboard: ClipboardProvider? = nil,
        parser: RowDataParser? = nil
    ) -> [(rowIndex: Int, values: [String?])] {
        // Read from clipboard
        let clipboardProvider = clipboard ?? ClipboardService.shared
        guard let clipboardText = clipboardProvider.readText() else {
            return []
        }

        // Create schema
        let schema = TableSchema(
            columns: columns,
            primaryKeyColumn: primaryKeyColumn
        )

        // Parse clipboard text (auto-detect CSV vs TSV)
        let rowParser = parser ?? Self.detectParser(for: clipboardText)
        let parseResult = rowParser.parse(clipboardText, schema: schema)

        switch parseResult {
        case .success(let parsedRows):
            return insertParsedRows(parsedRows, into: &resultRows)

        case .failure(let error):
            // Log error (in production, this could show a user-facing alert)
            Self.logger.warning("Paste failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Parser Detection

    /// Auto-detect whether clipboard text is CSV or TSV
    /// Heuristic: if tabs appear in most lines, use TSV; otherwise CSV
    static func detectParser(for text: String) -> RowDataParser {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return TSVRowParser() }

        let tabCount = lines.count(where: { $0.contains("\t") })
        let commaCount = lines.count(where: { $0.contains(",") })

        // If majority of lines have tabs, use TSV; otherwise CSV
        if tabCount > commaCount {
            return TSVRowParser()
        } else if commaCount > 0 {
            return CSVRowParser()
        }
        return TSVRowParser()
    }

    // MARK: - Private Helpers

    /// Insert parsed rows into the table
    /// - Parameters:
    ///   - parsedRows: Array of parsed rows from clipboard
    ///   - resultRows: Current rows (will be mutated)
    /// - Returns: Array of (rowIndex, values) for inserted rows
    private func insertParsedRows(
        _ parsedRows: [ParsedRow],
        into resultRows: inout [QueryResultRow]
    ) -> [(rowIndex: Int, values: [String?])] {
        var pastedRowInfo: [(Int, [String?])] = []

        for parsedRow in parsedRows {
            let rowValues = parsedRow.values

            // Add to resultRows
            resultRows.append(QueryResultRow(id: resultRows.count, values: rowValues))
            let newRowIndex = resultRows.count - 1

            // Record as pending INSERT in change manager
            changeManager.recordRowInsertion(rowIndex: newRowIndex, values: rowValues)

            pastedRowInfo.append((newRowIndex, rowValues))
        }

        return pastedRowInfo
    }
}
