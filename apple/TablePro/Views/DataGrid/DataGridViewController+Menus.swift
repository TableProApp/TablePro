//
//  DataGridViewController+Menus.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridMenuState {
    let loader = DataGridValueLoader()
    var valueFilterPopover: NSPopover?
}

extension DataGridViewController {
    var gridCommands: DataGridCommands {
        DataGridCommands(model: model, loader: menuState.loader)
    }

    // A context menu item carries the scope it was built over; the menu bar acts on the selection.
    func commandScope(for sender: Any?) -> DataGridCommandScope {
        if let item = sender as? NSMenuItem {
            if let context = item.representedObject as? DataGridMenuContext {
                return context.scope(in: model)
            }
            if let choice = item.representedObject as? DataGridSetValueChoice {
                return choice.context.scope(in: model)
            }
        }
        return .current(model.selection)
    }

    // Context menu for a row; displayColumn is nil over the row numbers. Built from clickedRow and clickedColumn.
    func rowMenu(forRow row: Int, displayColumn: Int?, in pane: DataGridPane.Kind) -> NSMenu? {
        buildRowMenu(row: row, displayColumn: displayColumn)
    }

    func headerMenu(for column: DataGridColumn) -> NSMenu? {
        buildHeaderMenu(for: column)
    }

    func emptySpaceMenu() -> NSMenu? {
        model.actions?.gridEmptySpaceMenu()
    }

    // Delete and Forward Delete mark every row the selection touches; a grid that deletes nothing beeps.
    func performDeleteCommand() {
        let scope = DataGridCommandScope.current(model.selection)
        guard gridCommands.canDelete(scope) else {
            NSSound.beep()
            return
        }
        guard commitCellEditing() else { return }
        gridCommands.deleteRows(scope)
    }

    // A double-click below the last row.
    func handleDoubleClickBelowRows() {
        guard model.configuration.isEditable, gridCommands.offers(.addRow), commitCellEditing() else { return }
        model.actions?.gridAddRow()
    }

    func performSelectAll(_ sender: Any?) {
        let context = selectionContext
        guard !context.isEmpty else { return }
        model.setSelection(GridSelectionReducer.selectAll(model.selection, in: context))
        mirrorSelection()
    }

    // MARK: - Standard edit actions

    @objc func copy(_ sender: Any?) {
        gridCommands.copy(commandScope(for: sender))
    }

    // The context menu's Paste and Command-V take this one path (interaction 4).
    @objc func paste(_ sender: Any?) {
        let scope = commandScope(for: sender)
        guard commitCellEditing() else { return }
        gridCommands.paste(scope)
    }

    @objc func delete(_ sender: Any?) {
        let scope = commandScope(for: sender)
        guard gridCommands.canDelete(scope), commitCellEditing() else { return }
        gridCommands.deleteRows(scope)
    }

    // MARK: - Validation

    // Validation for the grid's own commands; nil leaves an item to its responder's default.
    func validateGridCommand(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action else { return nil }
        let commands = gridCommands
        let scope = commandScope(for: item)
        let appliesRowFormat = model.configuration.appliesRowCopyFormat
        switch action {
        case #selector(copy(_:)), #selector(GridRowCopyCommandResponding.copySelectedRows(_:)):
            return commands.canCopy(scope)
        case #selector(paste(_:)):
            return commands.canPaste(scope)
        case #selector(delete(_:)):
            return commands.canDelete(scope)
        case #selector(NSTableView.selectAll(_:)):
            return !selectionContext.isEmpty
        case #selector(GridCopyCommandResponding.copyCellValue(_:)):
            return commands.focusCell(scope) != nil
        case #selector(GridRowCopyCommandResponding.copyRowsWithHeaders(_:)),
             #selector(GridRowCopyCommandResponding.copyRowsAsJson(_:)),
             #selector(GridCopyCommandResponding.copyRowsAsCsv(_:)),
             #selector(GridCopyCommandResponding.copyRowsAsCsvWithHeaders(_:)),
             #selector(GridCopyCommandResponding.copyRowsAsMarkdown(_:)):
            return appliesRowFormat && commands.canCopy(scope)
        case #selector(GridCopyCommandResponding.copyRowsAsInClause(_:)):
            return appliesRowFormat && commands.canCopy(scope) && commands.inClauseColumn(scope) != nil
        case #selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:)):
            return appliesRowFormat && commands.canCopyAsInsert(scope)
        case #selector(GridCopyCommandResponding.copyRowsAsUpdateStatements(_:)):
            return appliesRowFormat && commands.canCopyAsUpdate(scope)
        case #selector(SetValueCommandResponding.setCellsToValue(_:)):
            return commands.isSetCellsToValueOffered(for: commands.cells(scope))
        default:
            if let command = Self.setValueCommand(for: action) {
                return commands.isSetValueOffered(command, for: commands.cells(scope))
            }
            // The menus build these items only where they apply.
            return Self.contextMenuActions.contains(action) ? true : nil
        }
    }
}

extension DataGridViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateEditingCommand(menuItem) ?? validateFindCommand(menuItem) ?? validateGridCommand(menuItem) ?? true
    }
}
