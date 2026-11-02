//
//  LocalCredentialPrompt.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor
internal enum LocalCredentialPrompt {
    internal static func ask(_ question: LocalCredentialQuestion) async -> ConsentAnswer {
        await AlertHelper.askConsent(
            title: String(localized: "Sign In with Credentials from This Mac?"),
            message: message(for: question),
            confirmButton: String(localized: "Sign In"),
            window: NSApp.keyWindow
        )
    }

    internal static func message(for question: LocalCredentialQuestion) -> String {
        let summary = String(
            format: String(localized: "Connection “%1$@” signs in to %2$@ with credentials stored on this Mac:"),
            LoadableExtensionPrompt.singleLine(question.connectionName),
            LoadableExtensionPrompt.singleLine(question.destination)
        )
        let uses = question.uses.map(LoadableExtensionPrompt.singleLine).joined(separator: "\n")
        let warning = String(localized: "Allow this only if you trust where the connection signs in.")
        return [summary, uses, originLine(question.origin), warning]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private static func originLine(_ origin: ConnectionOrigin) -> String? {
        switch origin {
        case .thisMac:
            nil
        case .imported:
            String(localized: "This connection was imported, so someone else may have chosen the server and how it signs in.")
        case .synced:
            String(localized: "This connection arrived through iCloud from another device.")
        case .link:
            String(localized: "This connection was opened from a link, so its sender chose the server and how it signs in.")
        case .linkedFolder:
            String(localized: "This connection comes from a file in a linked folder, so its author chose the server and how it signs in.")
        case .teamLibrary:
            String(localized: "This connection comes from your team library, so a teammate chose the server and how it signs in.")
        }
    }
}
