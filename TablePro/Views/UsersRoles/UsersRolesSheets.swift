import SwiftUI
import TableProPluginKit

struct SheetChrome<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            content()
                .padding(16)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                footer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
    }
}

// MARK: - Create

struct CreatePrincipalSheet: View {
    @Bindable var viewModel: UsersRolesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = "%"
    @State private var password = ""
    @State private var isRole = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicateName: Bool {
        viewModel.principalRows.contains { $0.info.ref.name == trimmedName }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !duplicateName && (isRole || !password.isEmpty)
    }

    var body: some View {
        SheetChrome(title: String(localized: "New User or Role")) {
            Form {
                if viewModel.capabilities.roleMembership {
                    Picker(String(localized: "Kind:"), selection: $isRole) {
                        Text("User").tag(false)
                        Text("Role").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                TextField(String(localized: "Name:"), text: $name)

                if duplicateName, !trimmedName.isEmpty {
                    LabeledContent("") {
                        Text("A user or role with this name already exists.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if viewModel.capabilities.hostScoping {
                    TextField(String(localized: "Host:"), text: $host)
                    LabeledContent("") {
                        Text("Use % to allow any host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !isRole {
                    LabeledContent(String(localized: "Password:")) {
                        NewPasswordField(password: $password)
                    }
                }
            }
            .formStyle(.columns)
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Create")) {
                viewModel.createPrincipal(definition())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .frame(minWidth: 460, idealWidth: 480)
        .accessibilityIdentifier("usersroles-create-sheet")
    }

    private func definition() -> PluginPrincipalDefinition {
        PluginPrincipalDefinition(
            ref: PluginPrincipalRef(
                name: trimmedName,
                host: viewModel.capabilities.hostScoping ? host : nil
            ),
            password: password.isEmpty ? nil : password,
            canLogin: !isRole
        )
    }
}

// MARK: - Change password

struct ChangePasswordSheet: View {
    @Bindable var viewModel: UsersRolesViewModel
    let principal: PluginPrincipalRef

    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var verify = ""

    private var mismatch: Bool {
        !verify.isEmpty && password != verify
    }

    private var isValid: Bool {
        !password.isEmpty && password == verify
    }

    var body: some View {
        SheetChrome(
            title: String(localized: "Change Password"),
            subtitle: principal.displayName
        ) {
            Form {
                LabeledContent(String(localized: "New password:")) {
                    NewPasswordField(password: $password)
                }
                SecureField(String(localized: "Verify:"), text: $verify)

                if mismatch {
                    LabeledContent("") {
                        Text("The passwords do not match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.columns)
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Set Password")) {
                viewModel.setPassword(password, for: principal)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .frame(minWidth: 460, idealWidth: 480)
    }
}

// MARK: - Drop

struct DropPrincipalSheet: View {
    @Bindable var viewModel: UsersRolesViewModel
    let prompt: PrincipalDropPrompt

    @Environment(\.dismiss) private var dismiss

    @State private var reassigns = true
    @State private var target: PluginPrincipalRef?

    private var disposition: PrincipalDropPrompt.Disposition? {
        guard reassigns else { return .dropOwned }
        return target.map { .reassign(to: $0) }
    }

    var body: some View {
        SheetChrome(
            title: prompt.title,
            subtitle: String(
                localized: "Choose what happens to them when the role is dropped."
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $reassigns) {
                    Text("Reassign owned objects").tag(true)
                    Text("Drop owned objects").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if !reassigns {
                    Text("Tables, views, and functions owned by this role will be deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent(String(localized: "Reassign to")) {
                    Picker("", selection: $target) {
                        ForEach(prompt.reassignCandidates, id: \.self) { candidate in
                            Text(candidate.displayName).tag(Optional(candidate))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .disabled(!reassigns)
            }
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) {
                viewModel.activeSheet = nil
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Drop Role"), role: .destructive) {
                guard let disposition else { return }
                viewModel.confirmDrop(prompt, disposition: disposition)
            }
            .disabled(disposition == nil)
        }
        .frame(minWidth: 460, idealWidth: 480)
        .onAppear {
            target = viewModel.connectedPrincipal ?? prompt.reassignCandidates.first
        }
    }
}

// MARK: - Role membership

struct RoleMembershipSheet: View {
    @Bindable var viewModel: UsersRolesViewModel
    let principal: PluginPrincipalRef

    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var selected: Set<String> = []

    private var roles: [String] {
        let names = viewModel.changeManager.principals
            .filter { $0.isRole && $0.ref != principal }
            .map(\.ref.name)
        guard !filter.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        SheetChrome(
            title: String(localized: "Member Of"),
            subtitle: principal.displayName
        ) {
            VStack(spacing: 8) {
                NativeSearchField(text: $filter, placeholder: String(localized: "Filter roles"))

                List(roles, id: \.self) { role in
                    Toggle(role, isOn: binding(for: role))
                        .toggleStyle(.checkbox)
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds(.enabled)
            }
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Done")) {
                apply()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 320, idealHeight: 380)
        .onAppear {
            let current = viewModel.changeManager.pendingAlters[principal]?.memberOf
                ?? viewModel.selectedPrincipal?.memberOf
                ?? []
            selected = Set(current)
        }
    }

    private func binding(for role: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(role) },
            set: { isOn in
                if isOn {
                    selected.insert(role)
                } else {
                    selected.remove(role)
                }
            }
        )
    }

    private func apply() {
        guard let info = viewModel.changeManager.principals.first(where: { $0.ref == principal })
        else { return }

        let current = viewModel.changeManager.pendingAlters[principal]
            ?? PrincipalChangeManager.definition(from: info)

        viewModel.stageAttributes(
            PluginPrincipalDefinition(
                ref: current.ref,
                password: nil,
                canLogin: current.canLogin,
                attributes: current.attributes,
                memberOf: selected.sorted(),
                connectionLimit: current.connectionLimit,
                comment: current.comment
            ),
            for: principal
        )
    }
}

// MARK: - Copy privileges

struct CopyPrivilegesSheet: View {
    @Bindable var viewModel: UsersRolesViewModel
    let target: PluginPrincipalRef

    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var source: PluginPrincipalRef?

    private var candidates: [PrincipalRow] {
        let rows = viewModel.principalRows.filter { $0.ref != target }
        guard !filter.isEmpty else { return rows }
        return rows.filter { $0.displayName.localizedCaseInsensitiveContains(filter) }
    }

    private var isSourceLoaded: Bool {
        guard let source else { return false }
        return viewModel.changeManager.hasLoadedGrants(for: source)
    }

    var body: some View {
        SheetChrome(
            title: String(localized: "Copy Privileges"),
            subtitle: String(
                format: String(localized: "Copy privileges to %@"),
                target.displayName
            )
        ) {
            VStack(spacing: 8) {
                NativeSearchField(text: $filter, placeholder: String(localized: "Filter"))

                List(candidates, selection: $source) { row in
                    Label(row.displayName, systemImage: row.symbolName)
                        .tag(row.ref)
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds(.enabled)
            }
        } footer: {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if source != nil, !isSourceLoaded {
                ProgressView().controlSize(.small)
            }
            Button(String(localized: "Copy")) {
                guard let source else { return }
                viewModel.copyPrivileges(from: source, to: target)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(source == nil || !isSourceLoaded)
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 320, idealHeight: 380)
        .task(id: source) {
            guard let source else { return }
            await viewModel.loadGrants(for: source)
        }
    }
}
