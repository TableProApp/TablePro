//
//  PasswordPromptToggle.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct PasswordPromptToggle: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    private var auth: AuthPaneViewModel { coordinator.auth }

    private var isApiOnly: Bool {
        PluginManager.shared.connectionMode(for: coordinator.network.type) == .apiOnly
    }

    private var passwordTitle: String {
        isApiOnly ? String(localized: "API Token") : String(localized: "Password")
    }

    var body: some View {
        if !auth.promptForPassword {
            if let source = auth.passwordSource {
                PasswordSourceSummary(title: passwordTitle, source: source)
                PasswordSourceTestView(
                    source: source,
                    context: { coordinator.passwordSourceContext() },
                    refusal: {
                        coordinator.storage.storeIsTrusted ? nil : PasswordSourceResolver.ResolutionError.storeNotTrusted
                    }
                )
            } else {
                RevealablePasswordField(
                    title: passwordTitle,
                    text: $coordinator.auth.password,
                    requiresAuthentication: auth.storedPasswordState != .absent
                )
            }
        }
        Toggle(
            isApiOnly
                ? String(localized: "Prompt for API token")
                : String(localized: "Prompt for password"),
            isOn: $coordinator.auth.promptForPassword
        )
        .onChange(of: auth.promptForPassword) { newValue in
            if newValue {
                coordinator.auth.password = ""
                if coordinator.auth.additionalFieldValues["usePgpass"] == "true" {
                    coordinator.auth.additionalFieldValues["usePgpass"] = ""
                }
            }
        }
    }
}
