//
//  EditMenuBuilder.swift
//  TablePro
//

import AppKit

/// Start Dictation and Emoji & Symbols are omitted on purpose: the system appends
/// them to the Edit menu itself.
@MainActor
enum EditMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "Edit"), items: [
            MenuItemFactory.item(
                String(localized: "Undo"),
                action: Selector(("undo:")),
                shortcut: .undo,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Redo"),
                action: Selector(("redo:")),
                shortcut: .redo,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Cut"),
                action: #selector(NSText.cut(_:)),
                shortcut: .cut,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Copy"),
                action: #selector(NSText.copy(_:)),
                shortcut: .copy,
                keyboard: keyboard
            ),
            copySpecialSubmenu(keyboard: keyboard),
            MenuItemFactory.item(
                String(localized: "Paste"),
                action: #selector(NSText.paste(_:)),
                shortcut: .paste,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Delete"),
                action: #selector(NSText.delete(_:)),
                shortcut: .delete,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Select All"),
                action: #selector(NSText.selectAll(_:)),
                shortcut: .selectAll,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Clear Selection"),
                action: #selector(MainSplitViewController.clearSelection(_:)),
                shortcut: .clearSelection,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            findSubmenu(keyboard: keyboard),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Add Row"),
                action: #selector(MainSplitViewController.addRow(_:)),
                shortcut: .addRow,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Duplicate Row"),
                action: #selector(MainSplitViewController.duplicateRow(_:)),
                shortcut: .duplicateRow,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            /// Not Undo, and deliberately not next to it. Undo takes back an edit the user has not
            /// saved yet and costs nothing; this one writes to the database, needs review and can
            /// be refused. The HIG scopes Undo to the current document's content, and every Apple
            /// reversal of something already committed is a separate, named command.
            MenuItemFactory.item(
                String(localized: "Restore Previous Values…"),
                action: #selector(MainSplitViewController.restorePreviousValues(_:)),
                shortcut: .restorePreviousValues,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            tabularEditingSubmenu(keyboard: keyboard)
        ])
    }

    private static func copySpecialSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Copy Special"), items: [
            MenuItemFactory.item(
                String(localized: "Copy Rows"),
                action: #selector(MainSplitViewController.copySelectedRows(_:)),
                shortcut: .copyRowsExplicit,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Copy with Headers"),
                action: #selector(MainSplitViewController.copyRowsWithHeaders(_:)),
                shortcut: .copyWithHeaders,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Copy as JSON"),
                action: #selector(MainSplitViewController.copyRowsAsJson(_:)),
                shortcut: .copyAsJson,
                keyboard: keyboard
            )
        ])
    }

    private static func findSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Find"), items: [
            MenuItemFactory.item(
                String(localized: "Find…"),
                action: #selector(MainSplitViewController.performFind(_:)),
                shortcut: .find,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Find and Replace…"),
                action: #selector(MainSplitViewController.performFindAndReplace(_:)),
                shortcut: .findAndReplace,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Find Next"),
                action: #selector(MainSplitViewController.findNext(_:)),
                shortcut: .findNext,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Find Previous"),
                action: #selector(MainSplitViewController.findPrevious(_:)),
                shortcut: .findPrevious,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Use Selection for Find"),
                action: #selector(MainSplitViewController.useSelectionForFind(_:)),
                shortcut: .useSelectionForFind,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Jump to Column…"),
                action: #selector(MainSplitViewController.jumpToColumn(_:)),
                shortcut: .jumpToColumn,
                keyboard: keyboard
            )
        ])
    }

    private static func tabularEditingSubmenu(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.submenu(String(localized: "Data"), items: [
            MenuItemFactory.item(
                String(localized: "Insert Row Above"),
                action: #selector(DataFileSplitViewController.dataFileInsertRowAbove(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Insert Row Below"),
                action: #selector(DataFileSplitViewController.dataFileInsertRowBelow(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Delete Rows"),
                action: #selector(DataFileSplitViewController.dataFileDeleteSelectedRows(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Add Column…"),
                action: #selector(DataFileSplitViewController.dataFileAddColumn(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Insert Column Left"),
                action: #selector(DataFileSplitViewController.dataFileInsertColumnLeft(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Insert Column Right"),
                action: #selector(DataFileSplitViewController.dataFileInsertColumnRight(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Rename Column…"),
                action: #selector(DataFileSplitViewController.dataFileRenameColumn(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Split Column…"),
                action: #selector(DataFileSplitViewController.dataFileSplitColumn(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Merge Columns…"),
                action: #selector(DataFileSplitViewController.dataFileMergeColumns(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Delete Column"),
                action: #selector(DataFileSplitViewController.dataFileDeleteColumn(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Fill Down"),
                action: #selector(DataFileSplitViewController.dataFileFillDown(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Set Cells to Value…"),
                action: #selector(DataFileSplitViewController.dataFileSetCellsToValue(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Trim Whitespace"),
                action: #selector(DataFileSplitViewController.dataFileTrimWhitespace(_:))
            ),
            changeCaseSubmenu(),
            MenuItemFactory.item(
                String(localized: "Replace in Column…"),
                action: #selector(DataFileSplitViewController.dataFileReplaceInColumn(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Remove Duplicate Rows…"),
                action: #selector(DataFileSplitViewController.dataFileRemoveDuplicates(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Column Statistics…"),
                action: #selector(DataFileSplitViewController.dataFileShowStatistics(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Search All Columns"),
                action: #selector(DataFileSplitViewController.dataFileSearchAllColumns(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Switch First Row Between Header and Data"),
                action: #selector(DataFileSplitViewController.dataFileToggleHeaderRow(_:)),
                shortcut: .toggleHeaderRow,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "File Properties…"),
                action: #selector(DataFileSplitViewController.dataFileShowProperties(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Import into Table…"),
                action: #selector(DataFileSplitViewController.dataFileImportIntoTable(_:))
            )
        ])
    }

    private static func changeCaseSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Change Case"), action: nil, keyEquivalent: "")
        item.submenu = DataFileColumnMenuBuilder.caseSubmenu(for: nil)
        return item
    }
}
