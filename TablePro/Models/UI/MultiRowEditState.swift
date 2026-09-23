//
//  MultiRowEditState.swift
//  TablePro
//
//  State management for multi-row editing in right sidebar.
//  Tracks pending edits across multiple selected rows.
//

import Combine
import Foundation
import TableProPluginKit

/// Represents the edit state for a single field across multiple rows
struct FieldEditState: Identifiable {
    var id = UUID()
    let columnIndex: Int
    let columnName: String
    let columnTypeEnum: ColumnType
    let isLongText: Bool
    let isJson: Bool

    var isPrimaryKey: Bool = false
    var isForeignKey: Bool = false

    /// Set when the owning grid dictates the editor instead of the column type.
    var editor: FieldEditorKind?

    /// Which editor the field's own type and value ask for, resolved once here.
    ///
    /// Resolving it costs a full `JSONSerialization` parse of the value and a PHP-serialized parse
    /// after it, and `FieldEditorResolver` was reached from two view bodies per field. Every hover,
    /// every inspector tab switch and every pending-edit keystroke re-parsed every value in the row.
    var resolvedEditor: FieldEditorKind?

    /// A schema field has no data type, so it offers no type badge and no NULL or DEFAULT state.
    var isSchemaField: Bool = false

    /// The server owns the value, or refuses to change it on this kind of object, so the field is
    /// shown without an editor. Refusing the edit further down instead would leave a pending value
    /// here that nothing can clear, and the inspector would go on reporting an unsaved change that
    /// Save never writes.
    var isServerOwned: Bool = false

    /// The value already differs from the loaded schema because the edit is recorded elsewhere.
    var hasCommittedEdit: Bool = false

    var originalValue: String?

    let hasMultipleValues: Bool

    var pendingValue: String?

    var isPendingNull: Bool

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

enum FieldEditContinuity {
    case typing
    case discrete
}

/// Manages edit state for multi-row editing in sidebar
@MainActor
final class MultiRowEditState: ObservableObject {
    @Published var fields: [FieldEditState] = []

    /// A field's new value, and whether it arrived a character at a time. Typing is folded into one
    /// undo step; choosing NULL, DEFAULT, a function or a picker value is its own step.
    @Published var onFieldChanged: ((Int, PluginCellValue, FieldEditContinuity) -> Void)?

    /// A field the selected rows disagree on, cleared back to nothing. It has no single value to
    /// send, so it asks for each row's own configured value instead.
    @Published var onFieldReverted: ((Int, [RowID: PluginCellValue]) -> Void)?

    /// A value window still open over a selection that has moved on. It names the rows it was
    /// opened for, because the fields it was opened from are gone.
    @Published var onDetachedFieldChanged: ((Int, PluginCellValue, [RowID]) -> Void)?

    @Published private(set) var selectedRowIndices: Set<Int> = []

    /// The rows an edit is staged against, captured when the selection was configured.
    ///
    /// `selectedRowIndices` are display positions, and a commit that resolves them when the
    /// keystroke arrives writes into whatever row the sort, the value filter or a later selection
    /// left at that position.
    @Published private(set) var rowIDs: [RowID] = []

    @Published private(set) var allRows: [[String?]] = []
    @Published private(set) var columns: [String] = []
    @Published private(set) var columnTypes: [ColumnType] = []

    var hasEdits: Bool {
        fields.contains { $0.hasEdit }
    }

