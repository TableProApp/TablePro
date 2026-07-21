//
//  InspectorDeleteConfirmation.swift
//  TablePro
//

import AppKit

@MainActor
enum InspectorDeleteConfirmation {
    static func rowsContainData(_ rowsCells: [[String]]) -> Bool {
        rowsCells.contains { cells in cells.contains { !$0.isEmpty } }
    }

    static func rowDeleteTitle(count: Int) -> String {
        count == 1
            ? String(localized: "Delete this row?")
            : String(format: String(localized: "Delete %lld rows?"), count)
    }

    static func confirmDeleteRowsIfNeeded(
        rowsCells: [[String]],
        window: NSWindow?,
        proceed: @escaping @MainActor () -> Void
    ) {
        guard rowsContainData(rowsCells) else {
            proceed()
            return
        }
        present(messageText: rowDeleteTitle(count: rowsCells.count), window: window, proceed: proceed)
    }

    private static func present(
        messageText: String,
        window: NSWindow?,
        proceed: @escaping @MainActor () -> Void
    ) {
        guard let window else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: String(localized: "Delete"))
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            proceed()
        }
    }
}
