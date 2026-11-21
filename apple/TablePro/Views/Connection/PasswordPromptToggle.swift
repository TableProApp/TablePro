//
//  PasswordPromptToggle.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// How this connection supplies its password: stored in the Keychain, or asked for on every
/// connect. A password source set elsewhere (a credential profile, or an import that ran a command)
/// keeps its own read-only summary and the plain prompt toggle.
struct PasswordPromptToggle: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator

    private enum Mode: Hashable {
        case keychain
        case prompt
    }

    private var auth: AuthPaneViewModel { coordinator.auth }

    private var isApiOnly: Bool {
        PluginManager.shared.connectionMode(for: coordinator.network.type) == .apiOnly
    }

    private var passwordTitle: String {
        isApiOnly ? String(localized: "API Token") : String(localized: "Password")
    }

    private var mode: Binding<Mode> {
        Binding(
            get: { auth.promptForPassword ? .prompt : .keychain },
            set: { setPrompt($0 == .prompt) }
        )
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { auth.promptForPassword }, set: { setPrompt($0) })
    }

    private func setPrompt(_ prompt: Bool) {
        coordinator.auth.promptForPassword = prompt
        guard prompt else { return }
        coordinator.auth.password = ""
        if coordinator.auth.additionalFieldValues["usePgpass"] == "true" {
            coordinator.auth.additionalFieldValues["usePgpass"] = ""
        }
    }

    var body: some View {
        if let source = auth.passwordSource {
            if !auth.promptForPassword {
                PasswordSourceSummary(title: passwordTitle, source: source)
                PasswordSourceTestView(
                    source: source,
                    context: { coordinator.passwordSourceContext() },
                    leaseOwner: { coordinator.connectionId },
                    refusal: {
                        coordinator.storage.storeIsTrusted ? nil : PasswordSourceResolver.ResolutionError.storeNotTrusted
                    }
                )
            }
            Toggle(
                isApiOnly
                    ? String(localized: "Prompt for API token")
                    : String(localized: "Prompt for password"),
                isOn: promptBinding
            )
        } else {
            Picker(passwordTitle, selection: mode) {
                Text(String(localized: "Store in Keychain")).tag(Mode.keychain)
                Text(String(localized: "Ask Every Time")).tag(Mode.prompt)
            }
            .accessibilityIdentifier("connection-form-password-mode")
            if !auth.promptForPassword {
                RevealablePasswordField(
                    title: passwordTitle,
                    text: $coordinator.auth.password,
                    requiresAuthentication: auth.storedPasswordState != .absent
                )
            }
        }
    }
}
