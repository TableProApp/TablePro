//
//  OperationConfirming.swift
//  TablePro
//

import AppKit
import TableProPluginKit

internal struct OperationConfirmationRequest: Sendable {
    let sql: String?
    let operationDescription: String
    let connectionId: UUID
    let connectionName: String?
    let databaseType: DatabaseType
    let caller: OperationCaller
    let isDestructive: Bool
}

internal protocol OperationConfirming: Sendable {
    @MainActor
    func confirm(_ request: OperationConfirmationRequest) async -> Bool
}

/// What the user is shown before a statement runs. Everything here is a pure function of the
/// request so the wording can be tested without presenting anything.
internal enum OperationConfirmationPrompt {
    internal static let confirmTitle = String(localized: "Execute")

    internal static func statement(of request: OperationConfirmationRequest) -> String? {
        guard let sql = request.sql?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty else {
            return nil
        }
        return sql
    }

    internal static func subtitle(of request: OperationConfirmationRequest) -> String {
        let connection = request.connectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = clientName(for: request.caller) else {
            guard let connection, !connection.isEmpty else {
                return String(localized: "Review this before it runs.")
            }
            return String(format: String(localized: "Runs on '%@'."), connection)
        }
        guard let connection, !connection.isEmpty else {
            return String(format: String(localized: "%@ wants to run this."), client)
        }
        return String(format: String(localized: "%1$@ wants to run this on '%2$@'."), client, connection)
    }

    internal static func destructiveWarning(of request: OperationConfirmationRequest) -> String? {
        guard request.isDestructive else { return nil }
        return String(localized: "This may permanently modify or delete data and cannot be undone.")
    }

    /// A rename has no statement to show: the driver builds it from the names, and two engines
    /// perform it without SQL at all. The review dialog would render an empty box, so this case
    /// stays an alert, which is what an alert is for.
    @MainActor
    internal static func makeAlert(for request: OperationConfirmationRequest) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = request.operationDescription
        alert.informativeText = [subtitle(of: request), destructiveWarning(of: request)]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.alertStyle = request.isDestructive ? .critical : .warning
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: confirmTitle,
            cancelButton: String(localized: "Cancel")
        )
        return alert
    }

    private static func clientName(for caller: OperationCaller) -> String? {
        switch caller {
        case .userInterface, .importPipeline, .backgroundMaintenance:
            return nil
        case .mcpClient(let label):
            return label ?? String(localized: "An MCP client")
        case .aiAssistant:
            return String(localized: "The AI assistant")
        case .appleScript(let client):
            return client ?? String(localized: "Another app")
        }
    }
}

internal struct AlertOperationConfirming: OperationConfirming {
    @MainActor
    func confirm(_ request: OperationConfirmationRequest) async -> Bool {
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let window = WindowLifecycleMonitor.shared.activeWindow(
            for: request.connectionId,
            preferring: NSApp.keyWindow
        )

        guard let statement = OperationConfirmationPrompt.statement(of: request) else {
            let alert = OperationConfirmationPrompt.makeAlert(for: request)
            return await AlertHelper.response(to: alert, in: window) == .alertFirstButtonReturn
        }

        return await AlertHelper.runStatementConfirmation(
            title: request.operationDescription,
            subtitle: OperationConfirmationPrompt.subtitle(of: request),
            warning: OperationConfirmationPrompt.destructiveWarning(of: request),
            statements: [statement],
            databaseType: request.databaseType,
            confirmTitle: OperationConfirmationPrompt.confirmTitle,
            isDestructive: request.isDestructive,
            window: window
        )
    }
}
