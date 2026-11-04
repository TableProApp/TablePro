//
//  MultiRowEditState.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

struct FieldEditState: Identifiable {
    var id = UUID()
    let columnIndex: Int
    let columnName: String
    let columnTypeEnum: ColumnType
    let isLongText: Bool
    let isJson: Bool

    // Read from the values, not the column type: a spatial column is text on one engine and a blob on another.
    var isBinaryValue: Bool = false

    var isPrimaryKey: Bool = false
    var isForeignKey: Bool = false

    // Resolved once: it costs a JSONSerialization and a PHP-serialized parse, and view bodies re-parsed it on every hover.
    var resolvedEditor: FieldEditorKind?

    // Shown without an editor: refusing the edit further down left a pending value here that Save never writes.
    var isServerOwned: Bool = false

    // Nil from the schema reads as nullable, as the grid's menus do.
    var isNullable = true

    // Leaving the column out of an INSERT makes the server fill it, which is what Set DEFAULT gives.
    var serverAssignsValue = false

    var displayFormat: ValueDisplayFormat?

    // A lengthless MySQL CHAR takes the compact UUID form only when its values do.
    var sampleText: String?

    var declaredType: String?

    // Recorded by the change manager for rows that disagree, which no pending value can hold.
    var hasCommittedEdit: Bool = false

    var originalValue: String?

    var hasMultipleValues: Bool

    var pendingValue: String?

    var isPendingNull: Bool

    var isPendingDefault: Bool

    // pendingValue is SQL from CellExpressionVocabulary, staged to be written unquoted.
    var isPendingExpression = false

    // Only an engine that tells a missing field from NULL reports this.
    var isAbsent = false

    var isPendingRemoval = false

    // A selected row's value is still on the server, so the field shows no value and takes no edit.
    var isUnloaded = false

