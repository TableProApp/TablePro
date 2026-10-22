//
//  DataGridView+FillColumn.swift
//  TablePro
//

import AppKit
import TableProPluginKit

enum FillColumnChoice: Equatable {
    case value
    case null
    case uuid(UUIDVersion)
}

/// A UUID is drawn for each row.
enum FillColumnContent: Equatable {
    case value(PluginCellValue, isExpression: Bool = false)
    case uuid(UUIDVersion, UUIDCellForm)
}

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
        let accessory = FillColumnAccessoryView(choices: fillColumnChoices(columnIndex: columnIndex))

        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Fill column \"%@\""), columnName)
        alert.informativeText = Self.fillImpactDescription(rowCount: rowCount)
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Fill"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        alert.window.initialFirstResponder = accessory.firstResponderView

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let content = self.fillColumnContent(
                choice: accessory.choice, text: accessory.enteredText, columnIndex: columnIndex
            ) else {
                NSSound.beep()
                return
            }
            self.applyFillColumn(columnIndex: columnIndex, content: content)
        }
    }

    func fillColumnChoices(columnIndex: Int) -> [FillColumnChoice] {
        let tableRows = tableRowsProvider()
        guard tableRows.columns.indices.contains(columnIndex) else { return [.value] }
        var choices: [FillColumnChoice] = [.value]
        if tableRows.columnNullable[tableRows.columns[columnIndex]] ?? true {
            choices.append(.null)
        }
        if fillUUIDForm(columnIndex: columnIndex, in: tableRows) != nil {
            choices += [.uuid(.v4), .uuid(.v7)]
        }
        return choices
    }

    func applyFillColumn(columnIndex: Int, content: FillColumnContent) {
        let targetRows = fillTargetRows()
        guard !targetRows.isEmpty else { return }
        let retry: @MainActor () -> Void = { [weak self] in
            self?.applyFillColumn(columnIndex: columnIndex, content: content)
        }
        guard unloadedValuesAreLoaded(displayRows: targetRows, columns: IndexSet(integer: columnIndex), retry: retry)
        else { return }

        let undoManager = tableView?.window?.undoManager
        undoManager?.beginUndoGrouping()

        var didEdit = false
        for row in targetRows {
            let staged = Self.fillValue(content)
            if recordCellEdit(
                row: row, columnIndex: columnIndex, newValue: staged.value, isExpression: staged.isExpression
            ) != nil {
                didEdit = true
            }
        }

        // After the loop: each cell's own step names the open group "Edit Cell".
        undoManager?.setActionName(String(localized: "Fill Column"))
        undoManager?.endUndoGrouping()

        guard didEdit else { return }
        invalidateAllDisplayCaches()
        tableView?.reloadData()
    }

    private static func fillValue(_ content: FillColumnContent) -> (value: PluginCellValue, isExpression: Bool) {
        switch content {
        case .value(let value, let isExpression):
            return (value: value, isExpression: isExpression)
        case .uuid(let version, let form):
            return (value: form.value(for: UUIDValueGenerator.shared.make(version)), isExpression: false)
        }
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

    /// The value is read the way a typed cell is: an empty date is NULL, a function the engine runs there is SQL. Nil
    /// when the column holds neither the text nor NULL in its place.
    func fillColumnContent(choice: FillColumnChoice, text: String, columnIndex: Int) -> FillColumnContent? {
        switch choice {
        case .value:
            return enteredCell(text, columnIndex: columnIndex).map {
                FillColumnContent.value($0.value, isExpression: $0.isExpression)
            }
        case .null:
            return .value(.null)
        case .uuid(let version):
            return fillUUIDForm(columnIndex: columnIndex, in: tableRowsProvider()).map {
                FillColumnContent.uuid(version, $0)
            }
        }
    }

    private func fillUUIDForm(columnIndex: Int, in tableRows: TableRows) -> UUIDCellForm? {
        setValueContext(forColumn: columnIndex, rowIsInserted: false, in: tableRows)
            .flatMap { SetValueOptions.uuidForm(for: $0) }
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

/// Value, NULL and the UUIDs are radio buttons with one superview and one action, which AppKit groups by itself.
@MainActor
private final class FillColumnAccessoryView: NSView {
    private static let width: CGFloat = 260
    private static let valueRowHeight: CGFloat = 24
    private static let choiceRowHeight: CGFloat = 22

    private let valueField = NSTextField(frame: .zero)
    private var radios: [(choice: FillColumnChoice, button: NSButton)] = []

    init(choices: [FillColumnChoice]) {
        let others = choices.filter { $0 != .value }
        let height = Self.valueRowHeight + CGFloat(others.count) * Self.choiceRowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        valueField.usesSingleLineMode = true
        valueField.placeholderString = String(localized: "Value")
        addSubview(valueField)

        let valueRowY = height - Self.valueRowHeight
        guard !others.isEmpty else {
            valueField.frame = NSRect(x: 0, y: valueRowY, width: Self.width, height: Self.valueRowHeight)
            return
        }

        let valueRadio = addRadio(.value, at: valueRowY, rowHeight: Self.valueRowHeight)
        valueRadio.state = .on
        let fieldX = valueRadio.frame.maxX + 6
        valueField.frame = NSRect(
            x: fieldX, y: valueRowY, width: Self.width - fieldX, height: Self.valueRowHeight
        )
        for (index, choice) in others.enumerated() {
            addRadio(choice, at: valueRowY - CGFloat(index + 1) * Self.choiceRowHeight, rowHeight: Self.choiceRowHeight)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    var enteredText: String { valueField.stringValue }

    var choice: FillColumnChoice {
        radios.first { $0.button.state == .on }?.choice ?? .value
    }

    var firstResponderView: NSView { valueField }

    @discardableResult
    private func addRadio(_ choice: FillColumnChoice, at rowY: CGFloat, rowHeight: CGFloat) -> NSButton {
        let button = NSButton(radioButtonWithTitle: Self.title(for: choice), target: self, action: #selector(choiceChanged))
        button.sizeToFit()
        button.frame.origin = NSPoint(x: 0, y: rowY + (rowHeight - button.frame.height) / 2)
        addSubview(button)
        radios.append((choice, button))
        return button
    }

    private static func title(for choice: FillColumnChoice) -> String {
        switch choice {
        case .value: String(localized: "Value")
        case .null: String(localized: "NULL")
        case .uuid(.v4): String(localized: "New UUID")
        case .uuid(.v7): String(localized: "New UUIDv7")
        }
    }

    @objc private func choiceChanged() {
        valueField.isEnabled = choice == .value
    }
}
