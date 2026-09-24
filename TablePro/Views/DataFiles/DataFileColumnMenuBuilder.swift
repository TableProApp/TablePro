//
//  DataFileColumnMenuBuilder.swift
//  TablePro
//

import AppKit
import TableProTabular

@MainActor
enum DataFileColumnMenuBuilder {
    static func items(
        for column: TabularColumnID,
        controller: DataFileController,
        selectedColumns: [TabularColumnID]
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            item(String(localized: "Column Statistics…"), #selector(DataFileSplitViewController.dataFileShowStatistics(_:)), column)
        ]
        guard controller.isEditable else { return items }
        let deleteCount = selectedColumns.contains(column) ? max(1, selectedColumns.count) : 1
        let index = controller.columnNames.index(of: column) ?? 0
        let changeType = NSMenuItem(title: String(localized: "Change Type"), action: nil, keyEquivalent: "")
        changeType.submenu = kindSubmenu(for: column, current: controller.kind(of: column))
        let changeCase = NSMenuItem(title: String(localized: "Change Case"), action: nil, keyEquivalent: "")
        changeCase.submenu = caseSubmenu(for: column)
        items.append(contentsOf: [
            .separator(),
            item(String(localized: "Rename Column…"), #selector(DataFileSplitViewController.dataFileRenameColumn(_:)), column),
            item(String(localized: "Insert Column Left"), #selector(DataFileSplitViewController.dataFileInsertColumnLeft(_:)), column),
            item(String(localized: "Insert Column Right"), #selector(DataFileSplitViewController.dataFileInsertColumnRight(_:)), column),
            item(String(localized: "Split Column…"), #selector(DataFileSplitViewController.dataFileSplitColumn(_:)), column)
        ])
        if index + 1 < controller.columnNames.count {
            items.append(item(String(localized: "Merge Columns…"), #selector(DataFileSplitViewController.dataFileMergeColumns(_:)), column))
        }
        items.append(contentsOf: [
            changeType,
            .separator(),
            item(String(localized: "Set Cells to Value…"), #selector(DataFileSplitViewController.dataFileSetCellsToValue(_:)), column),
            item(String(localized: "Trim Whitespace"), #selector(DataFileSplitViewController.dataFileTrimWhitespace(_:)), column),
            changeCase,
            item(String(localized: "Replace in Column…"), #selector(DataFileSplitViewController.dataFileReplaceInColumn(_:)), column),
            .separator(),
            item(
                deleteCount > 1 ? String(localized: "Delete Columns") : String(localized: "Delete Column"),
                #selector(DataFileSplitViewController.dataFileDeleteColumn(_:)),
                column
            )
        ])
        return items
    }

    static func rowItems(forPageRow row: Int) -> [NSMenuItem] {
        [
            rowItem(String(localized: "Insert Row Above"), #selector(DataFileSplitViewController.dataFileInsertRowAbove(_:)), row),
            rowItem(String(localized: "Insert Row Below"), #selector(DataFileSplitViewController.dataFileInsertRowBelow(_:)), row)
        ]
    }

    static func kindSubmenu(for column: TabularColumnID, current: TabularInferredKind) -> NSMenu {
        let submenu = NSMenu()
        for kind in TabularInferredKind.allCases {
            let entry = NSMenuItem(title: label(for: kind), action: #selector(DataFileSplitViewController.dataFileSetColumnKind(_:)), keyEquivalent: "")
            entry.representedObject = DataFileKindAssignment(column: column, kind: kind)
            entry.state = kind == current ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let reset = NSMenuItem(
            title: String(localized: "Reset to Inferred"),
            action: #selector(DataFileSplitViewController.dataFileSetColumnKind(_:)),
            keyEquivalent: ""
        )
        reset.representedObject = DataFileKindAssignment(column: column, kind: nil)
        submenu.addItem(reset)
        return submenu
    }

    static func caseSubmenu(for column: TabularColumnID?) -> NSMenu {
        let submenu = NSMenu()
        for style in TabularCaseStyle.allCases {
            let entry = NSMenuItem(title: label(for: style), action: #selector(DataFileSplitViewController.dataFileChangeCase(_:)), keyEquivalent: "")
            entry.representedObject = DataFileCaseAssignment(column: column, style: style)
            submenu.addItem(entry)
        }
        return submenu
    }

    static func label(for kind: TabularInferredKind) -> String {
        switch kind {
        case .text: return String(localized: "Text")
        case .integer: return String(localized: "Integer")
        case .decimal: return String(localized: "Decimal")
        case .boolean: return String(localized: "Boolean")
        case .date: return String(localized: "Date")
        }
    }

    static func symbol(for kind: TabularInferredKind) -> String {
        switch kind {
        case .text: return "textformat"
        case .integer: return "number"
        case .decimal: return "number.square"
        case .boolean: return "checkmark.square"
        case .date: return "calendar"
        }
    }

    static func label(for style: TabularCaseStyle) -> String {
        switch style {
        case .uppercase: return String(localized: "UPPERCASE")
        case .lowercase: return String(localized: "lowercase")
        case .titleCase: return String(localized: "Title Case")
        }
    }

    private static func item(_ title: String, _ action: Selector, _ column: TabularColumnID) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.representedObject = column
        entry.target = nil
        return entry
    }

    private static func rowItem(_ title: String, _ action: Selector, _ row: Int) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.representedObject = row
        entry.target = nil
        return entry
    }
}

extension DataFileSplitViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = NSMenuItem(title: String(localized: "Add Column…"), action: #selector(dataFileAddColumn(_:)), keyEquivalent: "")
        add.target = nil
        menu.addItem(add)
        let showAll = NSMenuItem(title: String(localized: "Show All Columns"), action: #selector(dataFileShowAllColumns(_:)), keyEquivalent: "")
        showAll.target = nil
        menu.addItem(showAll)
        guard !controller.columnNames.ids.isEmpty else { return }
        menu.addItem(.separator())
        for (id, name) in zip(controller.columnNames.ids, controller.columnNames.displayNames) {
            let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: DataFileColumnMenuBuilder.symbol(for: controller.kind(of: id)), accessibilityDescription: nil)
            let submenu = NSMenu()
            for item in DataFileColumnMenuBuilder.items(for: id, controller: controller, selectedColumns: []) {
                submenu.addItem(item)
            }
            entry.submenu = submenu
            menu.addItem(entry)
        }
    }
}
