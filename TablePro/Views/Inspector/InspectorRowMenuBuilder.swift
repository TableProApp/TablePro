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

    /// A menu bar item carries no clicked row, so an absent anchor must fall through to the
    /// grid selection instead of resolving to row 0.
    static func insertAnchorDisplayRow(sender: Any?, selectedDisplayRows: Set<Int>, below: Bool) -> Int? {
        if let clicked = clickedRow(from: sender) { return clicked }
        return below ? selectedDisplayRows.max() : selectedDisplayRows.min()
    }

    private static func clickedRow(from sender: Any?) -> Int? {
        (sender as? NSMenuItem)?.representedObject as? Int
    }

    private static func actionItem(title: String, action: Selector, row: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = row
        item.target = nil
        return item
    }
}
