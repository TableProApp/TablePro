//
//  PreConnectScriptPrompt.swift
//  TablePro
//

import AppKit
import Foundation

internal extension DatabaseConnection {
    var trimmedPreConnectScript: String? {
        guard let script = preConnectScript else { return nil }
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasPreConnectScript: Bool {
        trimmedPreConnectScript != nil
    }
}

/// A pre-connect script is arbitrary shell code stored with the connection, so it only ever runs
/// off a gesture the user makes in this session. Keeping the confirmation here rather than at
/// each call site means no connect route can quietly skip it.
@MainActor
internal enum PreConnectScriptPrompt {
    internal static func confirmIfNeeded(for connection: DatabaseConnection) async -> Bool {
        guard let script = connection.trimmedPreConnectScript else { return true }
        return await AlertHelper.confirmDestructive(
            title: String(localized: "Pre-Connect Script"),
            message: String(
                format: String(localized: "Connection \"%@\" has a script that will run before connecting:\n\n%@"),
                connection.name, script
            ),
            confirmButton: String(localized: "Run Script"),
            cancelButton: String(localized: "Cancel"),
            window: NSApp.keyWindow
        )
    }
}
