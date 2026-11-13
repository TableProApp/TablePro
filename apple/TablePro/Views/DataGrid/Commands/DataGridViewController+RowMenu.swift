//
//  DataGridViewController+RowMenu.swift
//  TablePro
//

import AppKit
import TableProPluginKit

struct DataGridSetValueChoice {
    let context: DataGridMenuContext
    let command: SetValueCommand
}

extension DataGridViewController {
    // Unavailable items are left out; Copy and Paste stay, dimmed when they do not apply (HIG context menus).
    func buildRowMenu(row: Int, displayColumn: Int?) -> NSMenu? {
        guard row >= 0, row < model.rowCount, let rowID = model.rowID(at: row) else { return nil }
        let commands = gridCommands
        let scope = DataGridCommandScope.contextMenu(
            selection: model.selection,
            row: row,
            displayColumn: displayColumn,
            columnCount: model.columns.count
        )
        let context = DataGridMenuContext(scope, model: model)

        if commands.isRowDeleted(rowID), commands.offers(.undoDelete) {
            return Self.menu(groups: [[menuItem(String(localized: "Undo Delete"), #selector(undoDeleteFromMenu(_:)), context)]])
        }

        let cell = displayColumn == nil ? nil : commands.focusCell(scope)
        var groups: [[NSMenuItem]] = []
        groups.append(copyItems(scope: scope, context: context, cell: cell))
        groups.append(resultItems(context: context, cell: cell))
        if let cell {
            groups.append(foreignKeyItems(cell: cell, context: context))
            groups.append(valueItems(scope: scope, context: context, cell: cell))
        }
        groups.append(exportItems(context: context))
        groups.append(model.actions?.gridRowMenuItems(for: commands.rowIDs(scope), clickedRow: rowID) ?? [])
        groups.append(rowItems(context: context))
        return Self.menu(groups: groups)
    }

    static func menu(groups: [[NSMenuItem]]) -> NSMenu? {
        let filled = groups.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, group) in filled.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            group.forEach(menu.addItem)
        }
        return menu
    }

    func menuItem(_ title: String, _ action: Selector?, _ represented: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    // MARK: - Groups

    private func copyItems(scope: DataGridCommandScope, context: DataGridMenuContext, cell: DataGridCommandCell?) -> [NSMenuItem] {
        var items = [menuItem(String(localized: "Copy"), #selector(copy(_:)), context)]
        if cell != nil {
            items.append(menuItem(String(localized: "Copy Cell Value"), #selector(GridCopyCommandResponding.copyCellValue(_:)), context))
        }
        if model.configuration.appliesRowCopyFormat {
            items.append(copyAsItem(scope: scope, context: context, includesInClause: cell != nil))
        }
        if context.isCurrentSelection, let numbers = selectionSummaryTracker.currentSummary?.numbers {
            for figure in [SelectionSummaryFigures.Figure.sum, .average] {
                guard let text = SelectionSummaryFigures.copyText(figure, of: numbers) else { continue }
                items.append(menuItem(figure.copyTitle, #selector(copySummaryFigureFromMenu(_:)), text))
            }
        }
        if model.configuration.isEditable {
            items.append(menuItem(String(localized: "Paste"), #selector(paste(_:)), context))
        }
        return items
    }

    private func copyAsItem(scope: DataGridCommandScope, context: DataGridMenuContext, includesInClause: Bool) -> NSMenuItem {
        let commands = gridCommands
        let submenu = NSMenu()
        let formats: [(String, Selector)] = [
            (String(localized: "Rows"), #selector(GridRowCopyCommandResponding.copySelectedRows(_:))),
            (String(localized: "With Headers"), #selector(GridRowCopyCommandResponding.copyRowsWithHeaders(_:))),
            (String(localized: "JSON"), #selector(GridRowCopyCommandResponding.copyRowsAsJson(_:))),
            (String(localized: "CSV"), #selector(GridCopyCommandResponding.copyRowsAsCsv(_:))),
            (String(localized: "CSV with Headers"), #selector(GridCopyCommandResponding.copyRowsAsCsvWithHeaders(_:))),
            (String(localized: "Markdown"), #selector(GridCopyCommandResponding.copyRowsAsMarkdown(_:))),
        ]
        for (title, action) in formats {
            submenu.addItem(menuItem(title, action, context))
        }
        if includesInClause, commands.inClauseColumn(scope) != nil {
            submenu.addItem(menuItem(String(localized: "IN Clause"), #selector(GridCopyCommandResponding.copyRowsAsInClause(_:)), context))
        }
        if commands.canCopyAsInsert(scope) {
            submenu.addItem(.separator())
            submenu.addItem(menuItem(
                String(localized: "INSERT Statement(s)"),
                #selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:)),
                context
            ))
            if commands.canCopyAsUpdate(scope) {
                submenu.addItem(menuItem(
                    String(localized: "UPDATE Statement(s)"),
                    #selector(GridCopyCommandResponding.copyRowsAsUpdateStatements(_:)),
                    context
                ))
            }
        }
        let item = NSMenuItem(title: String(localized: "Copy as"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func resultItems(context: DataGridMenuContext, cell: DataGridCommandCell?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if gridCommands.offers(.showRowsAsJSON) {
            items.append(menuItem(String(localized: "Show Row as JSON"), #selector(showRowsAsJSONFromMenu(_:)), context))
        }
        if let cell {
            items += model.actions?.gridCellMenuItems(for: cell.rowID, column: cell.column) ?? []
        }
        return items
    }

    // Choosing a value is offered on an empty cell too, where it is needed most; previewing and following need a value.
    private func foreignKeyItems(cell: DataGridCommandCell, context: DataGridMenuContext) -> [NSMenuItem] {
        let commands = gridCommands
        let rows = model.rows
        guard let info = rows.columnForeignKeys[cell.column.name], let row = rows.row(withID: cell.rowID),
              cell.column.dataIndex < row.values.count else { return [] }
        let hasValue = row.values[cell.column.dataIndex].asText?.isEmpty == false
        let canChoose = commands.typingCanEdit(cell)
            && !ForeignKeyConstraintSpan.isMultiColumn(info, among: rows.columnForeignKeys)
        var items: [NSMenuItem] = []
        if canChoose {
            items.append(menuItem(
                String(format: String(localized: "Choose %@ Row…"), info.referencedTable),
                #selector(chooseForeignKeyRowFromMenu(_:)),
                context
            ))
        }
        guard hasValue, commands.offers(.navigateForeignKey) else { return items }
        items.append(menuItem(String(localized: "Preview Referenced Row"), #selector(previewForeignKeyFromMenu(_:)), context))
        items.append(menuItem(
            String(format: String(localized: "Open %@"), info.referencedTable),
            #selector(openForeignKeyFromMenu(_:)),
            context
        ))
        items.append(menuItem(
            String(format: String(localized: "Open %@ in New Tab"), info.referencedTable),
            #selector(openForeignKeyInNewTabFromMenu(_:)),
            context
        ))
        return items
    }

    private func valueItems(scope: DataGridCommandScope, context: DataGridMenuContext, cell: DataGridCommandCell) -> [NSMenuItem] {
        guard model.configuration.isEditable else { return [] }
        let commands = gridCommands
        let targets = commands.cells(scope)
        let submenu = NSMenu()
        var lastGroup: Int?
        for command in commands.setValueCommands(for: targets) {
            let group = DataGridCommands.menuGroup(command)
            if let lastGroup, lastGroup != group {
                submenu.addItem(.separator())
            }
            lastGroup = group
            submenu.addItem(menuItem(
                SetValueOptions.title(for: command),
                #selector(applySetValueFromMenu(_:)),
                DataGridSetValueChoice(context: context, command: command)
            ))
        }
        if commands.isSetCellsToValueOffered(for: targets) {
            if !submenu.items.isEmpty {
                submenu.addItem(.separator())
            }
            submenu.addItem(menuItem(
                String(localized: "Set Cells to Value…"),
                #selector(SetValueCommandResponding.setCellsToValue(_:)),
                context
            ))
        }
        var items: [NSMenuItem] = []
        if !submenu.items.isEmpty {
            let setValue = NSMenuItem(title: String(localized: "Set Value"), action: nil, keyEquivalent: "")
            setValue.submenu = submenu
            items.append(setValue)
        }
        if commands.canRemoveField(cell) {
            items.append(menuItem(String(localized: "Remove Field"), #selector(removeFieldFromMenu(_:)), context))
        }
        return items
    }

    private func exportItems(context: DataGridMenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if gridCommands.offers(.exportResults) {
            items.append(menuItem(String(localized: "Export Results…"), #selector(exportResultsFromMenu(_:)), context))
        }
        if gridCommands.offers(.clearResults) {
            items.append(menuItem(String(localized: "Clear Results"), #selector(clearResultsFromMenu(_:)), context))
        }
        return items
    }

    private func rowItems(context: DataGridMenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if gridCommands.offers(.duplicateRows) {
            items.append(menuItem(String(localized: "Duplicate"), #selector(duplicateRowsFromMenu(_:)), context))
        }
        if gridCommands.offers(.deleteRows) {
            items.append(menuItem(String(localized: "Delete"), #selector(delete(_:)), context))
        }
        return items
    }

    // MARK: - Actions

    private static let rowMenuActions: Set<Selector> = [
        #selector(DataGridViewController.undoDeleteFromMenu(_:)),
        #selector(DataGridViewController.showRowsAsJSONFromMenu(_:)),
        #selector(DataGridViewController.chooseForeignKeyRowFromMenu(_:)),
        #selector(DataGridViewController.previewForeignKeyFromMenu(_:)),
        #selector(DataGridViewController.openForeignKeyFromMenu(_:)),
        #selector(DataGridViewController.openForeignKeyInNewTabFromMenu(_:)),
        #selector(DataGridViewController.applySetValueFromMenu(_:)),
        #selector(DataGridViewController.removeFieldFromMenu(_:)),
        #selector(DataGridViewController.exportResultsFromMenu(_:)),
        #selector(DataGridViewController.clearResultsFromMenu(_:)),
        #selector(DataGridViewController.duplicateRowsFromMenu(_:)),
        #selector(DataGridViewController.copySummaryFigureFromMenu(_:)),
    ]

    static let contextMenuActions = rowMenuActions.union(headerMenuActions)

    @objc func undoDeleteFromMenu(_ sender: Any?) {
        let ids = gridCommands.deletedRowIDs(commandScope(for: sender))
        guard !ids.isEmpty else { return }
        model.actions?.gridUndoDelete(ids)
    }

    @objc func showRowsAsJSONFromMenu(_ sender: Any?) {
        model.actions?.gridShowRowsAsJSON(gridCommands.rowIDs(commandScope(for: sender)))
    }

    @objc func duplicateRowsFromMenu(_ sender: Any?) {
        let ids = gridCommands.rowIDs(commandScope(for: sender))
        guard !ids.isEmpty, commitCellEditing() else { return }
        model.actions?.gridDuplicateRows(ids)
    }

    @objc func exportResultsFromMenu(_ sender: Any?) {
        model.actions?.gridExportResults()
    }

    @objc func clearResultsFromMenu(_ sender: Any?) {
        model.actions?.gridClearResults()
    }

    @objc func copySummaryFigureFromMenu(_ sender: Any?) {
        guard let text = (sender as? NSMenuItem)?.representedObject as? String else { return }
        ClipboardService.shared.writeText(text)
    }

    @objc func applySetValueFromMenu(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? DataGridSetValueChoice,
              commitCellEditing() else { return }
        let commands = gridCommands
        commands.applySetValue(choice.command, to: commands.cells(choice.context.scope(in: model)))
    }

    @objc func removeFieldFromMenu(_ sender: Any?) {
        let commands = gridCommands
        guard let cell = commands.focusCell(commandScope(for: sender)), commitCellEditing() else { return }
        commands.removeField(cell)
    }

    @objc func chooseForeignKeyRowFromMenu(_ sender: Any?) {
        guard let focus = commandScope(for: sender).focus else { return }
        chooseForeignKeyRow(at: focus)
    }

    // The preview follows the active cell, so the clicked cell becomes it first.
    @objc func previewForeignKeyFromMenu(_ sender: Any?) {
        guard let focus = commandScope(for: sender).focus else { return }
        if model.selection.activeCell != focus || model.selection.hasMultipleCells {
            model.selectCell(focus)
            mirrorSelection()
        }
        toggleForeignKeyPreview()
    }

    @objc func openForeignKeyFromMenu(_ sender: Any?) {
        openForeignKey(from: sender, intent: .follow)
    }

    @objc func openForeignKeyInNewTabFromMenu(_ sender: Any?) {
        openForeignKey(from: sender, intent: .newTab)
    }

    private func openForeignKey(from sender: Any?, intent: ReferenceOpenIntent) {
        guard let cell = gridCommands.focusCell(commandScope(for: sender)) else { return }
        let rows = model.rows
        guard let info = rows.columnForeignKeys[cell.column.name],
              let value = rows.row(withID: cell.rowID)?[cell.column.dataIndex].asText, !value.isEmpty else { return }
        model.actions?.gridNavigateForeignKey(value: value, info: info, intent: intent)
    }
}
