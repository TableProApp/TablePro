import SwiftUI
import TableProPluginKit

struct ChangePasswordSheet: View {
    let principal: PluginPrincipalRef
    let onSet: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Change Password")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Text(principal.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 2)

            Form {
                LabeledContent("New password:") {
                    HStack(spacing: 8) {
                        SecurePasswordField(text: $password)
                        Button("Generate") {
                            password = GeneratedPassword.suggest()
                        }
                    }
                }
            }
            .formStyle(.columns)
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Password") {
                    onSet(password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
    }
}
