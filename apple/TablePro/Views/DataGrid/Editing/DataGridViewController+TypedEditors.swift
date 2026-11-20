//
//  DataGridViewController+TypedEditors.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit
import TableProSQLQuoting

extension DataGridViewController {
    // MARK: - Chevron

    func openChevronEditor(for target: DataGridEditTarget) {
        guard let cell = editCell(for: target) else { return }
        openChevronEditor(at: cell.coord)
    }

    func openChevronEditor(at coord: GridCoord) {
        guard model.configuration.isEditable, let cell = editCell(at: coord), !isRowDeleted(cell.row.id) else { return }
        guard model.isColumnWritable(cell.column) else {
            refuseEdit(of: cell.column)
            return
        }
        let target = cell.target
        guard loadsUnloadedValue(of: cell, then: { $0.openChevronEditor(for: target) }) else { return }
        guard let editor = chevronEditor(for: cell) else { return }
        present(editor, for: cell)
    }

    // What the chevron opens on a cell the grid can write; nil where the column has no typed editor.
    func chevronEditor(for cell: DataGridEditCell) -> DataGridChevronEditor? {
        let configuration = model.configuration
        let dataIndex = cell.column.dataIndex
        if configuration.dropdownColumns?.contains(dataIndex) == true {
            return dropdownOptions(for: cell) == nil ? nil : .dropdown
        }
        if configuration.typePickerColumns?.contains(dataIndex) == true { return .typePicker }
        guard let columnType = cell.column.type else { return nil }
        let allowedValues = model.rows.columnEnumValues[cell.column.name] ?? []
        if columnType.isBooleanType { return .boolean }
        if columnType.supportsElementEditing { return listsArrayElements(cell, columnType: columnType) ? .array : .inlineText }
        if columnType.isVectorType {
            return cell.value.asText.map(VectorLiteral.isVectorText) == true ? .vector : .inlineText
        }
        if !allowedValues.isEmpty { return columnType.isSetType ? .set : .enumeration }
        if columnType.isJsonType { return .json }
        if columnType.isBlobType { return .blob }
        if columnType.isDateType { return opensDatePicker(cell.value.asText) ? .datePicker : .inlineText }
        if columnType.isEnumOrSetType { return .inlineText }
        return nil
    }

    func present(_ editor: DataGridChevronEditor, for cell: DataGridEditCell) {
        switch editor {
        case .dropdown, .boolean:
            showDropdownMenu(for: cell)
        case .typePicker:
            showTypePicker(for: cell)
        case .array:
            showArrayEditor(for: cell)
        case .vector:
            showVectorPopover(for: cell, isEditable: textEditableValue(of: cell) != nil)
        case .set:
            showSetMenu(for: cell, allowedValues: model.rows.columnEnumValues[cell.column.name] ?? [])
        case .enumeration:
            showEnumMenu(for: cell, allowedValues: model.rows.columnEnumValues[cell.column.name] ?? [])
        case .json:
            showJSONEditor(for: cell)
        case .blob:
            showBlobPopover(for: cell, isEditable: true)
        case .datePicker:
            guard let columnType = cell.column.type else { return }
            showDateTimePicker(for: cell, columnType: columnType)
        case .inlineText:
            beginTextEditing(cell)
        }
    }

    // MARK: - Commit closures

    // Never a display position: an open editor outlives a filter or a sort (interaction 5).
    func enteredTextCommit(for cell: DataGridEditCell) -> (String?) -> Void {
        let target = cell.target
        return { [weak self, weak model = self.model] text in
            Self.commitEnteredText(text, to: target, in: model)
            self?.refreshHeldRows()
        }
    }

    func valueCommit(for cell: DataGridEditCell) -> (PluginCellValue) -> Void {
        let target = cell.target
        return { [weak self, weak model = self.model] value in
            Self.commitValue(value, to: target, in: model)
            self?.refreshHeldRows()
        }
    }

    // MARK: - Menus

    // nil on a dropdown column whose owner has no list for this row.
    func dropdownOptions(for cell: DataGridEditCell) -> (options: [GridMenuOption], isOwnerList: Bool)? {
        let configuration = model.configuration
        let dataIndex = cell.column.dataIndex
        // A list that depends on the row cannot live in a dictionary keyed by column.
        if let custom = model.dataSource?.gridMenuOptions(for: cell.row.id, column: cell.column)
            ?? configuration.customDropdownOptions?[dataIndex] {
            return (custom, true)
        }
        if configuration.dropdownColumns?.contains(dataIndex) == true { return nil }
        return (GridMenuOption.values(configuration.traits.usesTrueFalseBooleans ? ["true", "false"] : ["1", "0"]), false)
    }

