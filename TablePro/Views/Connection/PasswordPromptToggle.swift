//
//  PasswordPromptToggle.swift
//  TablePro
//
//  Toggle + conditional SecureField for the "ask for password on every connection" option.
//

import SwiftUI
import TableProPluginKit

struct PasswordPromptToggle: View {
    let type: DatabaseType
    @Binding var promptForPassword: Bool
    @Binding var password: String
    @Binding var additionalFieldValues: [String: String]

    private var isApiOnly: Bool {
        PluginManager.shared.connectionMode(for: type) == .apiOnly
    }

    var body: some View {
        Toggle(
            isApiOnly
                ? String(localized: "Ask for API token on every connection")
                : String(localized: "Ask for password on every connection"),
            isOn: $promptForPassword
        )
        .onChange(of: promptForPassword) { _, newValue in
            if newValue {
                password = ""
                if additionalFieldValues["usePgpass"] == "true" {
                    additionalFieldValues["usePgpass"] = ""
                }
            }
        }
        if !promptForPassword {
            SecureField(
                isApiOnly ? String(localized: "API Token") : String(localized: "Password"),
                text: $password
            )
        }
    }
}