    var hasEdit: Bool {
        pendingValue != nil || isPendingNull || isPendingDefault || isPendingRemoval
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

// For the save that runs when no pending change holds the inspector's edits.
struct InspectorFieldEdit: Equatable {
    let columnIndex: Int
    let columnName: String
    let newValue: String?
    // newValue cannot say this: it reads nil for NULL as well.
    var removesField = false
    // newValue is SQL picked from the field's menu, written unquoted.
    var isExpression = false
}

@MainActor
final class MultiRowEditState: ObservableObject {
    @Published var fields: [FieldEditState] = []

    // Typing folds into one undo step; choosing NULL, DEFAULT or a picker value is its own step.
    @Published var onFieldChanged: ((Int, PluginCellValue, FieldEditContinuity) -> Void)?

    // A plain .text must never be read as SQL, so an expression takes its own callback.
    @Published var onFieldExpressionChanged: ((Int, String, FieldEditContinuity) -> Void)?

    // A value per row, such as a fresh UUID: one value over several rows would repeat a key.
    @Published var onFieldValuesChanged: ((Int, [RowID: PluginCellValue]) -> Void)?

    // Disagreeing rows have no single value: each row's own value, plus the rows to make absent again and to restore SQL on.
    @Published var onFieldReverted: ((Int, [RowID: PluginCellValue], Set<RowID>, Set<RowID>) -> Void)?

    @Published var onFieldRemoved: ((Int, [RowID]) -> Void)?

    // A value window outliving its selection names its rows, since its fields are gone; the flag says the value is SQL.
    @Published var onDetachedFieldChanged: ((Int, PluginCellValue, [RowID], Bool) -> Void)?

    // The rows an edit is staged against, captured when the selection was configured, never a display position.
    @Published private(set) var rowIDs: [RowID] = []

    @Published private(set) var allRows: [[String?]] = []
    // Per row of allRows: the columns it has no field for.
    @Published private(set) var absentCells: [Set<Int>] = []
    @Published private(set) var unloadedCells: [Set<Int>] = []
    // Per row of allRows: the columns holding staged SQL.
    @Published private(set) var expressionCells: [Set<Int>] = []
    @Published private(set) var columns: [String] = []
    @Published private(set) var columnTypes: [ColumnType] = []
    // By column, not field id: every selection change reissues the ids. Cleared when the columns change.
    @Published private(set) var expandedColumn: Int?
    private var nonNullableColumns: Set<String> = []

    // Nil and .none offer no Set Value command and promote nothing.
    private(set) var databaseType: DatabaseType?
    private(set) var cellWriter: CellWriterSupport = .none
    private(set) var rowsAreInserted = false

    private var revealsInvisibleCharacters: Bool
    private var settingsCancellable: AnyCancellable?

    init() {
        revealsInvisibleCharacters = AppSettingsManager.shared.dataGrid.showInvisibleCharacters
        settingsCancellable = AppEvents.shared.dataGridSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.adoptInvisibleCharacterSetting() }
    }

    var hasEdits: Bool {
        fields.contains { $0.hasEdit }
    }

    func configure(
        rowIDs: [RowID],
        allRows: [[String?]],
        absentCells: [Set<Int>] = [],
        unloadedCells: [Set<Int>] = [],
        expressionCells: [Set<Int>] = [],
        columns: [String],
        columnTypes: [ColumnType],
        externallyModifiedColumns: Set<Int> = [],
        primaryKeyColumns: Set<String> = [],
        foreignKeyColumns: Set<String> = [],
        serverOwnedColumns: Set<String> = [],
        nonNullableColumns: Set<String> = [],
        serverAssignedColumns: Set<String> = [],
        displayFormats: [ValueDisplayFormat?] = [],
        declaredTypes: [String: String] = [:],
        binaryColumns: Set<Int> = [],
        databaseType: DatabaseType? = nil,
        cellWriter: CellWriterSupport = .none
    ) {
        let columnsChanged = self.columns != columns
        let selectionChanged = self.rowIDs != rowIDs

        self.rowIDs = rowIDs
        self.allRows = allRows
        self.absentCells = absentCells
        self.unloadedCells = unloadedCells
        self.expressionCells = expressionCells
        self.columns = columns
        self.columnTypes = columnTypes
        self.nonNullableColumns = nonNullableColumns
        self.databaseType = databaseType
        if columnsChanged { expandedColumn = nil }
        self.cellWriter = cellWriter
        rowsAreInserted = !rowIDs.isEmpty && rowIDs.allSatisfy { $0.isInserted }

        var newFields: [FieldEditState] = []

        for (colIndex, columnName) in columns.enumerated() {
            let columnTypeEnum = colIndex < columnTypes.count ? columnTypes[colIndex] : ColumnType.text(rawType: nil)
            let isLongText = columnTypeEnum.isLongText

            var values: [String?] = []
            for row in allRows {
                let value = colIndex < row.count ? row[colIndex] : nil
                values.append(value)
            }
            let absence = allRows.indices.map { absentCells[safe: $0]?.contains(colIndex) == true }
            let expression = allRows.indices.map { expressionCells[safe: $0]?.contains(colIndex) == true }

            let allSame = values.dropFirst().allSatisfy { $0 == values.first }
                && absence.dropFirst().allSatisfy { $0 == absence.first }
                && expression.dropFirst().allSatisfy { $0 == expression.first }
            let hasMultipleValues = !allSame
            let isAbsent = !hasMultipleValues && absence.first == true
            let isUnloaded = allRows.indices.contains { unloadedCells[safe: $0]?.contains(colIndex) == true }

            let originalValue: String?
            if hasMultipleValues {
                originalValue = nil
            } else {
                originalValue = values.first.flatMap { $0 }
            }

            var preservedId: UUID?
            var pendingValue: String?
            var isPendingNull = false
            var isPendingDefault = false
            var isPendingExpression = false
            var isPendingRemoval = false
            var hasCommittedEdit = false

            if !columnsChanged, !selectionChanged, colIndex < fields.count {
                let oldField = fields[colIndex]
                if oldField.originalValue == originalValue && oldField.hasMultipleValues == hasMultipleValues
                    && oldField.isAbsent == isAbsent && oldField.isUnloaded == isUnloaded {
                    preservedId = oldField.id
                    pendingValue = oldField.pendingValue
                    isPendingNull = oldField.isPendingNull
                    isPendingDefault = oldField.isPendingDefault
                    isPendingExpression = oldField.isPendingExpression
                    isPendingRemoval = oldField.isPendingRemoval
                }
            }

            // Edited elsewhere: as an empty pending value a NULL read as '' and disagreeing rows looked like one cell.
            if externallyModifiedColumns.contains(colIndex), pendingValue == nil, !isPendingNull, !isPendingDefault,
               !isPendingRemoval {
                if isAbsent {
                    isPendingRemoval = true
                } else if hasMultipleValues {
                    hasCommittedEdit = true
                } else if originalValue == nil {
                    isPendingNull = true
                } else {
                    pendingValue = originalValue
                    isPendingExpression = expression.first == true
                }
            }
            let displayFormat = colIndex < displayFormats.count ? displayFormats[colIndex] : nil

            let isJson = columnTypeEnum.isJsonType || (originalValue ?? "").looksLikeJson

            var newField = FieldEditState(
                columnIndex: colIndex,
                columnName: columnName,
                columnTypeEnum: columnTypeEnum,
                isLongText: isLongText,
                isJson: isJson,
                isBinaryValue: binaryColumns.contains(colIndex),
                isPrimaryKey: primaryKeyColumns.contains(columnName),
                isForeignKey: foreignKeyColumns.contains(columnName),
                isServerOwned: serverOwnedColumns.contains(columnName) || isUnloaded,
                isNullable: !nonNullableColumns.contains(columnName),
                serverAssignsValue: serverAssignedColumns.contains(columnName),
                displayFormat: displayFormat,
                sampleText: values.first(where: { $0 != nil }) ?? nil,
                declaredType: declaredTypes[columnName],
                hasCommittedEdit: hasCommittedEdit,
                originalValue: originalValue,
                hasMultipleValues: hasMultipleValues,
                pendingValue: pendingValue,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                isPendingExpression: isPendingExpression,
                isAbsent: isAbsent,
                isPendingRemoval: isPendingRemoval
            )
            newField.isUnloaded = isUnloaded
            if let preservedId {
                newField.id = preservedId
            }
            // Same display format as the grid, or a column set to JSON or PHP-serialized opened a plain text field here.
            newField.resolvedEditor = FieldEditorResolver.resolve(
                for: columnTypeEnum,
                isLongText: isLongText,
                originalValue: originalValue,
                displayFormatOverride: displayFormat,
                isBinaryValue: newField.isBinaryValue,
                revealsInvisibleCharacters: revealsInvisibleCharacters
            )
            newFields.append(newField)
        }

        self.fields = newFields
    }

    // One text cell rules a column out, since a binary field commits bytes to every row; an all-NULL column has none.
    static func binaryColumns(in rows: [[PluginCellValue]]) -> Set<Int> {
        var holdsBytes: [Bool] = []
        var holdsText: [Bool] = []
        for row in rows {
            if row.count > holdsBytes.count {
                let added = row.count - holdsBytes.count
                holdsBytes.append(contentsOf: repeatElement(false, count: added))
                holdsText.append(contentsOf: repeatElement(false, count: added))
            }
            for (column, cell) in row.enumerated() {
                switch cell {
                case .bytes:
                    holdsBytes[column] = true
                case .text:
                    holdsText[column] = true
                case .null:
                    break
                }
            }
        }
        return Set(holdsBytes.indices.filter { holdsBytes[$0] && !holdsText[$0] })
    }

    // An invisible-character value takes the text view only while marks are on, so a setting change re-resolves.
    private func adoptInvisibleCharacterSetting() {
        let reveals = AppSettingsManager.shared.dataGrid.showInvisibleCharacters
        guard reveals != revealsInvisibleCharacters else { return }
        revealsInvisibleCharacters = reveals
        for index in fields.indices {
            let field = fields[index]
            let resolved = FieldEditorResolver.resolve(
                for: field.columnTypeEnum,
                isLongText: field.isLongText,
                originalValue: field.originalValue,
                displayFormatOverride: field.displayFormat,
                isBinaryValue: field.isBinaryValue,
                revealsInvisibleCharacters: reveals
            )
            if resolved != field.resolvedEditor {
                fields[index].resolvedEditor = resolved
            }
        }
    }

    // Read from the store, not a copy an earlier render captured; a field's value binding answers with this.
    func currentText(at index: Int) -> String {
        guard fields.indices.contains(index) else { return "" }
        return FieldValueState.resolve(fields[index]).editableText
    }

    // Same answer the grid's menu gives for the column.
    func setValueCommands(for field: FieldEditState, isWritable: Bool) -> [SetValueCommand] {
        setValueContext(for: field, isWritable: isWritable).map(SetValueOptions.commands(for:)) ?? []
    }

    func setValueContext(for field: FieldEditState, isWritable: Bool) -> SetValueContext? {
        guard let databaseType else { return nil }
        return SetValueContext(
            columnType: field.columnTypeEnum,
            isNullable: field.isNullable,
            serverAssignsValue: field.serverAssignsValue,
            isForeignKey: field.isForeignKey,
            isWritable: isWritable && !field.isServerOwned,
            displayFormat: field.displayFormat,
            sampleText: field.sampleText,
            declaredType: field.declaredType,
            databaseType: databaseType,
            rowIsInserted: rowsAreInserted,
            writer: cellWriter
        )
    }

    func setValue(_ command: SetValueCommand, at index: Int) {
        switch command {
        case .empty: setFieldToEmpty(at: index)
        case .null: setFieldToNull(at: index)
        case .defaultValue: setFieldToDefault(at: index)
        case .expression(let expression): setFieldToExpression(at: index, expression: expression)
        case .uuid(let version): generateUUID(at: index, version: version)
        }
    }

    func updateField(at index: Int, value: String?) {
        guard index < fields.count else { return }
        let hadPendingEdit = fields[index].hasEdit
        let original = fields[index].originalValue
        var pending = Self.resolvePendingValue(value, original: original, isJson: fields[index].isJson)
        let expression = pending.flatMap { typedExpression($0, columnType: fields[index].columnTypeEnum) }
        var staged = pending.map { PluginCellValue.entered($0, columnType: fields[index].columnTypeEnum) }
        // NOT NULL with no empty value for the type: the field goes back to its stored value, as the grid's cell does.
        if staged == .null, !fields[index].isNullable {
            pending = nil
            staged = nil
        }
        resetPending(at: index)
        fields[index].pendingValue = pending
        // The field keeps its empty text while staging NULL; the NULL pill would take it away mid-typing.
        if let expression {
            onFieldExpressionChanged?(index, expression, .typing)
        } else if let staged {
            onFieldChanged?(index, staged, .typing)
        } else if hadPendingEdit {
            // originalValue nil is a stored NULL, disagreeing rows or a missing field; one value wrote NULL into every row.
            let absentRows = configuredAbsentRows(atColumn: index)
            let expressionRows = configuredExpressionRows(atColumn: index)
            if fields[index].hasMultipleValues || !absentRows.isEmpty || !expressionRows.isEmpty {
                onFieldReverted?(index, configuredValues(atColumn: index), absentRows, expressionRows)
            } else {
                onFieldChanged?(index, storedCell(original, atColumn: index), .typing)
            }
        }
    }

    // Only typed text comes here, so stored text that spells a function stays text.
    private func typedExpression(_ text: String, columnType: ColumnType?) -> String? {
        guard let databaseType,
              let entry = CellEntry.typed(text, columnType: columnType, databaseType: databaseType, writer: cellWriter),
              entry.isExpression,
              case .text(let sql) = entry.value else { return nil }
        return sql
    }

    // What a field with no value of its own reverts to.
    private func configuredValues(atColumn index: Int) -> [RowID: PluginCellValue] {
        var values: [RowID: PluginCellValue] = [:]
        for (rowID, row) in zip(rowIDs, allRows) where row.indices.contains(index) {
            values[rowID] = storedCell(row[index], atColumn: index)
        }
        return values
    }

    // Sent back as text, a binary field's string is staged over the blob as a change, and SQLite cuts it at the first NUL.
    private func storedCell(_ value: String?, atColumn index: Int) -> PluginCellValue {
        guard let value else { return .null }
        guard fields.indices.contains(index), fields[index].isBinaryValue else { return .text(value) }
        return .bytes(value.storedBytes)
    }

    private func configuredAbsentRows(atColumn index: Int) -> Set<RowID> {
        Set(rowIDs.indices.filter { absentCells[safe: $0]?.contains(index) == true }.map { rowIDs[$0] })
    }

    private func configuredExpressionRows(atColumn index: Int) -> Set<RowID> {
        Set(rowIDs.indices.filter { expressionCells[safe: $0]?.contains(index) == true }.map { rowIDs[$0] })
    }

    // Once the selection has moved, the value goes to the rows the window was opened for, not to what is selected now.
    func updateDetachedField(columnIndex: Int, rowIDs: [RowID], value: String?) {
        guard !rowIDs.isEmpty else { return }
        if self.rowIDs == rowIDs, fields.indices.contains(columnIndex) {
            updateField(at: columnIndex, value: value)
            return
        }
        if let value, let sql = typedExpression(value, columnType: columnTypes[safe: columnIndex]) {
            onDetachedFieldChanged?(columnIndex, .text(sql), rowIDs, true)
            return
        }
        let staged = PluginCellValue.entered(value, columnType: columnTypes[safe: columnIndex])
        if staged.isNull, columns[safe: columnIndex].map(nonNullableColumns.contains) == true { return }
        onDetachedFieldChanged?(columnIndex, staged, rowIDs, false)
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

    private func resetPending(at index: Int) {
        fields[index].pendingValue = nil
        fields[index].isPendingNull = false
        fields[index].isPendingDefault = false
        fields[index].isPendingExpression = false
        fields[index].isPendingRemoval = false
    }

    func setFieldToBytes(at index: Int, data: Data) {
        guard index < fields.count else { return }
        resetPending(at: index)
        fields[index].pendingValue = String(data: data, encoding: .isoLatin1) ?? ""
        onFieldChanged?(index, .bytes(data), .discrete)
    }

    func setFieldToNull(at index: Int) {
        guard index < fields.count else { return }
        resetPending(at: index)
        fields[index].isPendingNull = true
        onFieldChanged?(index, .null, .discrete)
    }

    // Rows that had no field to begin with are back as they were, so nothing is pending for them.
    func removeField(at index: Int) {
        guard index < fields.count, !rowIDs.isEmpty else { return }
        resetPending(at: index)
        fields[index].isPendingRemoval = !fields[index].isAbsent
        onFieldRemoved?(index, rowIDs)
    }

    func setFieldToDefault(at index: Int) {
        guard index < fields.count else { return }
        resetPending(at: index)
        fields[index].isPendingDefault = true
        onFieldChanged?(index, .text("__DEFAULT__"), .discrete)
    }

    func setFieldToExpression(at index: Int, expression: CellExpression) {
        guard index < fields.count else { return }
        resetPending(at: index)
        fields[index].pendingValue = expression.sql
        fields[index].isPendingExpression = true
        onFieldExpressionChanged?(index, expression.sql, .discrete)
    }

    // Each row gets its own UUID, so the field then reads Multiple values.
    func generateUUID(at index: Int, version: UUIDVersion, generator: UUIDValueGenerator = .shared) {
        guard fields.indices.contains(index),
              let context = setValueContext(for: fields[index], isWritable: true),
              let form = SetValueOptions.uuidForm(for: context) else { return }
        guard rowIDs.count > 1 else {
            guard allRows.count <= 1 else { return }
            switch form.value(for: generator.make(version)) {
            case .bytes(let data):
                setFieldToBytes(at: index, data: data)
            case .text(let text):
                resetPending(at: index)
                fields[index].pendingValue = text
                onFieldChanged?(index, .text(text), .discrete)
            case .null:
                break
            }
            return
        }
        let values = Dictionary(
            rowIDs.map { ($0, form.value(for: generator.make(version))) },
            uniquingKeysWith: { first, _ in first }
        )
        // Clearing a later edit goes back to these values, as it does once the inspector is rebuilt from the rows.
        for (position, rowID) in rowIDs.enumerated() {
            guard let value = values[rowID], allRows.indices.contains(position),
                  allRows[position].indices.contains(index) else { continue }
            allRows[position][index] = Self.configuredText(of: value)
            if absentCells.indices.contains(position) { absentCells[position].remove(index) }
            if expressionCells.indices.contains(position) { expressionCells[position].remove(index) }
        }
        resetPending(at: index)
        fields[index].originalValue = nil
        fields[index].hasMultipleValues = true
        fields[index].hasCommittedEdit = true
        if form == .bytes { fields[index].isBinaryValue = true }
        onFieldValuesChanged?(index, values)
    }

    private static func configuredText(of value: PluginCellValue) -> String? {
        switch value {
        case .null: nil
        case .text(let text): text
        case .bytes(let data): String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    func setFieldToEmpty(at index: Int) {
        guard index < fields.count else { return }
        let hadPendingEdit = fields[index].hasEdit
        let isStoredValue = fields[index].originalValue == ""
        resetPending(at: index)
        fields[index].pendingValue = isStoredValue ? nil : ""
        if isStoredValue, hadPendingEdit {
            onFieldChanged?(index, storedCell("", atColumn: index), .discrete)
        } else if !isStoredValue {
            onFieldChanged?(index, .text(""), .discrete)
        }
    }

    func toggleExpansion(ofColumn index: Int) {
        expandedColumn = expandedColumn == index ? nil : index
    }

    func clearEdits() {
        for index in fields.indices {
            resetPending(at: index)
        }
    }

    func releaseData() {
        fields = []
        onFieldChanged = nil
        onFieldExpressionChanged = nil
        onFieldValuesChanged = nil
        onFieldReverted = nil
        onFieldRemoved = nil
        onDetachedFieldChanged = nil
        rowIDs = []
        allRows = []
        absentCells = []
        unloadedCells = []
        expressionCells = []
        columns = []
        columnTypes = []
        nonNullableColumns = []
        expandedColumn = nil
        databaseType = nil
        cellWriter = .none
        rowsAreInserted = false
    }

    func getEditedFields() -> [InspectorFieldEdit] {
        fields.compactMap { field in
            guard field.hasEdit else { return nil }
            return InspectorFieldEdit(
                columnIndex: field.columnIndex,
                columnName: field.columnName,
                newValue: field.effectiveValue,
                removesField: field.isPendingRemoval,
                isExpression: field.isPendingExpression
            )
        }
    }
}