    func showDropdownMenu(for cell: DataGridEditCell) {
        reveal(row: cell.coord.row, displayColumn: cell.coord.displayColumn)
        guard let frame = cellFrame(of: cell.coord) else { return }
        let current = cell.value.asText
        guard let (options, isOwnerList) = dropdownOptions(for: cell) else { return }

        let commit = enteredTextCommit(for: cell)
        let target = cell.target
        let menu = NSMenu()
        for option in options {
            switch option {
            case .sectionHeader(let title):
                menu.addItem(NSMenuItem.sectionHeaderCompat(title: title))
            case .value(let title, let sql):
                menu.addItem(DataGridMenuAction.item(title, state: sql == current ? .on : .off) { commit(sql) })
            case .clear(let title):
                menu.addItem(DataGridMenuAction.item(title, state: current == nil ? .on : .off) { commit(nil) })
            case .custom(let title):
                menu.addItem(DataGridMenuAction.item(title) { [weak self] in
                    guard let self, let cell = self.editCell(for: target) else { return }
                    self.showCustomValuePopover(for: cell)
                })
            }
        }
        let isNullable = model.rows.columnNullable[cell.column.name] ?? true
        if isNullable, !isOwnerList {
            menu.addItem(.separator())
            menu.addItem(DataGridMenuAction.item(String(localized: "Set NULL"), state: current == nil ? .on : .off) { commit(nil) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: frame.rect.minX, y: frame.rect.maxY), in: frame.pane.tableView)
    }

    func showEnumMenu(for cell: DataGridEditCell, allowedValues: [String]) {
        reveal(row: cell.coord.row, displayColumn: cell.coord.displayColumn)
        guard let frame = cellFrame(of: cell.coord) else { return }
        let rows = model.rows
        let name = cell.column.name
        // A string default arrives as the SQL after DEFAULT, quoted; the picker matches unquoted tokens.
        let storedDefault = rows.columnDefaults[name] ?? nil
        let defaultValue = storedDefault.flatMap { SQLQuoting.decodedStringLiteral($0) } ?? storedDefault
        let commit = enteredTextCommit(for: cell)
        EnumMenuPicker.presentEnum(
            relativeTo: frame.rect,
            in: frame.pane.tableView,
            allowedValues: allowedValues,
            currentValue: cell.value.asText,
            isNullable: rows.columnNullable[name] ?? true,
            defaultValue: defaultValue
        ) { commit($0) }
    }

    func showSetMenu(for cell: DataGridEditCell, allowedValues: [String]) {
        reveal(row: cell.coord.row, displayColumn: cell.coord.displayColumn)
        guard let frame = cellFrame(of: cell.coord) else { return }
        let commit = enteredTextCommit(for: cell)
        EnumMenuPicker.presentSet(
            relativeTo: frame.rect,
            in: frame.pane.tableView,
            allowedValues: allowedValues,
            currentCsv: cell.value.asText
        ) { commit($0) }
    }

    // MARK: - Popovers

    func showCustomValuePopover(for cell: DataGridEditCell) {
        let commit = enteredTextCommit(for: cell)
        let escape = stringLiteralEscaper()
        let prefix = SQLStringLiteralPrefix.forDatabaseType(editingDatabaseType)
        let current = cell.value.asText ?? ""
        presentTypedPopover(for: cell, edits: true) { dismiss in
            CustomValueContentView(
                initialValue: current,
                escapeStringLiteral: escape,
                stringLiteralPrefix: prefix,
                onCommit: { commit($0) },
                onDismiss: dismiss
            )
        }
    }

    func showTypePicker(for cell: DataGridEditCell) {
        let commit = enteredTextCommit(for: cell)
        let databaseType = editingDatabaseType ?? .mysql
        let scope = userDefinedTypeScope
        let current = cell.value.asText ?? ""
        presentTypedPopover(for: cell, edits: true) { dismiss in
            UserDefinedTypeAwarePicker(scope: scope) { userDefinedTypes in
                TypePickerContentView(
                    databaseType: databaseType,
                    currentValue: current,
                    userDefinedTypes: userDefinedTypes,
                    onCommit: { commit($0) },
                    onDismiss: dismiss
                )
            }
        }
    }

    // A date control has no unreadable state: a value the parser rejects keeps the text editor.
    func opensDatePicker(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return DatabaseDateParser.parse(value) != nil
    }

    func showDateTimePicker(for cell: DataGridEditCell, columnType: ColumnType) {
        let commit = enteredTextCommit(for: cell)
        let parsed = DatabaseDateParser.parse(cell.value.asText)
        // A fraction near one second rounds up, which would open past the stored value.
        let initialDate = parsed?.wholeSecond ?? Date()
        let timeZone = parsed?.timeZone ?? DateEditingService.defaultTimeZone
        let components = DateEditingService.components(for: columnType)
        presentTypedPopover(for: cell, edits: true) { dismiss in
            DateTimePickerContentView(
                initialDate: initialDate,
                components: components,
                timeZone: timeZone,
                carriesItsOwnZone: parsed?.carriesItsOwnZone ?? false,
                onCommit: { picked in
                    guard picked != initialDate else { return }
                    let text = parsed.map { DateEditingService.string(from: picked, like: $0, offered: components) }
                        ?? DateEditingService.defaultString(from: picked, columnType: columnType)
                    commit(text)
                },
                onDismiss: dismiss
            )
        }
    }

    func listsArrayElements(_ cell: DataGridEditCell, columnType: ColumnType) -> Bool {
        guard !cell.value.isNull else { return true }
        return PostgresArrayLiteralCodec.parse(cell.value.asText ?? "", delimiter: PostgresArrayDelimiter.forColumn(columnType)) != nil
    }

    func showArrayEditor(for cell: DataGridEditCell) {
        guard let columnType = cell.column.type else { return }
        let delimiter = PostgresArrayDelimiter.forColumn(columnType)
        let value = cell.value
        let literal: String?
        if value.isNull {
            literal = nil
        } else {
            let stored = value.asText ?? ""
            guard PostgresArrayLiteralCodec.parse(stored, delimiter: delimiter) != nil else {
                beginTextEditing(cell)
                return
            }
            literal = stored
        }
        let rows = model.rows
        let name = cell.column.name
        let allowedValues = rows.columnEnumValues[name] ?? []
        let isNullable = rows.columnNullable[name] ?? true
        let elementEditor = columnType.arrayElementEditor ?? .scalar
        let commit = enteredTextCommit(for: cell)
        presentTypedPopover(for: cell, edits: true, behavior: .applicationDefined) { dismiss in
            ArrayValueEditorView(
                literal: literal,
                allowedValues: allowedValues,
                isNullable: isNullable,
                delimiter: delimiter,
                elementEditor: elementEditor,
                onCommit: { commit($0) },
                onDismiss: dismiss
            )
        }
    }

    func showVectorPopover(for cell: DataGridEditCell, isEditable: Bool) {
        guard let literal = cell.value.asText, VectorLiteral.isVectorText(literal) else {
            if isEditable { beginTextEditing(cell) }
            return
        }
        let commit = enteredTextCommit(for: cell)
        let expectedDimensions = cell.column.type?.vectorDimensions
        presentTypedPopover(
            for: cell,
            edits: isEditable,
            behavior: isEditable ? .applicationDefined : .semitransient
        ) { dismiss in
            VectorValueView(
                literal: literal,
                expectedDimensions: expectedDimensions,
                isEditable: isEditable,
                onCommit: { commit($0) },
                onDismiss: dismiss
            )
        }
    }

    func showSvgPopover(for cell: DataGridEditCell, isEditable: Bool) {
        let commit = enteredTextCommit(for: cell)
        let value = cell.value.asText ?? ""
        let name = cell.column.name
        presentTypedPopover(for: cell, edits: isEditable) { dismiss in
            SvgViewerContentView(
                initialValue: value,
                isEditable: isEditable,
                onDismiss: dismiss,
                onCommit: isEditable ? { commit($0) } : nil,
                onPopOut: { text in
                    dismiss()
                    CellImageWindowController.open(data: Data(text.utf8), format: .svg, sourceKind: .markup, columnName: name)
                }
            )
        }
    }

    func showJSONEditor(for cell: DataGridEditCell) {
        let commit = enteredTextCommit(for: cell)
        let current = cell.value.asText
        let name = cell.column.name
        let held = heldRow(cell)
        presentTypedPopover(for: cell, edits: true, contentSize: NSSize(width: 560, height: 420)) { [weak self] dismiss in
            JSONEditorContentView(
                initialValue: current,
                columnName: name,
                onCommit: { commit($0) },
                onDismiss: dismiss,
                onPopOut: { text in
                    dismiss()
                    self?.popOutJSONEditor(text: text, baseline: current, columnName: name, held: held)
                }
            )
        }
    }

    // Save compares against the stored value: the popover's text can hold an edit nothing committed yet.
    private func popOutJSONEditor(text: String, baseline: String?, columnName: String, held: DataGridHeldRow) {
        closePoppedOutEditor()
        let target = held.target
        let window = JSONViewerWindowController.open(
            text: text,
            baseline: baseline,
            columnName: columnName,
            isEditable: true,
            onCommit: { [weak self, weak model = self.model] value in
                Self.commitEnteredText(value, to: target, in: model)
                self?.refreshHeldRows()
            }
        )
        editingState.poppedOutEditor = window
        editingState.poppedOutRow = held
    }

    func showJSONViewer(for cell: DataGridEditCell) {
        let current = cell.value.asText
        let name = cell.column.name
        presentTypedPopover(for: cell, edits: false, contentSize: NSSize(width: 560, height: 360)) { dismiss in
            JSONViewerContentView(
                initialValue: current,
                columnName: name,
                onDismiss: dismiss,
                onPopOut: { text in
                    dismiss()
                    JSONViewerWindowController.open(text: text, columnName: name, isEditable: false, onCommit: nil)
                }
            )
        }
    }

    func showPhpViewer(for cell: DataGridEditCell) {
        let current = cell.value.asText
        let name = cell.column.name
        presentTypedPopover(for: cell, edits: false, contentSize: NSSize(width: 560, height: 360)) { dismiss in
            PhpViewerContentView(
                initialValue: current,
                columnName: name,
                onDismiss: dismiss,
                onPopOut: { text in
                    dismiss()
                    PhpViewerWindowController.open(text: text, columnName: name)
                }
            )
        }
    }

    func showBinaryValueViewer(for cell: DataGridEditCell, format: BinaryValueFormat) {
        let data: Data
        switch cell.value {
        case .null: return
        case .bytes(let bytes): data = bytes
        case .text(let text):
            let holdsBytes = BinaryValueBytes.holdsBytes(columnType: cell.column.type)
            data = BinaryValueBytes.data(of: text, holdsBytes: holdsBytes) ?? text.storedBytes
        }
        let name = cell.column.name
        presentTypedPopover(for: cell, edits: false, contentSize: NSSize(width: 560, height: 360)) { dismiss in
            BinaryValueViewerView(
                data: data,
                format: format,
                onPopOut: {
                    dismiss()
                    BinaryValueViewerWindowController.open(data: data, format: format, columnName: name)
                }
            )
            .frame(width: 560)
            .frame(minHeight: 200, maxHeight: 480)
        }
    }

    func showBlobPopover(for cell: DataGridEditCell, isEditable: Bool) {
        let commit = enteredTextCommit(for: cell)
        let commitBytes = valueCommit(for: cell)
        let current = blobText(of: cell.value)
        let image = model.displayFormat(for: cell.column) == .raw ? nil : blobImage(of: cell.value)
        let name = cell.column.name
        presentTypedPopover(for: cell, edits: isEditable) { dismiss in
            BlobPopoverContentView(
                initialValue: current,
                image: image,
                columnName: name,
                isEditable: isEditable,
                onCommit: isEditable ? { commit($0) } : nil,
                onCommitBytes: isEditable ? { commitBytes(.bytes($0)) } : nil,
                onDismiss: dismiss
            )
        }
    }

    private func blobImage(of value: PluginCellValue) -> CellImageValue? {
        switch value {
        case .null:
            return nil
        case .bytes(let bytes):
            guard let format = CellImageSniffer.format(of: bytes) else { return nil }
            return CellImageValue(data: bytes, format: format)
        case .text(let text):
            guard let format = CellImageSniffer.format(ofText: text) else { return nil }
            return CellImageValue(data: text.storedBytes, format: format)
        }
    }

    private func blobText(of value: PluginCellValue) -> String? {
        switch value {
        case .null: return nil
        case .text(let text): return text
        case .bytes(let data): return String(data: data, encoding: .isoLatin1)
        }
    }
}
