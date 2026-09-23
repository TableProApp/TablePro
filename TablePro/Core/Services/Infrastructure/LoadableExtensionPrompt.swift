//
//  LoadableExtensionPrompt.swift
//  TablePro
//

import AppKit
import Foundation
import TableProPluginKit

/// Asks before a connect loads SQLite extensions this Mac has not approved for the connection, which
/// is every list that arrived through an import, a link, a linked folder, the team library or
/// iCloud rather than being added in the connection form here. It names each file, because the
/// person is agreeing to run that code, and records the answer so the same list does not ask again.
@MainActor
internal enum LoadableExtensionPrompt {
    internal static func confirmIfNeeded(
        for connection: DatabaseConnection,
        approvals: LoadableExtensionApprovalStore = .shared
    ) async -> Bool {
        let pending = LoadableExtensionGate.pendingApproval(for: connection, approvals: approvals)
        guard !pending.isEmpty else { return true }
        let approved = await AlertHelper.confirmDestructive(
            title: String(localized: "Load Extensions"),
            message: message(for: connection, pending: pending),
            confirmButton: String(localized: "Load Extensions"),
            cancelButton: String(localized: "Cancel"),
            window: NSApp.keyWindow
        )
        guard approved else { return false }
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

    /// A connection name arrives with the connection, from an import or another Mac, so it may not
    /// add lines of its own to an alert whose other lines name the code about to run.
    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
    }
}

/// Everything a connect started by a person has to clear before it may run code the connection
/// carries: its pre-connect script, then its extensions. One call, so no route can ask for one and
/// forget the other.
@MainActor
internal enum ConnectConsent {
    internal static func requiresPrompt(for connection: DatabaseConnection) -> Bool {
        connection.hasPreConnectScript || !LoadableExtensionGate.pendingApproval(for: connection).isEmpty
    }

    internal static func confirmIfNeeded(for connection: DatabaseConnection) async -> Bool {
        guard await PreConnectScriptPrompt.confirmIfNeeded(for: connection) else { return false }
        return await LoadableExtensionPrompt.confirmIfNeeded(for: connection)
    }
}
