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

    /// Every selected cell that has a value holds bytes, one character per byte in `originalValue`.
    /// The column type cannot say so: a spatial column is text on one engine and a blob on another.
    var isBinaryValue: Bool = false

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

    /// False for a NOT NULL column. Nil from the schema reads as nullable, as the grid's menus do.
    var isNullable = true

    /// Leaving the column out of an INSERT makes the server fill it, which is what Set DEFAULT gives.
    var serverAssignsValue = false

    var displayFormat: ValueDisplayFormat?

    /// A value the selected rows hold. A lengthless MySQL `CHAR` takes the compact UUID form only when its values do.
    var sampleText: String?

    var declaredType: String?

    /// The edit is recorded elsewhere: by the grid that owns a schema row, or in the change manager for rows
    /// that now disagree, which no single pending value can stand for.
    var hasCommittedEdit: Bool = false

    var originalValue: String?

    var hasMultipleValues: Bool

    var pendingValue: String?

    var isPendingNull: Bool

    var isPendingDefault: Bool

    /// `pendingValue` is SQL from `CellExpressionVocabulary`, staged to be written unquoted.
    var isPendingExpression = false

    /// No selected row has a field for the column, which only an engine that tells a missing field
    /// from NULL reports.
    var isAbsent = false

    /// The user asked for the field to be taken out of the row.
    var isPendingRemoval = false

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

/// A field the inspector writes itself, for the save that runs when no pending change holds its
/// edits.
struct InspectorFieldEdit: Equatable {
    let columnIndex: Int
    let columnName: String
    let newValue: String?
    /// The edit takes the field out of the row, which `newValue` cannot say: it reads nil for NULL
    /// as well.
    var removesField = false
    /// `newValue` is SQL picked from the field's menu, written unquoted.
    var isExpression = false
}

@MainActor
final class MultiRowEditState: ObservableObject {
    @Published var fields: [FieldEditState] = []

    /// A field's new literal value, and whether it arrived a character at a time. Typing is folded into one
    /// undo step; choosing NULL, DEFAULT or a picker value is its own step.
    @Published var onFieldChanged: ((Int, PluginCellValue, FieldEditContinuity) -> Void)?

    /// A field set to SQL the database evaluates, picked from its menu or typed. `onFieldChanged` cannot carry
    /// that, and a plain `.text` must never be read as SQL.
    @Published var onFieldExpressionChanged: ((Int, String, FieldEditContinuity) -> Void)?

    /// A value of its own for each row, such as a fresh UUID: one value over several rows would repeat a key.
    @Published var onFieldValuesChanged: ((Int, [RowID: PluginCellValue]) -> Void)?

    /// A field cleared back to what the rows held, when they disagree on it, some of them have
    /// no field for it, or some held SQL. It has no single value to send, so it asks for each row's own
    /// configured value instead, for the field to go missing again on the rows that lacked it (the first set),
    /// and for SQL again on the rows that held it (the second).
    @Published var onFieldReverted: ((Int, [RowID: PluginCellValue], Set<RowID>, Set<RowID>) -> Void)?

    /// Remove Field on a field, for the rows the selection was configured with.
    @Published var onFieldRemoved: ((Int, [RowID]) -> Void)?

    /// A value window still open over a selection that has moved on. It names the rows it was
    /// opened for, because the fields it was opened from are gone. The flag says the value is SQL.
    @Published var onDetachedFieldChanged: ((Int, PluginCellValue, [RowID], Bool) -> Void)?

    @Published private(set) var selectedRowIndices: Set<Int> = []

    /// The rows an edit is staged against, captured when the selection was configured.
    ///
    /// `selectedRowIndices` are display positions, and a commit that resolves them when the
    /// keystroke arrives writes into whatever row the sort, the value filter or a later selection
    /// left at that position.
    @Published private(set) var rowIDs: [RowID] = []

    @Published private(set) var allRows: [[String?]] = []
    /// The columns each row in `allRows` has no field for.
    @Published private(set) var absentCells: [Set<Int>] = []
    /// The columns each row in `allRows` holds staged SQL in.
    @Published private(set) var expressionCells: [Set<Int>] = []
    @Published private(set) var columns: [String] = []
    @Published private(set) var columnTypes: [ColumnType] = []
    private var nonNullableColumns: Set<String> = []

    /// The engine whose vocabulary typed text is read against, and what the table's writer takes. Nil and
    /// `.none` offer no Set Value command and promote nothing.
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
        selectedRowIndices: Set<Int>,
        rowIDs: [RowID] = [],
        allRows: [[String?]],
        absentCells: [Set<Int>] = [],
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
        let selectionChanged = self.selectedRowIndices != selectedRowIndices

