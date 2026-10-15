//
//  DataGridView+FillColumn.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension TableViewCoordinator {
    @objc func fillColumn(_ sender: NSMenuItem) {
        guard let columnIndex = sender.representedObject as? Int else { return }
        presentFillColumnDialog(columnIndex: columnIndex)
    }

    func presentFillColumnDialog(columnIndex: Int) {
        guard isEditable, let window = tableView?.window else { return }

        let tableRows = tableRowsProvider()
        guard columnIndex >= 0, columnIndex < tableRows.columns.count else { return }

        let rowCount = fillTargetRows().count
        guard rowCount > 0 else { return }

        let columnName = tableRows.columns[columnIndex]
        let allowsNull = tableRows.columnNullable[columnName] ?? true
        let accessory = FillColumnAccessoryView(allowsNull: allowsNull)

        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Fill column \"%@\""), columnName)
        alert.informativeText = Self.fillImpactDescription(rowCount: rowCount)
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Fill"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        alert.window.initialFirstResponder = accessory.firstResponderView

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let value = self.fillColumnValue(
                text: accessory.enteredText, setNull: accessory.setsNull, columnIndex: columnIndex
            ) else {
                NSSound.beep()
                return
            }
            self.applyFillColumn(columnIndex: columnIndex, value: value)
        }
    }

    func applyFillColumn(columnIndex: Int, value: PluginCellValue) {
        let targetRows = fillTargetRows()
        guard !targetRows.isEmpty else { return }

        let undoManager = tableView?.window?.undoManager
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(String(localized: "Fill Column"))

        var didEdit = false
        for row in targetRows where recordCellEdit(row: row, columnIndex: columnIndex, newValue: value) != nil {
            didEdit = true
        }

        undoManager?.endUndoGrouping()

        guard didEdit else { return }
        invalidateAllDisplayCaches()
        tableView?.reloadData()
    }

    private func fillTargetRows() -> [Int] {
        let tableRows = tableRowsProvider()
        return Self.fillTargetRows(rowCount: cachedRowCount, isEditable: isEditable) { displayIndex in
            guard let storageIndex = DisplayRowMapping.rowIndex(
                forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows
            ) else { return false }
            return changeManager.isRowDeleted(tableRows.rows[storageIndex].id)
        }
    }

    static func fillTargetRows(rowCount: Int, isEditable: Bool, isRowDeleted: (Int) -> Bool) -> [Int] {
        guard isEditable, rowCount > 0 else { return [] }
        return (0..<rowCount).filter { !isRowDeleted($0) }
    }

    /// The value a fill writes, read for the column the way a typed cell is: an empty fill of a date
    /// is NULL. Nil when the column holds neither the text nor NULL in its place.
    func fillColumnValue(text: String, setNull: Bool, columnIndex: Int) -> PluginCellValue? {
        setNull ? .null : tableRowsProvider().enteredValue(text, forColumn: columnIndex)
    }

    static func fillImpactDescription(rowCount: Int) -> String {
        if rowCount == 1 {
            return String(localized: "This sets 1 loaded row. Review and Save to apply.")
        }
        return String(
            format: String(localized: "This sets %lld loaded rows. Review and Save to apply."),
            Int64(rowCount)
        )
    }
}

@MainActor
private final class FillColumnAccessoryView: NSView {
    private let valueField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    private let nullCheckbox: NSButton?

    init(allowsNull: Bool) {
        nullCheckbox = allowsNull
            ? NSButton(checkboxWithTitle: String(localized: "Set to NULL"), target: nil, action: nil)
            : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: allowsNull ? 50 : 24))

        valueField.usesSingleLineMode = true
        valueField.placeholderString = String(localized: "Value")
        valueField.frame = NSRect(x: 0, y: allowsNull ? 26 : 0, width: 260, height: 24)
        addSubview(valueField)

        guard let nullCheckbox else { return }
        nullCheckbox.frame = NSRect(x: 0, y: 0, width: 260, height: 18)
        nullCheckbox.target = self
        nullCheckbox.action = #selector(nullStateChanged)
        addSubview(nullCheckbox)
    }

    required init?(coder: NSCoder) {
        nullCheckbox = nil
        super.init(coder: coder)
    }

    var enteredText: String { valueField.stringValue }

    var setsNull: Bool { nullCheckbox?.state == .on }

    var firstResponderView: NSView { valueField }

    @objc private func nullStateChanged() {
        valueField.isEnabled = nullCheckbox?.state != .on
    }
}
