//
//  SchemaPrivilegeTable.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Who holds what on one schema: a row per role, a checkbox per privilege.
///
/// The transpose of `PrivilegeChecklistView`, which asks the same question of one role across
/// every object. Checkboxes rather than switches, which is what the HIG asks for a grid of
/// independent on-off settings, and a row the user did not touch emits neither a GRANT nor a
/// REVOKE.
///
/// A `Grid` rather than a `Table`, because the privilege set is the engine's and a `Table` cannot
/// take a dynamic column count before macOS 14.4 (`TableColumnForEach`), which is past our
/// deployment target. `Grid` aligns the columns for real, so the headings sit over their boxes.
struct SchemaPrivilegeTable: View {
    let model: SchemaEditorViewModel

    private let roleColumnWidth: CGFloat = 180
    private let privilegeColumnWidth: CGFloat = 72

    var body: some View {
        if model.privileges.isEmpty {
            ContentUnavailableView(
                String(localized: "No Privileges"),
                systemImage: "lock",
                description: Text("No privileges can be granted on a schema here.")
            )
        } else if model.granteeRows.isEmpty {
            ContentUnavailableView(
                String(localized: "No Roles"),
                systemImage: "person.2",
                description: Text("Add a role to grant it access to this schema.")
            )
        } else {
            matrix
        }
    }

    private var matrix: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(model.granteeRows) { row in
                        GridRow {
                            Text(row.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: roleColumnWidth, alignment: .leading)
                            ForEach(model.privileges, id: \.name) { privilege in
                                checkbox(privilege, row: row)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .accessibilityIdentifier("schema-privilege-table")
    }

    private var headerRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
            GridRow {
                Text(String(localized: "Role"))
                    .frame(width: roleColumnWidth, alignment: .leading)
                ForEach(model.privileges, id: \.name) { privilege in
                    Text(privilege.label)
                        .frame(width: privilegeColumnWidth, alignment: .center)
                }
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A cell another role granted is shown checked and dimmed. `REVOKE` removes only what the
    /// executing role granted, so offering it would run a statement that succeeds, changes nothing,
    /// and reports the access as gone while it is still there.
    private func checkbox(_ privilege: PluginPrivilegeDescriptor, row: SchemaGranteeRow) -> some View {
        Toggle(
            privilege.label,
            isOn: Binding(
                get: { row.holds(privilege.name) },
                set: { model.setPrivilege(privilege.name, granted: $0, for: row.grantee) }
            )
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!row.canEdit(privilege.name))
        .frame(width: privilegeColumnWidth, alignment: .center)
        .help(row.canEdit(privilege.name) ? "" : String(localized: "Granted by another role"))
        .accessibilityLabel(
            Text(
                String(
                    format: row.canEdit(privilege.name)
                        ? String(localized: "%1$@ for %2$@")
                        : String(localized: "%1$@ for %2$@, granted by another role"),
                    privilege.label,
                    row.displayName
                )
            )
        )
    }
}
