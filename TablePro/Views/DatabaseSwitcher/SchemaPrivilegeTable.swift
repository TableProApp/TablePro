//
//  SchemaPrivilegeTable.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Who holds what on one schema: a row per role, a checkbox column per privilege.
///
/// The transpose of `PrivilegeChecklistView`, which asks the same question of one role across
/// every object. Checkboxes rather than switches, which is what the HIG asks for a grid of
/// independent on-off settings.
///
/// A real `Table`, so the column headings, the row striping and the metrics are AppKit's rather
/// than hand-drawn. The privilege set is the engine's, so the columns come from
/// `TableColumnForEach`; that is what puts the app's floor at macOS 14.4.
struct SchemaPrivilegeTable: View {
    let model: SchemaEditorViewModel

    var body: some View {
        Table(model.granteeRows) {
            TableColumn(String(localized: "Role")) { row in
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.locked.isEmpty ? "" : String(localized: "Granted by another role"))
            }
            .width(min: 120, ideal: 200)

            TableColumnForEach(model.privileges, id: \.name) { privilege in
                TableColumn(privilege.label) { row in
                    checkbox(privilege, row: row)
                }
                .width(min: 56, ideal: 72)
            }
        }
        .tableStyle(.inset)
        .accessibilityIdentifier("schema-privilege-table")
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
