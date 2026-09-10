//
//  PluginDeveloperTrustPrompting.swift
//  TablePro
//

import AppKit
import Foundation

internal enum PluginDeveloperTrustDecision: Sendable {
    case trust
    case cancel
}

@MainActor
internal protocol PluginDeveloperTrustPrompting {
    func prompt(for identity: PluginDeveloperIdentity, pluginName: String) async -> PluginDeveloperTrustDecision
}

@MainActor
internal struct PluginDeveloperTrustAlertPrompt: PluginDeveloperTrustPrompting {
    internal func prompt(
        for identity: PluginDeveloperIdentity,
        pluginName: String
    ) async -> PluginDeveloperTrustDecision {
        let response = await present(Self.makeAlert(for: identity, pluginName: pluginName))
        return response == .alertFirstButtonReturn ? .trust : .cancel
    }

    internal static func makeAlert(for identity: PluginDeveloperIdentity, pluginName: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(localized: "Trust plugins from %@?"),
            identity.name
        )
        alert.informativeText = String(
            format: String(localized: """
                %1$@ was signed by %2$@ (Team ID %3$@) and notarized by Apple. TablePro did not \
                write it.

                A database plugin runs as part of TablePro and can read the credentials of every \
                connection you open. Trust this developer only if you would give them that access.

                Trusting applies to every plugin this developer signs, now and later. You can \
                withdraw it in Settings > Plugins.
                """),
            pluginName,
            identity.name,
            identity.teamID
        )
        alert.addButton(withTitle: String(localized: "Trust and Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}