        self.selectedRowIndices = selectedRowIndices
        self.rowIDs = rowIDs
        self.allRows = allRows
        self.absentCells = absentCells
        self.expressionCells = expressionCells
        self.columns = columns
        self.columnTypes = columnTypes
        self.nonNullableColumns = nonNullableColumns
        self.databaseType = databaseType
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
                    && oldField.isAbsent == isAbsent {
                    preservedId = oldField.id
                    pendingValue = oldField.pendingValue
                    isPendingNull = oldField.isPendingNull
                    isPendingDefault = oldField.isPendingDefault
                    isPendingExpression = oldField.isPendingExpression
                    isPendingRemoval = oldField.isPendingRemoval
                }
            }

            /// A column edited elsewhere, in the grid or by an earlier inspector edit. A modified field that is now
            /// missing is one an edit removed, and one that now reads NULL is a pending NULL: written as an empty
            /// pending value it read as `''`, and the boolean picker showed false. Rows that now disagree stay
            /// Multiple values: an empty pending value there read as one value, and typing into it looked like
            /// editing a single cell.
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
                isServerOwned: serverOwnedColumns.contains(columnName),
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
                displayFormatOverride: displayFormat,
                isBinaryValue: newField.isBinaryValue,
                revealsInvisibleCharacters: revealsInvisibleCharacters
            )
            newFields.append(newField)
        }

        self.fields = newFields
    }

    /// The columns whose selected cells are bytes. One text cell rules a column out, because a
    /// binary field commits bytes to every selected row, and a column of NULLs alone has none.
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

    // A value holding an invisible character takes the text view only while marks are on, so a field
    // shown when the setting changes is resolved again.
    private func adoptInvisibleCharacterSetting() {
        let reveals = AppSettingsManager.shared.dataGrid.showInvisibleCharacters
        guard reveals != revealsInvisibleCharacters else { return }
        revealsInvisibleCharacters = reveals
        for index in fields.indices where !fields[index].isSchemaField && fields[index].editor == nil {
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

    /// Configure state for a single schema row supplied by the grid that owns the selection.
    /// Field ids survive a reconfigure of the same row so a commit does not rebuild the
    /// editors and drop focus while the user is still moving between fields.
    func configure(schemaFields: [InspectorRowField], displayRow: Int) {
        let names = schemaFields.map(\.name)
        let reusedIds = selectedRowIndices == [displayRow] && columns == names ? fields.map(\.id) : []

        selectedRowIndices = [displayRow]
        rowIDs = []
        absentCells = []
        expressionCells = []
        databaseType = nil
        cellWriter = .none
        rowsAreInserted = false
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

    /// What Set Value can do to the field, the same answer the grid's menu gives for the column.
    func setValueCommands(for field: FieldEditState, isWritable: Bool) -> [SetValueCommand] {
        setValueContext(for: field, isWritable: isWritable).map(SetValueOptions.commands(for:)) ?? []
    }

    func setValueContext(for field: FieldEditState, isWritable: Bool) -> SetValueContext? {
        guard let databaseType, !field.isSchemaField else { return nil }
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
        /// A NOT NULL column whose type has no empty value holds nothing an emptied field could
        /// mean, so the field goes back to its stored value, as the grid's cell does.
        if staged == .null, !fields[index].isNullable {
            pending = nil
            staged = nil
        }
        resetPending(at: index)
        fields[index].pendingValue = pending
        /// The field keeps its empty text while the change it stages is NULL: swapping the editor
        /// for the pending NULL pill would take the field away in the middle of typing a new value.
        if let expression {
            onFieldExpressionChanged?(index, expression, .typing)
        } else if let staged {
            onFieldChanged?(index, staged, .typing)
        } else if hadPendingEdit {
            /// `originalValue` is nil for three different situations, and only one of them is a
            /// value: a stored NULL, a selection whose rows do not agree, and a field the rows do
            /// not have. Sending it as one value wrote NULL into every selected row when the user
            /// cleared a field they all disagreed on, which the field then reported as unedited.
            let absentRows = configuredAbsentRows(atColumn: index)
            let expressionRows = configuredExpressionRows(atColumn: index)
            if fields[index].hasMultipleValues || !absentRows.isEmpty || !expressionRows.isEmpty {
                onFieldReverted?(index, configuredValues(atColumn: index), absentRows, expressionRows)
            } else {
                onFieldChanged?(index, storedCell(original, atColumn: index), .typing)
            }
        }
    }

    /// The vocabulary's SQL for typed text, as the grid reads a typed cell. A value the rows were configured
    /// with never comes through here, so stored text that spells a function stays text.
    private func typedExpression(_ text: String, columnType: ColumnType?) -> String? {
        guard let databaseType,
              let entry = CellEntry.typed(text, columnType: columnType, databaseType: databaseType, writer: cellWriter),
              entry.isExpression,
              case .text(let sql) = entry.value else { return nil }
        return sql
    }

    /// What each row held when the selection was configured, which is what a field with no value of
    /// its own reverts to.
    private func configuredValues(atColumn index: Int) -> [RowID: PluginCellValue] {
        var values: [RowID: PluginCellValue] = [:]
        for (rowID, row) in zip(rowIDs, allRows) where row.indices.contains(index) {
            values[rowID] = storedCell(row[index], atColumn: index)
        }
        return values
    }

    /// A binary field holds its bytes one character per byte. Sent back as text, that string is
    /// staged over the blob as a real change, and SQLite cuts it at the first NUL.
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

    /// Takes the field out of every selected row. The value is gone as well, so it reads as
    /// neither NULL nor any value.
    ///
    /// Rows that had no field for it when the selection was configured are back as they were,
    /// which leaves nothing pending, exactly as typing a field's own value back does.
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

    /// Several rows each get a UUID of their own, so the field then reads Multiple values, and typing over it
    /// writes the typed value to every row as on any field the rows disagree on.
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
        /// The rows hold these values now, so clearing a later edit goes back to them, as it does once the
        /// inspector is rebuilt from the rows.
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
        selectedRowIndices = []
        rowIDs = []
        allRows = []
        absentCells = []
        expressionCells = []
        columns = []
        columnTypes = []
        nonNullableColumns = []
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
