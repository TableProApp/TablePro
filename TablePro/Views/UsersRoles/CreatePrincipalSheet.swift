import SwiftUI
import TableProPluginKit

struct CreatePrincipalSheet: View {
    let supportsHostScoping: Bool
    let supportsRoleMembership: Bool
    let availableRoles: [String]
    let onCreate: (PluginPrincipalDefinition) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = "%"
    @State private var password = ""
    @State private var canLogin = true
    @State private var memberOf: Set<String> = []

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && (!canLogin || !password.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New User or Role")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                TextField("Name:", text: $name)

                if supportsHostScoping {
                    TextField("Host:", text: $host)
                    LabeledContent("") {
                        Text("Use % to allow any host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Can log in", isOn: $canLogin)

                LabeledContent("Password:") {
                    HStack(spacing: 8) {
                        SecurePasswordField(text: $password)
                        Button("Generate") {
                            password = GeneratedPassword.suggest()
                        }
                    }
                }

                if supportsRoleMembership, !availableRoles.isEmpty {
                    Section("Member of") {
                        ForEach(availableRoles, id: \.self) { role in
                            Toggle(role, isOn: membership(for: role))
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
                Button("Create") {
                    onCreate(definition())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func membership(for role: String) -> Binding<Bool> {
        Binding(
            get: { memberOf.contains(role) },
            set: { isOn in
                if isOn {
                    memberOf.insert(role)
                } else {
                    memberOf.remove(role)
                }
            }
        )
    }

    private func definition() -> PluginPrincipalDefinition {
        PluginPrincipalDefinition(
            ref: PluginPrincipalRef(
                name: trimmedName,
                host: supportsHostScoping ? host : nil
            ),
            password: password.isEmpty ? nil : password,
            canLogin: canLogin,
            memberOf: memberOf.sorted()
        )
    }
}
