//
//  OperationConfirming.swift
//  TablePro
//

import AppKit

internal protocol OperationConfirming: Sendable {
    @MainActor
    func confirm(sql: String, operationDescription: String, connectionId: UUID, isDestructive: Bool) async -> Bool
}

internal struct AlertOperationConfirming: OperationConfirming {
    @MainActor
    func confirm(sql: String, operationDescription: String, connectionId: UUID, isDestructive: Bool) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let window = WindowLifecycleMonitor.shared.findWindow(for: connectionId)
        let preview = Self.preview(of: sql)

        if isDestructive {
            return await AlertHelper.confirmCritical(
                title: operationDescription,
                message: String(
                    format: String(localized: "This query may permanently modify or delete data and cannot be undone.\n\n%@"),
                    preview
                ),
                confirmButton: String(localized: "Execute"),
                cancelButton: String(localized: "Cancel"),
                window: window
            )
        }

        return await AlertHelper.confirmDestructive(
            title: operationDescription,
            message: String(
                format: String(localized: "Are you sure you want to execute this query?\n\n%@"),
                preview
            ),
            confirmButton: String(localized: "Execute"),
            cancelButton: String(localized: "Cancel"),
            window: window
        )
    }

    private static func preview(of sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed as NSString).length > 200 {
            return String(trimmed.prefix(200)) + "..."
        }
        return trimmed
    }
}
