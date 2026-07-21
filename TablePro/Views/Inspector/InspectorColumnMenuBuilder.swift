//
//  InspectorColumnMenuBuilder.swift
//  TablePro
//

import AppKit
import TableProPluginKit

@MainActor
enum InspectorColumnMenuBuilder {
    static func structureItems(
        forColumn index: Int,
        currentType: InspectorColumnType,
        deleteColumns: [Int]
    ) -> [NSMenuItem] {
        let rename = actionItem(
            title: String(localized: "Rename Column…"),
            action: #selector(InspectorViewController.inspectorRenameColumn(_:)),
            column: index
        )
        let insertLeft = actionItem(
            title: String(localized: "Insert Column Left"),
            action: #selector(InspectorViewController.inspectorInsertColumnLeft(_:)),
            column: index
        )
        let insertRight = actionItem(
            title: String(localized: "Insert Column Right"),
            action: #selector(InspectorViewController.inspectorInsertColumnRight(_:)),
            column: index
        )
        let changeType = NSMenuItem(title: String(localized: "Change Type"), action: nil, keyEquivalent: "")
        changeType.submenu = typeSubmenu(forColumn: index, currentType: currentType)
        let delete = actionItem(
            title: deleteColumns.count > 1
                ? String(localized: "Delete Columns")
                : String(localized: "Delete Column"),
            action: #selector(InspectorViewController.inspectorDeleteColumn(_:)),
            column: index
        )
        delete.representedObject = deleteColumns
        return [rename, insertLeft, insertRight, changeType, .separator(), delete]
    }

    static func typeSubmenu(forColumn index: Int, currentType: InspectorColumnType) -> NSMenu {
        let submenu = NSMenu()
        for type in InspectorColumnType.allCases {
            let item = actionItem(
                title: typeLabel(type),
                action: #selector(InspectorViewController.inspectorSetColumnType(_:)),
                column: index
            )
            item.representedObject = ColumnTypeAssignment(column: index, type: type)
            item.state = (type == currentType) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let reset = actionItem(
            title: String(localized: "Reset to Inferred"),
            action: #selector(InspectorViewController.inspectorSetColumnType(_:)),
            column: index
        )
        reset.representedObject = ColumnTypeAssignment(column: index, type: nil)
        submenu.addItem(reset)
        return submenu
    }

    static func typeSymbol(_ type: InspectorColumnType) -> String {
        switch type {
        case .text: return "textformat"
        case .integer: return "number"
        case .real: return "number.square"
        case .boolean: return "checkmark.square"
        case .date: return "calendar"
        }
    }

    static func typeLabel(_ type: InspectorColumnType) -> String {
        switch type {
        case .text: return String(localized: "Text")
        case .integer: return String(localized: "Integer")
        case .real: return String(localized: "Real")
        case .boolean: return String(localized: "Boolean")
        case .date: return String(localized: "Date")
        }
    }

    private static func actionItem(title: String, action: Selector, column: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.tag = column
        item.target = nil
        return item
    }
}
