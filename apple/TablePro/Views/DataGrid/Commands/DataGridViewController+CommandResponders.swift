//
//  DataGridViewController+CommandResponders.swift
//  TablePro
//

import AppKit

// The focused grid answers the Copy Special and Set Value commands itself, so they work in every window (interaction 8).
extension DataGridViewController: GridCopyCommandResponding {
    func copyCellValue(_ sender: Any?) {
        let commands = gridCommands
        guard let cell = commands.focusCell(commandScope(for: sender)) else { return }
        commands.copyCellValue(cell)
    }

    func copyRowsAsCsv(_ sender: Any?) {
        copyRows(sender, as: .csv)
    }

    func copyRowsAsCsvWithHeaders(_ sender: Any?) {
        copyRows(sender, as: .csvWithHeaders)
    }

    func copyRowsAsMarkdown(_ sender: Any?) {
        copyRows(sender, as: .markdown)
    }

    func copyRowsAsInClause(_ sender: Any?) {
        guard model.configuration.appliesRowCopyFormat else { return }
        gridCommands.copyRowsAsInClause(commandScope(for: sender))
    }

    func copyRowsAsInsertStatements(_ sender: Any?) {
        guard model.configuration.appliesRowCopyFormat else { return }
        gridCommands.copyRowsAsStatements(commandScope(for: sender), update: false)
    }

    func copyRowsAsUpdateStatements(_ sender: Any?) {
        guard model.configuration.appliesRowCopyFormat else { return }
        gridCommands.copyRowsAsStatements(commandScope(for: sender), update: true)
    }

    // Structure grids list definitions, so only Copy Rows, which their owner answers, applies to them.
    private func copyRows(_ sender: Any?, as format: RowCopyFormat) {
        guard format == .rows || model.configuration.appliesRowCopyFormat else { return }
        gridCommands.copyRows(commandScope(for: sender), as: format)
    }
}

extension DataGridViewController: GridRowCopyCommandResponding {
    func copySelectedRows(_ sender: Any?) {
        copyRows(sender, as: .rows)
    }

    func copyRowsWithHeaders(_ sender: Any?) {
        copyRows(sender, as: .rowsWithHeaders)
    }

    func copyRowsAsJson(_ sender: Any?) {
        copyRows(sender, as: .json)
    }
}

extension DataGridViewController: SetValueCommandResponding {
    func setValueEmpty(_ sender: Any?) {
        applySetValue(.empty, sender: sender)
    }

    func setValueNull(_ sender: Any?) {
        applySetValue(.null, sender: sender)
    }

    func setValueDefault(_ sender: Any?) {
        applySetValue(.defaultValue, sender: sender)
    }

    func generateUUIDv4(_ sender: Any?) {
        applySetValue(.uuid(.v4), sender: sender)
    }

    func generateUUIDv7(_ sender: Any?) {
        applySetValue(.uuid(.v7), sender: sender)
    }

    // A window with its own command (a whole data file) runs it instead; the sheet otherwise names how many cells it sets.
    func setCellsToValue(_ sender: Any?) {
        let commands = gridCommands
        let targets = commands.cells(commandScope(for: sender))
        guard !targets.isEmpty, commitCellEditing() else { return }
        if model.actions?.gridSetCellsToValue(targets.map { (rowID: $0.rowID, column: $0.column) }) == true { return }
        let cells = targets.filter { commands.typingCanEdit($0) }
        guard !cells.isEmpty, let window = view.window else { return }
        let records = DataGridCellRecords(cells, in: model)
        SetCellsToValuePrompt.present(
            informative: DataGridCommands.setCellsToValueImpact(cells: cells.count, targets: targets.count),
            window: window
        ) { [weak self] text in
            guard let self, let text else { return }
            guard let current = records.current(in: self.model) else {
                NSSound.beep()
                return
            }
            let commands = self.gridCommands
            commands.applyEnteredText(text, to: current.filter { commands.typingCanEdit($0) })
        }
    }

    private func applySetValue(_ command: SetValueCommand, sender: Any?) {
        let commands = gridCommands
        let cells = commands.cells(commandScope(for: sender))
        guard !cells.isEmpty, commitCellEditing() else { return }
        commands.applySetValue(command, to: cells)
    }

    static func setValueCommand(for action: Selector) -> SetValueCommand? {
        switch action {
        case #selector(SetValueCommandResponding.setValueEmpty(_:)): SetValueCommand.empty
        case #selector(SetValueCommandResponding.setValueNull(_:)): SetValueCommand.null
        case #selector(SetValueCommandResponding.setValueDefault(_:)): SetValueCommand.defaultValue
        case #selector(SetValueCommandResponding.generateUUIDv4(_:)): SetValueCommand.uuid(.v4)
        case #selector(SetValueCommandResponding.generateUUIDv7(_:)): SetValueCommand.uuid(.v7)
        default: nil
        }
    }
}

// The focused grid opens its own find bar, so Find reaches a query result, a Structure list or any other grid
// before the window hands the command to its editor.
extension DataGridViewController {
    @objc func performFind(_ sender: Any?) {
        model.showFind()
    }

    @objc func performFindAndReplace(_ sender: Any?) {
        model.showFind(replace: true)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        model.useSelectionForFind()
    }

    @objc func findNext(_ sender: Any?) {
        model.findNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        model.findPrevious()
    }

    func validateFindCommand(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(performFind(_:)), #selector(performFindAndReplace(_:)):
            true
        case #selector(useSelectionForFind(_:)):
            model.selection.activeCell != nil
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            model.find.isVisible && model.hasFindTerm
        default:
            nil
        }
    }
}

extension DataGridViewController {
    // A key column takes no fill; the sheet says how many loaded rows it sets.
    func presentFillColumn(for column: DataGridColumn) {
        let commands = gridCommands
        guard commands.canFillColumn(column), let window = view.window, commitCellEditing() else { return }
        let rowCount = commands.fillTargetRowIDs().count
        guard rowCount > 0 else { return }
        let accessory = FillColumnAccessoryView(choices: commands.fillColumnChoices(for: column))
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Fill column \"%@\""), column.name)
        alert.informativeText = DataGridCommands.fillImpactDescription(rowCount: rowCount)
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Fill"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = accessory.firstResponderView
        let columnID = column.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let current = self.model.columns.column(id: columnID) else { return }
            let commands = self.gridCommands
            guard let content = commands.fillColumnContent(
                choice: accessory.choice,
                text: accessory.enteredText,
                column: current
            ) else {
                NSSound.beep()
                return
            }
            commands.applyFillColumn(current, content: content)
        }
    }
}
