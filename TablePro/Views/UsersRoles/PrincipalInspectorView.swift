import SwiftUI
import TableProPluginKit

struct PrincipalInspectorView: View {
    @Bindable var viewModel: UsersRolesViewModel
    let principal: PluginPrincipalInfo

    private var changeManager: PrincipalChangeManager { viewModel.changeManager }

    private var readOnlyGrants: [PluginGrantInfo] {
        changeManager.readOnlyGrants(for: principal.ref)
    }

    private var scopes: [PluginPrivilegeScope] {
        var scopes: [PluginPrivilegeScope] = []
        if let catalog = changeManager.catalog, !catalog.serverPrivileges.isEmpty {
            scopes.append(.server)
        }
        scopes.append(contentsOf: viewModel.databases.map { .database($0) })
        return scopes
    }

    private var privileges: [PluginPrivilegeDescriptor] {
        guard let catalog = changeManager.catalog else { return [] }
        var seen = Set<String>()
        return (catalog.serverPrivileges + catalog.databasePrivileges).filter { seen.insert($0.name).inserted }
    }

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
                if privileges.isEmpty {
                    Text("No privileges reported by the server.")
                        .foregroundStyle(.secondary)
                } else {
                    PrivilegeGridView(
                        scopes: scopes,
                        privileges: privileges,
                        databasePrivileges: Set((changeManager.catalog?.databasePrivileges ?? []).map(\.name)),
                        serverPrivileges: Set((changeManager.catalog?.serverPrivileges ?? []).map(\.name)),
                        isGranted: { privilege, scope in
                            changeManager.isGranted(privilege, scope: scope, for: principal.ref)
                        },
                        onToggle: { privilege, scope, isGranted in
                            changeManager.setGranted(
                                isGranted,
                                privilege: privilege,
                                scope: scope,
                                for: principal.ref
                            )
                        }
                    )
                    .frame(minHeight: 240)
                }
            }

            if !readOnlyGrants.isEmpty {
                Section("Table and Column Privileges") {
                    Text("Managed outside TablePro in this version. Shown so a database-level change does not hide them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(readOnlyGrants.enumerated()), id: \.offset) { _, grant in
                        LabeledContent(Self.scopeLabel(grant.scope), value: grant.privilege)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func scopeLabel(_ scope: PluginPrivilegeScope) -> String {
        switch scope {
        case .server:
            String(localized: "Server")
        case let .database(name):
            name
        case let .schema(_, schema):
            schema
        case let .table(_, schema, table):
            schema.map { "\($0).\(table)" } ?? table
        }
    }
}
