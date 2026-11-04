//
//  EnvVarReferencePrompt.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor
internal enum EnvVarReferencePrompt {
    internal static func ask(_ question: EnvVarReferenceQuestion) async -> ConsentAnswer {
        await AlertHelper.askConsent(
            title: String(localized: "Send Environment Variables?"),
            message: message(for: question),
            confirmButton: String(localized: "Send Values"),
            window: NSApp.keyWindow
        )
    }

    // Names and the destination as written, never a value: the person decides before anything is read.
    internal static func message(for question: EnvVarReferenceQuestion) -> String {
        let summary = String(
            format: String(localized: "Connection “%@” reads %@ from TablePro's environment and sends the values to %@."),
            LoadableExtensionPrompt.singleLine(question.connectionName),
            ListFormatter.localizedString(byJoining: question.names.map { "$" + $0 }),
            LoadableExtensionPrompt.singleLine(question.destination)
        )
        guard let source = originLine(question.origin) else { return summary }
        return [summary, source].joined(separator: "\n\n")
    }

    private static func originLine(_ origin: ConnectionOrigin) -> String? {
        switch origin {
        case .thisMac:
            nil
        case .imported:
            String(localized: "This connection was imported, so someone else may have chosen the server and the variables.")
        case .synced:
            String(localized: "This connection arrived through iCloud from another device.")
        case .link:
            String(localized: "This connection was opened from a link, so its sender chose the server and the variables.")
        case .linkedFolder:
            String(localized: "This connection comes from a file in a linked folder, so its author chose the server and the variables.")
        case .teamLibrary:
            String(localized: "This connection comes from your team library, so a teammate chose the server and the variables.")
        }
    }
}
