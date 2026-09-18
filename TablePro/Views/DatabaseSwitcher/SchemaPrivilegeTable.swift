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
/// The privilege set is the engine's, so the columns are built from it rather than written out.
/// `TableColumnForEach` is the native way to say that and it is macOS 14.4, so macOS 13 gets a
/// `Grid` laid out to the same shape: same order, same cells, same accessibility, drawn rather
/// than measured by AppKit. Both arms read `cell(_:row:)`, so a change to what a cell offers
/// lands in both at once and only the surrounding metrics differ.
struct SchemaPrivilegeTable: View {
    @ObservedObject var model: SchemaEditorViewModel

    var body: some View {
        content
            .accessibilityIdentifier("schema-privilege-table")
    }

    @ViewBuilder
    private var content: some View {
        if #available(macOS 14.4, *) {
            nativeTable
        } else {
            gridFallback
        }
    }

    /// A real `Table`, so the column headings, the row striping and the metrics are AppKit's
    /// rather than hand-drawn.
    @available(macOS 14.4, *)
    private var nativeTable: some View {
        Table(model.granteeRows) {
            TableColumn(String(localized: "Role")) { row in
                roleLabel(row)
            }
            .width(min: Self.roleColumnMinWidth, ideal: Self.roleColumnIdealWidth)

            TableColumnForEach(model.privileges, id: \.name) { privilege in
                TableColumn(privilege.label) { row in
                    cell(privilege, row: row)
                }
                .width(min: Self.privilegeColumnMinWidth, ideal: Self.privilegeColumnIdealWidth)
            }
        }
        .tableStyle(.inset)
    }

    /// The same grid without AppKit's table chrome: headings and striping are drawn here, and the
    /// columns hold their width instead of being resizable.
    private var gridFallback: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow {
                    Text("Role")
                        .gridColumnAlignment(.leading)
                        .frame(minWidth: Self.roleColumnMinWidth, alignment: .leading)

                    ForEach(model.privileges, id: \.name) { privilege in
                        Text(privilege.label)
                            .frame(width: Self.privilegeColumnIdealWidth, alignment: .center)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

                Divider()
                    .gridCellUnsizedAxes(.horizontal)

                ForEach(Array(model.granteeRows.enumerated()), id: \.element.id) { offset, row in
                    GridRow {
                        roleLabel(row)
                            .frame(minWidth: Self.roleColumnMinWidth, alignment: .leading)

                        ForEach(model.privileges, id: \.name) { privilege in
                            cell(privilege, row: row)
                                .frame(width: Self.privilegeColumnIdealWidth, alignment: .center)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(offset.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    private func roleLabel(_ row: SchemaGranteeRow) -> some View {
        Text(row.displayName)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(row.locked.isEmpty ? "" : String(localized: "Granted by another role"))
    }

    /// A cell another role granted is shown checked and dimmed. `REVOKE` removes only what the
    /// executing role granted, so offering it would run a statement that succeeds, changes nothing,
    /// and reports the access as gone while it is still there.
    private func cell(_ privilege: PluginPrivilegeDescriptor, row: SchemaGranteeRow) -> some View {
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

    private static let roleColumnMinWidth: CGFloat = 120
    private static let roleColumnIdealWidth: CGFloat = 200
    private static let privilegeColumnMinWidth: CGFloat = 56
    private static let privilegeColumnIdealWidth: CGFloat = 72
}
