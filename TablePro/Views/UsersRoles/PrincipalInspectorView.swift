import SwiftUI
import TableProPluginKit

struct PrincipalInspectorView: View {
    @Bindable var viewModel: UsersRolesViewModel
    let principal: PluginPrincipalInfo

    private var changeManager: PrincipalChangeManager { viewModel.changeManager }

    private var catalog: PluginPrivilegeCatalog? { changeManager.catalog }

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Name", value: principal.ref.name)
                if let host = principal.ref.host {
                    LabeledContent("Host", value: host)
                }
                LabeledContent("Can log in", value: principal.canLogin ? "Yes" : "No")
                if let limit = principal.connectionLimit {
                    LabeledContent("Connection limit", value: "\(limit)")
                }
                Button("Change Password…") {
                    viewModel.isPasswordSheetPresented = true
                }
                if changeManager.pendingPasswords[principal.ref] != nil {
                    Text("A new password will be set when you apply changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !principal.attributes.isEmpty {
                Section("Attributes") {
                    ForEach(principal.attributes, id: \.key) { attribute in
                        LabeledContent(attribute.label, value: attribute.isEnabled ? "Yes" : "No")
                    }
                }
            }

            if viewModel.supportsRoleMembership, !principal.memberOf.isEmpty {
                Section("Member of") {
                    ForEach(principal.memberOf, id: \.self) { role in
                        Text(role)
                    }
                }
            }

            Section("Privileges") {
                privilegeTree
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var privilegeTree: some View {
        if let catalog, !catalog.allPrivileges.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                PrivilegeTreeView(
                    roots: viewModel.privilegeRoots,
                    version: viewModel.treeVersion,
                    privileges: catalog.allPrivileges,
                    catalog: catalog,
                    isGranted: { privilege, scope in
                        changeManager.isGranted(privilege, scope: scope, for: principal.ref)
                    },
                    hasDescendantGrant: { privilege, scope in
                        changeManager.hasDescendantGrant(privilege, under: scope, for: principal.ref)
                    },
                    onToggle: { privilege, scope, isGranted in
                        changeManager.setGranted(
                            isGranted,
                            privilege: privilege,
                            scope: scope,
                            for: principal.ref
                        )
                    },
                    onExpand: { viewModel.expand($0) }
                )
                .frame(height: 360)

                Text("Expand a database to grant on its schemas, tables, and columns. A dash means the privilege is granted somewhere inside.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No privileges reported by the server.")
                .foregroundStyle(.secondary)
        }
    }
}
