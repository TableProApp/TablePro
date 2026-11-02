//
//  LoadableExtensionPrompt.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

// Names each file, since the person is agreeing to run that code.
@MainActor
internal enum LoadableExtensionPrompt {
    internal static func confirmIfNeeded(
        for connection: DatabaseConnection,
        approvals: LoadableExtensionApprovalStore = .shared
    ) async -> Bool {
        let pending = LoadableExtensionGate.pendingApproval(for: connection, approvals: approvals)
        guard !pending.isEmpty else { return true }
        let answer = await AlertHelper.askConsent(
            title: String(localized: "Load Extensions"),
            message: message(for: connection, pending: pending),
            confirmButton: String(localized: "Load Extensions"),
            window: NSApp.keyWindow
        )
        guard answer == .approved else { return false }
        approvals.approve(pending, for: connection.id)
        return true
    }

    internal static func message(for connection: DatabaseConnection, pending: [LoadableExtension]) -> String {
        let files = pending.map { item in
            guard let entryPoint = item.entryPoint else { return item.path }
            return String(format: String(localized: "%@ (entry point %@)"), item.path, entryPoint)
        }
        let intro = String(
            format: String(localized: "Connection \"%@\" loads SQLite extensions that were not added on this Mac:"),
            singleLine(connection.name)
        )
        let warning = String(
            localized: "An extension runs inside TablePro with full access to your Mac. Load them only if you trust these files."
        )
        return [intro, files.joined(separator: "\n"), warning].joined(separator: "\n\n")
    }

    // Text that arrived with the connection may not add lines of its own to a consent alert.
    internal static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
    }
}

// One call for every question a person's connect asks before it starts, so no route skips one.
@MainActor
internal enum ConnectConsent {
    internal static func requiresPrompt(for connection: DatabaseConnection, manager: DatabaseManager = .shared) -> Bool {
        connection.hasPreConnectScript
            || !LoadableExtensionGate.pendingApproval(for: connection).isEmpty
            || manager.envVarReferenceConsent.requiresApproval(connection)
    }

    internal static func confirmIfNeeded(
        for connection: DatabaseConnection,
        manager: DatabaseManager = .shared
    ) async -> Bool {
        if case .live = manager.connectionState(connection.id) { return true }
        // First, so the script approval's lifetime does not run down while this prompt is open.
        guard await manager.envVarReferenceConsent.confirm(connection) else { return false }
        let scriptConsent = manager.preConnectScriptConsent
        guard await scriptConsent.confirm(connection) else { return false }
        guard await LoadableExtensionPrompt.confirmIfNeeded(for: connection) else {
            scriptConsent.withdrawApproval(for: connection.id)
            return false
        }
        return true
    }
}
