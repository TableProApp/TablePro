//
//  InspectorRowMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
enum InspectorRowMenuBuilder {
    static func structureItems(forRow displayRow: Int) -> [NSMenuItem] {
        [
            actionItem(
                title: String(localized: "Insert Row Above"),
                action: #selector(InspectorViewController.inspectorInsertRowAbove(_:)),
                row: displayRow
            ),
            actionItem(
                title: String(localized: "Insert Row Below"),
                action: #selector(InspectorViewController.inspectorInsertRowBelow(_:)),
                row: displayRow
            ),
        ]
    }

    private static func actionItem(title: String, action: Selector, row: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.tag = row
        item.target = nil
        return item
    }
}
