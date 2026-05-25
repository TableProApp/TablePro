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

        let rowCount = Self.fillTargetRows(
            rowCount: cachedRowCount,
            isEditable: isEditable,
            isRowDeleted: changeManager.isRowDeleted
        ).count
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

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyFillColumn(columnIndex: columnIndex, value: accessory.resolvedValue)
        }

        DispatchQueue.main.async {
            alert.window.makeFirstResponder(accessory.firstResponderView)
        }
    }

    func applyFillColumn(columnIndex: Int, value: PluginCellValue) {
        let targetRows = Self.fillTargetRows(
            rowCount: cachedRowCount,
            isEditable: isEditable,
            isRowDeleted: changeManager.isRowDeleted
        )
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

    static func fillTargetRows(rowCount: Int, isEditable: Bool, isRowDeleted: (Int) -> Bool) -> [Int] {
        guard isEditable, rowCount > 0 else { return [] }
        return (0..<rowCount).filter { !isRowDeleted($0) }
    }

    static func fillColumnValue(text: String, setNull: Bool) -> PluginCellValue {
        setNull ? .null : .text(text)
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

    var resolvedValue: PluginCellValue {
        TableViewCoordinator.fillColumnValue(
            text: valueField.stringValue,
            setNull: nullCheckbox?.state == .on
        )
    }

    var firstResponderView: NSView { valueField }

    @objc private func nullStateChanged() {
        valueField.isEnabled = nullCheckbox?.state != .on
    }
}