    /// Configure state for the given selection
    func configure(
        selectedRowIndices: Set<Int>,
        rowIDs: [RowID] = [],
        allRows: [[String?]],
        columns: [String],
        columnTypes: [ColumnType],
        externallyModifiedColumns: Set<Int> = [],
        primaryKeyColumns: Set<String> = [],
        foreignKeyColumns: Set<String> = [],
        serverOwnedColumns: Set<String> = [],
        displayFormats: [ValueDisplayFormat?] = []
    ) {
        // Check if the underlying data has changed (not just edits)
        let columnsChanged = self.columns != columns
        let selectionChanged = self.selectedRowIndices != selectedRowIndices

        self.selectedRowIndices = selectedRowIndices
        self.rowIDs = rowIDs
        self.allRows = allRows
        self.columns = columns
        self.columnTypes = columnTypes

        var newFields: [FieldEditState] = []

        for (colIndex, columnName) in columns.enumerated() {
            let columnTypeEnum = colIndex < columnTypes.count ? columnTypes[colIndex] : ColumnType.text(rawType: nil)
            let isLongText = columnTypeEnum.isLongText

            var values: [String?] = []
            for row in allRows {
                let value = colIndex < row.count ? row[colIndex] : nil
                values.append(value)
            }

            let allSame = values.dropFirst().allSatisfy { $0 == values.first }
            let hasMultipleValues = !allSame

            let originalValue: String?
            if hasMultipleValues {
                originalValue = nil
            } else {
                originalValue = values.first.flatMap { $0 }
            }

            // Preserve pending edits if data hasn't changed
            var preservedId: UUID?
            var pendingValue: String?
            var isPendingNull = false
            var isPendingDefault = false

            if !columnsChanged, !selectionChanged, colIndex < fields.count {
                let oldField = fields[colIndex]
                // Preserve pending edits when original data matches
                if oldField.originalValue == originalValue && oldField.hasMultipleValues == hasMultipleValues {
                    preservedId = oldField.id
                    pendingValue = oldField.pendingValue
                    isPendingNull = oldField.isPendingNull
                    isPendingDefault = oldField.isPendingDefault
                }
            }

            // Mark externally modified columns (e.g., edited in data grid)
            if externallyModifiedColumns.contains(colIndex), pendingValue == nil, !isPendingNull, !isPendingDefault {
                pendingValue = originalValue ?? ""
            }

            let isJson = columnTypeEnum.isJsonType || (originalValue ?? "").looksLikeJson

            var newField = FieldEditState(
                columnIndex: colIndex,
                columnName: columnName,
                columnTypeEnum: columnTypeEnum,
                isLongText: isLongText,
                isJson: isJson,
                isPrimaryKey: primaryKeyColumns.contains(columnName),
                isForeignKey: foreignKeyColumns.contains(columnName),
                isServerOwned: serverOwnedColumns.contains(columnName),
                originalValue: originalValue,
                hasMultipleValues: hasMultipleValues,
                pendingValue: pendingValue,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault
            )
            if let preservedId {
                newField.id = preservedId
            }
            /// The column's display format decides the editor here exactly as it does in the grid.
            /// Without it the inspector resolved from the raw value alone, so a column the user had
            /// set to JSON or PHP-serialized opened a plain text field in the inspector while the
            /// grid rendered it structured.
            newField.resolvedEditor = FieldEditorResolver.resolve(
                for: columnTypeEnum,
                isLongText: isLongText,
                originalValue: originalValue,
                displayFormatOverride: colIndex < displayFormats.count ? displayFormats[colIndex] : nil
            )
            newFields.append(newField)
        }

        self.fields = newFields
    }

    /// Configure state for a single schema row supplied by the grid that owns the selection.
    /// Field ids survive a reconfigure of the same row so a commit does not rebuild the
    /// editors and drop focus while the user is still moving between fields.
    func configure(schemaFields: [InspectorRowField], displayRow: Int) {
        let names = schemaFields.map(\.name)
        let reusedIds = selectedRowIndices == [displayRow] && columns == names ? fields.map(\.id) : []

        selectedRowIndices = [displayRow]
        rowIDs = []
        columns = names
        columnTypes = Array(repeating: .text(rawType: nil), count: names.count)
        allRows = [schemaFields.map(\.value)]

        fields = schemaFields.enumerated().map { index, field in
            var state = FieldEditState(
                columnIndex: index,
                columnName: field.name,
                columnTypeEnum: .text(rawType: nil),
                isLongText: false,
                isJson: false,
                editor: field.editor,
                isSchemaField: true,
                hasCommittedEdit: field.isModified,
                originalValue: field.value,
                hasMultipleValues: false,
                pendingValue: nil,
                isPendingNull: false,
                isPendingDefault: false
            )
            if index < reusedIds.count {
                state.id = reusedIds[index]
            }
            if field.editor == nil {
                state.resolvedEditor = FieldEditorResolver.resolve(
                    for: .text(rawType: nil),
                    isLongText: false,
                    originalValue: field.value
                )
            }
            state.isServerOwned = !field.isEditable
            return state
        }
    }

