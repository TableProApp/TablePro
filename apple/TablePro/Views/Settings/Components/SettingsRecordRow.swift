import SwiftUI

struct SettingsRecordRemoval {
    let menuTitle: String
    let actionName: String
    let action: () -> Void

    static func remove(_ action: @escaping () -> Void) -> SettingsRecordRemoval {
        SettingsRecordRemoval(menuTitle: String(localized: "Remove…"), actionName: String(localized: "Remove"), action: action)
    }

    static func delete(_ action: @escaping () -> Void) -> SettingsRecordRemoval {
        SettingsRecordRemoval(menuTitle: String(localized: "Delete…"), actionName: String(localized: "Delete"), action: action)
    }
}

struct SettingsRecordRow<Trailing: View>: View {
    private struct EditActions {
        let onEdit: () -> Void
        let onDuplicate: (() -> Void)?
        let removal: SettingsRecordRemoval?
        let identifier: String?
    }

    private let title: String
    private let subtitle: String?
    private let value: String?
    private let trailing: Trailing
    private var editActions: EditActions?

    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.trailing = trailing()
    }

    func infoButton(
        onEdit: @escaping () -> Void,
        onDuplicate: (() -> Void)? = nil,
        removal: SettingsRecordRemoval? = nil,
        identifier: String? = nil
    ) -> SettingsRecordRow {
        var row = self
        row.editActions = EditActions(onEdit: onEdit, onDuplicate: onDuplicate, removal: removal, identifier: identifier)
        return row
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                if let editActions {
                    Button(String(localized: "Edit"), action: editActions.onEdit)
                    otherActions(editActions)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(verbatim: value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            trailing

            if let editActions {
                Button(action: editActions.onEdit) {
                    Image(systemName: "info.circle")
                        .frame(width: 20, height: 20, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(String(localized: "Edit"))
                .accessibilityLabel(String(format: String(localized: "Edit %@"), title))
                .accessibilityIdentifier(editActions.identifier ?? "")
                .accessibilityActions {
                    otherActions(editActions)
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(EditMenu(actions: editActions))
        .accessibilityElement(children: .contain)
    }

    // An empty inner context menu would shadow one the caller attaches to the row.
    private struct EditMenu: ViewModifier {
        let actions: EditActions?

        func body(content: Content) -> some View {
            if let actions {
                content.contextMenu {
                    Button(String(localized: "Edit…"), action: actions.onEdit)
                    if let onDuplicate = actions.onDuplicate {
                        Button(String(localized: "Duplicate"), action: onDuplicate)
                    }
                    if let removal = actions.removal {
                        Divider()
                        Button(removal.menuTitle, role: .destructive, action: removal.action)
                    }
                }
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private func otherActions(_ actions: EditActions) -> some View {
        if let onDuplicate = actions.onDuplicate {
            Button(String(localized: "Duplicate"), action: onDuplicate)
        }
        if let removal = actions.removal {
            Button(removal.actionName, action: removal.action)
        }
    }
}
