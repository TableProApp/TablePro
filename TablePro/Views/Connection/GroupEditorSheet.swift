//
//  GroupEditorSheet.swift
//  TablePro
//

import SwiftUI

internal enum GroupEditorMode {
    case create(parentId: UUID?)
    case edit(ConnectionGroup)
}

internal struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionGroupFields
    @State private var errorMessage: String?

    private let mode: GroupEditorMode
    private let groups: [ConnectionGroup]
    /// Throwing, because the store refuses a duplicate sibling name, a cycle and a group nested
    /// past the cap. A sheet that dismissed on the attempt left the caller holding the id of a
    /// group that was never saved.
    private let onSave: (ConnectionGroupFields) throws -> Void

    internal init(
        mode: GroupEditorMode,
        groups: [ConnectionGroup],
        onSave: @escaping (ConnectionGroupFields) throws -> Void
    ) {
        self.mode = mode
        self.groups = groups
        self.onSave = onSave
        switch mode {
        case .create(let parentId):
            _draft = State(initialValue: ConnectionGroupFields(name: "", parentId: parentId))
        case .edit(let group):
            _draft = State(initialValue: ConnectionGroupFields(group))
        }
    }

    internal var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            TextField("Group name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("group-editor-name")

            VStack(alignment: .leading, spacing: 12) {
                field(String(localized: "Icon")) {
                    SymbolWell(
                        iconName: $draft.iconName,
                        subject: .group,
                        color: draft.color,
                        accessibilityIdentifier: "group-editor-icon"
                    )
                }

                field(String(localized: "Color")) {
                    ColorPaletteView(selectedColor: $draft.color, includesNone: true, size: .compact)
                }

                let entries = parentEntries
                if entries.count > 1 {
                    field(String(localized: "Parent Group")) {
                        GroupPopUpButton(
                            entries: entries,
                            selection: $draft.parentId,
                            accessibilityLabel: String(localized: "Parent Group")
                        )
                        .fixedSize()
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(saveTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: draft) { _ in errorMessage = nil }
        .onExitCommand {
            dismiss()
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var title: String {
        switch mode {
        case .create: return String(localized: "New Group")
        case .edit: return String(localized: "Edit Group")
        }
    }

    private var saveTitle: String {
        switch mode {
        case .create: return String(localized: "Create")
        case .edit: return String(localized: "Save")
        }
    }

    private var parentEntries: [GroupMenuEntry] {
        let noneTitle = String(localized: "None (Top Level)")
        switch mode {
        case .create:
            return GroupMenuEntries.forParent(groups: groups, noneTitle: noneTitle)
        case .edit(let group):
            return GroupMenuEntries.forMoving(groupId: group.id, groups: groups, noneTitle: noneTitle)
        }
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        var saved = draft
        saved.name = trimmedName
        do {
            try onSave(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
