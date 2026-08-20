//
//  NewPasswordField.swift
//  TablePro
//
//  A password entry field with a reveal toggle and a generator. The value is a database
//  credential, not the user's own, so it is never tagged for AutoFill saving.
//

import SwiftUI

struct NewPasswordField: View {
    @Binding var password: String
    var prompt: String?

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField("", text: $password, prompt: prompt.map { Text($0) })
                    } else {
                        SecureField("", text: $password, prompt: prompt.map { Text($0) })
                    }
                }
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "Password"))

                Button(String(localized: "Generate")) {
                    password = PasswordGenerator.generate()
                    isRevealed = true
                }
                .controlSize(.small)
            }

            Toggle(String(localized: "Show password"), isOn: $isRevealed)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
    }
}
