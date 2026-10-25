//
//  DataGridEditSession.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// Captured when an editor opens, so a reload, a sort or a tab switch never redirects its commit (H2).
struct DataGridEditTarget: Equatable {
    let rowID: RowID
    let columnID: DataGridColumnID
}

struct DataGridEditSession {
    enum Editor: Equatable {
        case field
        case textPopover
    }

    let target: DataGridEditTarget
    let editor: Editor
    // Committing it unchanged is no edit, even over a NULL that opened as empty text.
    let originalText: String
    // A replaced result reuses RowIDs for other records; the values tell them apart.
    let originalRow: ContiguousArray<PluginCellValue>
    var pane: DataGridPane.Kind
    // Read by every drawn cell, so it is refreshed per change rather than resolved per draw.
    var cell: GridCoord
}

struct DataGridHeldRow {
    let target: DataGridEditTarget
    var values: ContiguousArray<PluginCellValue>
}

struct DataGridEditCell {
    let coord: GridCoord
    let row: Row
    let column: DataGridColumn

    var target: DataGridEditTarget {
        DataGridEditTarget(rowID: row.id, columnID: column.id)
    }

    var value: PluginCellValue {
        row[column.dataIndex]
    }

    var isUnloaded: Bool {
        row.unloadedByteCount(column.dataIndex) != nil
    }
}

// A reload ends AppKit's editing (probe P1d), so the field pauses across one.
struct DataGridSuspendedFieldEdit {
    let session: DataGridEditSession
    let text: String
    let selection: NSRange
}

// A menu item's target is weak, so the item keeps its action alive as its represented object.
@MainActor
final class DataGridMenuAction: NSObject {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @objc func invoke(_ sender: Any?) {
        perform()
    }

    static func item(
        _ title: String,
        state: NSControl.StateValue = .off,
        perform: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let action = DataGridMenuAction(perform)
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.state = state
        return item
    }
}
