//
//  DataGridView+Popovers.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

// MARK: - Popover Editors

extension TableViewCoordinator {
    func cellValue(at row: Int, column columnIndex: Int) -> String? {
        guard let displayRow = displayRow(at: row), columnIndex >= 0, columnIndex < displayRow.values.count else {
            return nil
        }
        return displayRow.values[columnIndex].asText
    }

    func cellTypedValue(at row: Int, column columnIndex: Int) -> PluginCellValue {
        guard let displayRow = displayRow(at: row), columnIndex >= 0, columnIndex < displayRow.values.count else {
            return .null
        }
        return displayRow.values[columnIndex]
    }

    func toggleForeignKeyPreview(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        if let popover = activeFKPreviewPopover, popover.isShown {
            popover.close()
            clearFKPreviewState()
            return
        }
        showForeignKeyPreview(tableView: tableView, row: row, column: column, columnIndex: columnIndex)
    }

    func showForeignKeyPreview(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let fkInfo = tableRows.columnForeignKeys[columnName] else { return }
        let cellValue = cellValue(at: row, column: columnIndex)
        guard let databaseType, let connectionId else { return }
        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let model = FKPreviewModel(cellValue: cellValue, fkInfo: fkInfo)
        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        let popover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 380, height: 400)
        ) { [weak self] dismiss in
            ForeignKeyPreviewView(
                model: model,
                connectionId: connectionId,
                databaseType: databaseType,
                onNavigate: { [weak self, model] in
                    dismiss()
                    guard let value = model.cellValue else { return }
                    self?.delegate?.dataGridNavigateFK(value: value, fkInfo: model.fkInfo, openInNewTab: false)
                },
                onDismiss: dismiss
            )
        }
        activeFKPreviewPopover = popover
        activeFKPreviewModel = model
        activeFKPreviewColumnIndex = columnIndex
    }

    func clearFKPreviewState() {
        activeFKPreviewPopover = nil
        activeFKPreviewModel = nil
        activeFKPreviewColumnIndex = nil
    }

    func refreshFKPreviewForRowChange() {
        guard let popover = activeFKPreviewPopover, popover.isShown,
              let model = activeFKPreviewModel,
              let columnIndex = activeFKPreviewColumnIndex,
              let tableView else {
            return
        }
        let focusedRow = (tableView as? KeyHandlingTableView)?.focusedRow ?? -1
        let newRow = focusedRow >= 0 ? focusedRow : (tableView.selectedRowIndexes.max() ?? -1)
        guard newRow >= 0,
              let tableColumnIndex = tableColumnIndex(for: columnIndex) else {
            popover.close()
            clearFKPreviewState()
            return
        }
        let tableRows = tableRowsProvider()
        guard columnIndex < tableRows.columns.count,
              let fkInfo = tableRows.columnForeignKeys[tableRows.columns[columnIndex]] else {
            popover.close()
            clearFKPreviewState()
            return
        }
        let newValue = cellValue(at: newRow, column: columnIndex)
        let newRect = tableView.rect(ofRow: newRow).intersection(tableView.rect(ofColumn: tableColumnIndex))
        guard !newRect.isEmpty else {
            popover.close()
            clearFKPreviewState()
            return
        }
        model.cellValue = newValue
        model.fkInfo = fkInfo
        popover.positioningRect = newRect
    }

    func dismissFKPreviewOnColumnChange() {
        guard let popover = activeFKPreviewPopover, popover.isShown else { return }
        popover.close()
        clearFKPreviewState()
    }

    func showJSONEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = cellValue(at: row, column: columnIndex)
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]

        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 560, height: 420)
        ) { [weak self] dismiss in
            JSONEditorContentView(
                initialValue: currentValue,
                columnName: columnName,
                onCommit: { newValue in
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss,
                onPopOut: { currentText in
                    dismiss()
                    self?.activePoppedOutEditor = JSONViewerWindowController.open(
                        text: currentText,
                        columnName: columnName,
                        isEditable: true,
                        onCommit: { newValue in
                            self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                        }
                    )
                }
            )
        }
    }

    func showBlobEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = blobStringValue(at: row, columnIndex: columnIndex)
        let columnName = columnName(at: columnIndex)
        let image = blobImage(at: row, columnIndex: columnIndex)

        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: nil
        ) { [weak self] dismiss in
            BlobPopoverContentView(
                initialValue: currentValue,
                image: image,
                columnName: columnName,
                isEditable: true,
                onCommit: { newValue in
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onCommitBytes: { data in
                    self?.commitBinaryEdit(row: row, columnIndex: columnIndex, data: data)
                },
                onDismiss: dismiss
            )
        }
    }

    /// A date control has no vocabulary for "I could not read this": `NSDatePicker.dateValue` and
    /// every SwiftUI `DatePicker` binding are a non-optional `Date`, so a cell the parser rejects
    /// gets seeded with today and an unchanged confirm writes today over the stored value in a
    /// spelling the column never used. Such a cell goes to the text editor instead, where the value
    /// stays visible and the user can repair it. An empty cell has nothing to misrepresent and keeps
    /// the picker.
    func opensDatePicker(row: Int, columnIndex: Int) -> Bool {
        guard let value = cellValue(at: row, column: columnIndex),
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return true }
        return DatabaseDateParser.parse(value) != nil
    }

    func showDateTimePickerPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columnTypes.count else { return }
        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let columnType = tableRows.columnTypes[columnIndex]
        let parsed = DatabaseDateParser.parse(cellValue(at: row, column: columnIndex))
        let initialDate = parsed?.date ?? Date()
        let timeZone = parsed?.timeZone ?? DateEditingService.defaultTimeZone
        let components = DateEditingService.components(for: columnType)

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView
        ) { [weak self] dismiss in
            DateTimePickerContentView(
                initialDate: initialDate,
                components: components,
                timeZone: timeZone,
                onCommit: { picked in
                    guard picked != initialDate else { return }
                    let newValue = parsed
                        .map { DateEditingService.string(from: picked, like: $0, offered: components) }
                        ?? DateEditingService.defaultString(from: picked, columnType: columnType)
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func showEnumPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let allowedValues = tableRows.columnEnumValues[columnName] else { return }

        let currentValue = cellValue(at: row, column: columnIndex)
        let isNullable = tableRows.columnNullable[columnName] ?? true
        let defaultValue = tableRows.columnDefaults[columnName] ?? nil

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        EnumMenuPicker.presentEnum(
            relativeTo: cellRect,
            in: tableView,
            allowedValues: allowedValues,
            currentValue: currentValue,
            isNullable: isNullable,
            defaultValue: defaultValue
        ) { [weak self] newValue in
            self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
        }
    }

    /// The value picker a writable foreign key cell opens in place of the plain text editor.
    ///
    /// Falls back to that editor whenever the picker cannot be built, the way the array editor falls
    /// back on a literal it cannot parse: an engine with no SQL dialect has nothing to search the
    /// referenced table with, a column of a composite key cannot be picked on its own, and a cell
    /// that opens nothing at all reads as a broken grid.
    ///
    /// `canStartInlineEdit` is asked again here because `CellInteractionResolver` knows only the
    /// columns the plugin declares immutable. A generated column carrying foreign key metadata,
    /// which SQLite allows, would otherwise open the picker and have its commit dropped by
    /// `recordCellEdit`, closing the popover over a cell that never changed.
    func showForeignKeyPicker(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]

        guard let connectionId,
              let databaseType,
              let fkInfo = tableRows.columnForeignKeys[columnName],
              canStartInlineEdit(row: row, columnIndex: columnIndex),
              PluginManager.shared.sqlDialect(for: databaseType) != nil,
              !ForeignKeyConstraintSpan.isMultiColumn(fkInfo, among: tableRows.columnForeignKeys)
        else {
            beginCellEdit(row: row, tableColumnIndex: column)
            return
        }

        let scope = DatabaseScope(
            connectionId: connectionId,
            database: databaseName ?? DatabaseManager.shared.browseScope(for: connectionId)?.database ?? "",
            schema: schemaName
        )

        let currentValue = cellValue(at: row, column: columnIndex)
        let isNullable = tableRows.columnNullable[columnName] ?? true
        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView
        ) { [weak self] dismiss in
            ForeignKeyPickerView(
                scope: scope,
                databaseType: databaseType,
                fkInfo: fkInfo,
                currentValue: currentValue,
                isNullable: isNullable,
                onCommit: { newValue in
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    func showSetPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]
        guard let allowedValues = tableRows.columnEnumValues[columnName] else { return }

        let currentValue = cellValue(at: row, column: columnIndex)
        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        EnumMenuPicker.presentSet(
            relativeTo: cellRect,
            in: tableView,
            allowedValues: allowedValues,
            currentCsv: currentValue
        ) { [weak self] newValue in
            self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
        }
    }

    func showArrayEditorPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]

        let typedValue = cellTypedValue(at: row, column: columnIndex)
        let elements: [PostgresArrayElement]?
        if typedValue.isNull {
            elements = nil
        } else {
            guard let parsed = PostgresArrayLiteralCodec.parse(typedValue.asText ?? "") else {
                beginCellEdit(row: row, tableColumnIndex: column)
                return
            }
            elements = parsed
        }

        let allowedValues = tableRows.columnEnumValues[columnName] ?? []
        let isNullable = tableRows.columnNullable[columnName] ?? true
        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))

        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            behavior: .applicationDefined
        ) { [weak self] dismiss in
            ArrayValueEditorView(
                initialElements: elements,
                allowedValues: allowedValues,
                isNullable: isNullable,
                onCommit: { newValue in
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                },
                onDismiss: dismiss
            )
        }
    }

    /// Only one cell editor popover is open at a time, and the outgoing one is closed before the
    /// next is presented rather than after. An `.applicationDefined` popover such as the array
    /// editor stays on screen until something closes it, so forgetting it would strand an editor
    /// nothing can dismiss, and closing it once the replacement is already up takes first responder
    /// back off the editor that just opened.
    func dismissActiveCellEditorPopover() {
        guard let popover = activeCellEditorPopover else { return }
        activeCellEditorPopover = nil
        popover.close()
    }

    /// The popped-out JSON editor is a window rather than a popover, so it survives everything that
    /// closes a popover while still committing through the display row it was opened from. Only a
    /// replaced row set invalidates it, never the user opening a different cell's editor.
    func dismissPoppedOutCellEditor() {
        guard let editor = activePoppedOutEditor else { return }
        activePoppedOutEditor = nil
        editor.close()
    }

    func showDropdownMenu(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }

        let currentValue = cellValue(at: row, column: columnIndex)
        let context = DropdownMenuContext(row: row, columnIndex: columnIndex)

        let options: [String]
        if let custom = customDropdownOptions?[columnIndex] {
            options = custom
        } else if let dbType = databaseType, PluginManager.shared.usesTrueFalseBooleans(for: dbType) {
            options = ["true", "false"]
        } else {
            options = ["1", "0"]
        }

        let menu = NSMenu()
        for option in options {
            let item = NSMenuItem(title: option, action: #selector(dropdownMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = context
            if option == currentValue {
                item.state = .on
            }
            menu.addItem(item)
        }

        let columnName = tableRows.columns[columnIndex]
        let isNullable = tableRows.columnNullable[columnName] ?? true
        if isNullable && customDropdownOptions?[columnIndex] == nil {
            menu.addItem(.separator())
            let nullItem = NSMenuItem(
                title: String(localized: "Set NULL"),
                action: #selector(dropdownMenuNullSelected(_:)),
                keyEquivalent: ""
            )
            nullItem.target = self
            nullItem.representedObject = context
            if currentValue == nil {
                nullItem.state = .on
            }
            menu.addItem(nullItem)
        }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        menu.popUp(positioning: nil, at: NSPoint(x: cellRect.minX, y: cellRect.maxY), in: tableView)
    }

    @objc func dropdownMenuItemSelected(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? DropdownMenuContext else { return }
        commitPopoverEdit(row: context.row, columnIndex: context.columnIndex, newValue: sender.title)
    }

    @objc func dropdownMenuNullSelected(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? DropdownMenuContext else { return }
        commitPopoverEdit(row: context.row, columnIndex: context.columnIndex, newValue: nil)
    }

    func commitPopoverEdit(row: Int, columnIndex: Int, newValue: String?) {
        commitCellEdit(row: row, columnIndex: columnIndex, newValue: newValue)
    }

    func commitBinaryEdit(row: Int, columnIndex: Int, data: Data) {
        commitTypedCellEdit(row: row, columnIndex: columnIndex, newValue: .bytes(data))
    }

    func showJSONViewerPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = cellValue(at: row, column: columnIndex)
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]

        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 560, height: 360)
        ) { dismiss in
            JSONViewerContentView(
                initialValue: currentValue,
                columnName: columnName,
                onDismiss: dismiss,
                onPopOut: { currentText in
                    dismiss()
                    JSONViewerWindowController.open(
                        text: currentText,
                        columnName: columnName,
                        isEditable: false,
                        onCommit: nil
                    )
                }
            )
        }
    }

    func showPhpViewerPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = cellValue(at: row, column: columnIndex)
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }
        let columnName = tableRows.columns[columnIndex]

        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: NSSize(width: 560, height: 360)
        ) { dismiss in
            PhpViewerContentView(
                initialValue: currentValue,
                columnName: columnName,
                onDismiss: dismiss,
                onPopOut: { currentText in
                    dismiss()
                    PhpViewerWindowController.open(text: currentText, columnName: columnName)
                }
            )
        }
    }

    func showBlobViewerPopover(tableView: NSTableView, row: Int, column: Int, columnIndex: Int) {
        let currentValue = blobStringValue(at: row, columnIndex: columnIndex)
        let columnName = columnName(at: columnIndex)
        let image = blobImage(at: row, columnIndex: columnIndex)

        guard presentsCell(row: row, tableColumnIndex: column) else { return }

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: nil
        ) { dismiss in
            BlobPopoverContentView(
                initialValue: currentValue,
                image: image,
                columnName: columnName,
                isEditable: false,
                onDismiss: dismiss
            )
        }
    }

    func showSvgViewerPopover(
        tableView: NSTableView,
        row: Int,
        column: Int,
        columnIndex: Int,
        isEditable: Bool
    ) {
        guard presentsCell(row: row, tableColumnIndex: column) else { return }
        let columnName = columnName(at: columnIndex)
        let value = cellValue(at: row, column: columnIndex) ?? ""

        let cellRect = tableView.rect(ofRow: row).intersection(tableView.rect(ofColumn: column))
        dismissActiveCellEditorPopover()
        activeCellEditorPopover = PopoverPresenter.show(
            relativeTo: cellRect,
            of: tableView,
            contentSize: nil
        ) { [weak self] dismiss in
            SvgViewerContentView(
                initialValue: value,
                isEditable: isEditable,
                onDismiss: dismiss,
                onCommit: isEditable ? { newValue in
                    self?.commitPopoverEdit(row: row, columnIndex: columnIndex, newValue: newValue)
                } : nil,
                onPopOut: { currentText in
                    dismiss()
                    CellImageWindowController.open(
                        data: Data(currentText.utf8),
                        format: .svg,
                        sourceKind: .markup,
                        columnName: columnName
                    )
                }
            )
        }
    }

    private func displayFormatOverride(at columnIndex: Int) -> ValueDisplayFormat? {
        guard columnIndex >= 0, columnIndex < columnDisplayFormats.count else { return nil }
        return columnDisplayFormats[columnIndex]
    }

    private func columnName(at columnIndex: Int) -> String? {
        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return nil }
        return tableRows.columns[columnIndex]
    }

    /// The cell's stored bytes paired with what they turned out to be, or nil when they are not an
    /// image or the column asked for its value raw.
    private func blobImage(at row: Int, columnIndex: Int) -> CellImageValue? {
        guard displayFormatOverride(at: columnIndex) != .raw else { return nil }
        let value = cellTypedValue(at: row, column: columnIndex)
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

    private func blobStringValue(at row: Int, columnIndex: Int) -> String? {
        switch cellTypedValue(at: row, column: columnIndex) {
        case .null: return nil
        case .text(let text): return text
        case .bytes(let data): return String(data: data, encoding: .isoLatin1)
        }
    }
}

private final class DropdownMenuContext {
    let row: Int
    let columnIndex: Int

    init(row: Int, columnIndex: Int) {
        self.row = row
        self.columnIndex = columnIndex
    }
}
