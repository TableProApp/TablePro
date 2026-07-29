import SwiftUI
import TableProPluginKit

struct PrincipalAttributesForm: View {
    @Bindable var viewModel: UsersRolesViewModel
    let principal: PluginPrincipalInfo

    private var draft: PluginPrincipalDefinition {
        viewModel.changeManager.pendingAlters[principal.ref]
            ?? PrincipalChangeManager.definition(from: principal)
    }

    var body: some View {
        Form {
            Section(String(localized: "Identity")) {
                LabeledContent(String(localized: "Name"), value: principal.ref.name)
                if let host = principal.ref.host {
                    LabeledContent(String(localized: "Host"), value: host)
                }
            }

            Section {
                Toggle(String(localized: "Can log in"), isOn: canLoginBinding)
                    .disabled(!viewModel.capabilities.roleMembership)

                Button(String(localized: "Change Password…")) {
                    viewModel.activeSheet = .changePassword(principal.ref)
                }
            } header: {
                Text("Authentication")
            } footer: {
                if viewModel.changeManager.pendingPasswords[principal.ref] != nil {
                    Text("A new password will be set when you apply changes.")
                }
            }

            if !principal.attributes.isEmpty {
                Section {
                    ForEach(principal.attributes, id: \.key) { attribute in
                        Toggle(attribute.label, isOn: attributeBinding(attribute))
                    }
                } header: {
                    Text("Role Attributes")
                } footer: {
                    if isSuperuser {
                        Text("A superuser bypasses all permission checks.")
                    }
                }
            }

            if viewModel.capabilities.roleMembership {
                Section(String(localized: "Membership")) {
                    LabeledContent(String(localized: "Member of")) {
                        HStack {
                            Text(membershipSummary)
                                .foregroundStyle(draft.memberOf.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button(String(localized: "Edit…")) {
                                viewModel.activeSheet = .roleMembership(principal.ref)
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Limits")) {
                LabeledContent(String(localized: "Connection limit")) {
                    TextField(
                        "",
                        value: connectionLimitBinding,
                        format: .number,
                        prompt: Text("Unlimited")
                    )
                    .frame(width: 90)
                    .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isSuperuser: Bool {
        draft.attributes.contains { $0.key == "SUPERUSER" && $0.isEnabled }
    }

    private var membershipSummary: String {
        draft.memberOf.isEmpty
            ? String(localized: "None")
            : draft.memberOf.formatted(.list(type: .and))
    }

    private var canLoginBinding: Binding<Bool> {
        Binding(
            get: { draft.canLogin },
            set: { stage(canLogin: $0) }
        )
    }

    private var connectionLimitBinding: Binding<Int?> {
        Binding(
            get: { draft.connectionLimit },
            set: { stage(connectionLimit: $0) }
        )
    }

    private func attributeBinding(_ attribute: PluginPrincipalAttribute) -> Binding<Bool> {
        Binding(
            get: {
                draft.attributes.first { $0.key == attribute.key }?.isEnabled ?? attribute.isEnabled
            },
            set: { isEnabled in
                let attributes = draft.attributes.map {
                    $0.key == attribute.key
                        ? PluginPrincipalAttribute(
                            key: $0.key,
                            label: $0.label,
                            isEnabled: isEnabled
                        )
                        : $0
                }
                stage(attributes: attributes)
            }
        )
    }

    private func stage(
        canLogin: Bool? = nil,
        attributes: [PluginPrincipalAttribute]? = nil,
        connectionLimit: Int?? = nil
    ) {
        let current = draft
        viewModel.stageAttributes(
            PluginPrincipalDefinition(
                ref: current.ref,
                password: nil,
                canLogin: canLogin ?? current.canLogin,
                attributes: attributes ?? current.attributes,
                memberOf: current.memberOf,
                connectionLimit: connectionLimit ?? current.connectionLimit,
                comment: current.comment
            ),
            for: principal.ref
        )
    }
}
