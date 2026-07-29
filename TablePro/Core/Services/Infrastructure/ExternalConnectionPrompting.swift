//
//  ExternalConnectionPrompting.swift
//  TablePro
//

import AppKit
import Foundation

internal enum ExternalConnectionDecision: Sendable {
    case connect
    case alwaysAllow
    case cancel
}

@MainActor
internal protocol ExternalConnectionPrompting {
    func prompt(for connection: DatabaseConnection, offerAlwaysAllow: Bool) async -> ExternalConnectionDecision
}

@MainActor
internal struct ExternalConnectionAlertPrompt: ExternalConnectionPrompting {
    internal func prompt(
        for connection: DatabaseConnection,
        offerAlwaysAllow: Bool
    ) async -> ExternalConnectionDecision {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open External Database Connection?")
        alert.informativeText = String(
            format: String(localized: """
                An external link wants to connect to a %@ database:

                %@

                Connect only if you trust the source of this link.
                """),
            connection.type.rawValue,
            details(for: connection).joined(separator: "\n")
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if offerAlwaysAllow {
            alert.addButton(withTitle: String(localized: "Always Allow"))
        }
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let response = await present(alert)
        switch response {
        case .alertFirstButtonReturn:
            return .connect
        case .alertThirdButtonReturn where offerAlwaysAllow:
            return .alwaysAllow
        default:
            return .cancel
        }
    }

    private func details(for connection: DatabaseConnection) -> [String] {
        var details: [String] = [
            String(format: String(localized: "Host: %@"), "\(connection.host):\(connection.port)")
        ]
        if !connection.username.isEmpty {
            details.append(String(format: String(localized: "User: %@"), connection.username))
        }
        if !connection.database.isEmpty {
            details.append(String(format: String(localized: "Database: %@"), connection.database))
        }
        return details
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = AlertHelper.resolveWindow(NSApp.keyWindow) else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
