//
//  MultiRowEditState.swift
//  TablePro
//
//  State management for multi-row editing in right sidebar.
//  Tracks pending edits across multiple selected rows.
//

import Foundation
import Observation

/// Represents the edit state for a single field across multiple rows
struct FieldEditState {
    let columnIndex: Int
    let columnName: String
    let columnTypeEnum: ColumnType
    let isLongText: Bool

    /// Original values from all selected rows (nil if multiple different values)
    let originalValue: String?

    /// Flag indicating if selected rows have different values for this field
    let hasMultipleValues: Bool

    /// Pending new value (nil if not edited yet)
    var pendingValue: String?

    /// Whether user has explicitly set this field to NULL
    var isPendingNull: Bool

    /// Whether user has explicitly set this field to DEFAULT
    var isPendingDefault: Bool

    var hasEdit: Bool {
        pendingValue != nil || isPendingNull || isPendingDefault
    }

    var effectiveValue: String? {
        if isPendingDefault {
            return "__DEFAULT__"
        } else if isPendingNull {
            return nil
        } else {
            return pendingValue
        }
    }
}

/// Manages edit state for multi-row editing in sidebar
@MainActor @Observable
final class MultiRowEditState {
    var fields: [FieldEditState] = []

    var onFieldChanged: ((Int, String?) -> Void)?

    private(set) var selectedRowIndices: Set<Int> = []
    private(set) var allRows: [[String?]] = []
    private(set) var columns: [String] = []
    private(set) var columnTypes: [ColumnType] = []  // Changed from [String] to [ColumnType]

    var hasEdits: Bool {
        fields.contains { $0.hasEdit }
    }

    /// Configure state for the given selection
    func configure(
        selectedRowIndices: Set<Int>,
        allRows: [[String?]],
        columns: [String],
        columnTypes: [ColumnType],  // Changed from [String] to [ColumnType]
        externallyModifiedColumns: Set<Int> = []
    ) {
        // Check if the underlying data has changed (not just edits)
        let columnsChanged = self.columns != columns
        let selectionChanged = self.selectedRowIndices != selectedRowIndices

        self.selectedRowIndices = selectedRowIndices
        self.allRows = allRows
        self.columns = columns
        self.columnTypes = columnTypes

        // Build field states
        var newFields: [FieldEditState] = []

        for (colIndex, columnName) in columns.enumerated() {
            let columnTypeEnum = colIndex < columnTypes.count ? columnTypes[colIndex] : ColumnType.text(rawType: nil)
            let isLongText = columnTypeEnum.isLongText

            // Gather values from all selected rows
            var values: [String?] = []
            for row in allRows {
                let value = colIndex < row.count ? row[colIndex] : nil
                values.append(value)
            }

            // Check if all values are the same
            let uniqueValues = Set(values.map { $0 ?? "__NULL__" })
            let hasMultipleValues = uniqueValues.count > 1

            let originalValue: String?
            if hasMultipleValues {
                originalValue = nil
            } else {
                // Get first value, unwrapping the optional properly
                originalValue = values.first.flatMap { $0 }
            }

            // Preserve pending edits if data hasn't changed
            var pendingValue: String?
            var isPendingNull = false
            var isPendingDefault = false

            if !columnsChanged, !selectionChanged, colIndex < fields.count {
                let oldField = fields[colIndex]
                if oldField.originalValue == originalValue && oldField.hasMultipleValues == hasMultipleValues {
                    pendingValue = oldField.pendingValue
                    isPendingNull = oldField.isPendingNull
                    isPendingDefault = oldField.isPendingDefault
                }
            }

            // Mark externally modified columns (e.g., edited in data grid)
            if externallyModifiedColumns.contains(colIndex), pendingValue == nil, !isPendingNull, !isPendingDefault {
                pendingValue = originalValue ?? ""
            }

            newFields.append(FieldEditState(
                columnIndex: colIndex,
                columnName: columnName,
                columnTypeEnum: columnTypeEnum,
                isLongText: isLongText,
                originalValue: originalValue,
                hasMultipleValues: hasMultipleValues,
                pendingValue: pendingValue,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault
            ))
        }

        self.fields = newFields
    }

    /// Update a field's pending value
    func updateField(at index: Int, value: String?) {
        guard index < fields.count else { return }
        let hadPendingEdit = fields[index].hasEdit
        let original = fields[index].originalValue
        if value == original || (original == nil && value == "") {
            fields[index].pendingValue = nil
        } else {
            fields[index].pendingValue = value
        }
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        if fields[index].pendingValue != nil || hadPendingEdit {
            onFieldChanged?(index, value)
        }
    }

    /// Set a field to NULL
    func setFieldToNull(at index: Int) {
        guard index < fields.count else { return }
        fields[index].pendingValue = nil
        fields[index].isPendingNull = true
        fields[index].isPendingDefault = false
        onFieldChanged?(index, nil)
    }

    /// Set a field to DEFAULT
    func setFieldToDefault(at index: Int) {
        guard index < fields.count else { return }
        fields[index].pendingValue = nil
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = true
        onFieldChanged?(index, "__DEFAULT__")
    }

    /// Set a field to a SQL function (e.g., NOW())
    func setFieldToFunction(at index: Int, function: String) {
        guard index < fields.count else { return }
        fields[index].pendingValue = function
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        onFieldChanged?(index, function)
    }

    /// Set a field to empty string
    func setFieldToEmpty(at index: Int) {
        guard index < fields.count else { return }
        let hadPendingEdit = fields[index].hasEdit
        if fields[index].originalValue == "" {
            fields[index].pendingValue = nil
        } else {
            fields[index].pendingValue = ""
        }
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        if fields[index].pendingValue != nil || hadPendingEdit {
            onFieldChanged?(index, "")
        }
    }

    /// Clear all pending edits
    func clearEdits() {
        for i in 0..<fields.count {
            fields[i].pendingValue = nil
            fields[i].isPendingNull = false
            fields[i].isPendingDefault = false
        }
    }

    /// Release all data to free memory on disconnect
    func releaseData() {
        fields = []
        onFieldChanged = nil
        selectedRowIndices = []
        allRows = []
        columns = []
        columnTypes = []
    }

    /// Get all edited fields with their new values
    func getEditedFields() -> [(columnIndex: Int, columnName: String, newValue: String?)] {
        fields.compactMap { field in
            guard field.hasEdit else { return nil }
            return (field.columnIndex, field.columnName, field.effectiveValue)
        }
    }
}