    /// What a field's editor is showing right now, read from the store rather than from a copy an
    /// earlier render captured. This is what a field's value binding answers.
    func currentText(at index: Int) -> String {
        guard fields.indices.contains(index) else { return "" }
        return FieldValueState.resolve(fields[index]).editableText
    }

    /// Update a field's pending value
    func updateField(at index: Int, value: String?) {
        guard index < fields.count else { return }
        let hadPendingEdit = fields[index].hasEdit
        let original = fields[index].originalValue
        let pending = Self.resolvePendingValue(value, original: original, isJson: fields[index].isJson)
        fields[index].pendingValue = pending
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        if pending != nil {
            onFieldChanged?(index, PluginCellValue.fromOptional(pending), .typing)
        } else if hadPendingEdit {
            /// `originalValue` is nil for two different situations, and only one of them is a
            /// value: a stored NULL, and a selection whose rows do not agree. Sending it as one
            /// value wrote NULL into every selected row when the user cleared a field they all
            /// disagreed on, which the field then reported as unedited.
            if fields[index].hasMultipleValues {
                onFieldReverted?(index, configuredValues(atColumn: index))
            } else {
                onFieldChanged?(index, PluginCellValue.fromOptional(original), .typing)
            }
        }
    }

    /// What each row held when the selection was configured, which is what a field with no value of
    /// its own reverts to.
    private func configuredValues(atColumn index: Int) -> [RowID: PluginCellValue] {
        var values: [RowID: PluginCellValue] = [:]
        for (rowID, row) in zip(rowIDs, allRows) where row.indices.contains(index) {
            values[rowID] = PluginCellValue.fromOptional(row[index])
        }
        return values
    }

    /// A commit from a detached value window, which outlives the selection it was opened from.
    ///
    /// While that selection is still the one on screen this is an ordinary field edit. Once it has
    /// moved the fields no longer describe those rows, so the value goes straight to the rows the
    /// window was opened for rather than into whatever is selected now.
    func updateDetachedField(columnIndex: Int, rowIDs: [RowID], value: String?) {
        guard !rowIDs.isEmpty else { return }
        if self.rowIDs == rowIDs, fields.indices.contains(columnIndex) {
            updateField(at: columnIndex, value: value)
            return
        }
        onDetachedFieldChanged?(columnIndex, PluginCellValue.fromOptional(value), rowIDs)
    }

    private static func resolvePendingValue(_ value: String?, original: String?, isJson: Bool) -> String? {
        if isJson, let value, !value.isEmpty {
            let normalized = JsonReindenter.normalize(value)
            if let original, JsonReindenter.normalize(original) == normalized {
                return nil
            }
            return normalized
        }
        if value == original || (original == nil && value == "") {
            return nil
        }
        return value
    }

    func setFieldToBytes(at index: Int, data: Data) {
        guard index < fields.count else { return }
        let encoded = String(data: data, encoding: .isoLatin1) ?? ""
        fields[index].pendingValue = encoded
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        onFieldChanged?(index, .bytes(data), .discrete)
    }

    func setFieldToNull(at index: Int) {
        guard index < fields.count else { return }
        fields[index].pendingValue = nil
        fields[index].isPendingNull = true
        fields[index].isPendingDefault = false
        onFieldChanged?(index, .null, .discrete)
    }

    func setFieldToDefault(at index: Int) {
        guard index < fields.count else { return }
        fields[index].pendingValue = nil
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = true
        onFieldChanged?(index, .text("__DEFAULT__"), .discrete)
    }

    func setFieldToFunction(at index: Int, function: String) {
        guard index < fields.count else { return }
        fields[index].pendingValue = function
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        onFieldChanged?(index, .text(function), .discrete)
    }

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
            onFieldChanged?(index, .text(""), .discrete)
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
        onFieldReverted = nil
        onDetachedFieldChanged = nil
        selectedRowIndices = []
        rowIDs = []
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
