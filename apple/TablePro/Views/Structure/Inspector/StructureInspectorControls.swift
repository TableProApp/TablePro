//
//  StructureInspectorControls.swift
//  TablePro
//

import SwiftUI

// A definition field's text. Every keystroke is staged at once, the way the table comment's field is, so Save, Refresh
// and the close prompt always see what is typed; the editor folds the run into one undo step, ended by Return or by
// focus leaving.
struct StructureInspectorTextField: View {
    let label: String
    let value: String
    let revision: Int
    var isMultiline = false
    // Moved by a pick from a menu beside the field: the field shows the picked value even while it has focus.
    var resetToken = 0
    let onType: (String) -> Void
    let onEnd: () -> Void

    @State private var draft = ""
    // What the field last wrote or was synced from, so only typing writes, never a value the model moved under it.
    @State private var base = ""
    // The stored value, so leaving a field whose write was refused puts it back.
    @State private var latest = ""
    @State private var hasSeeded = false
    @FocusState private var isFocused: Bool

    private struct Sync: Equatable {
        let value: String
        let revision: Int
    }

    var body: some View {
        field
            .textFieldStyle(.squareBorder)
            .autocorrectionDisabled(true)
            .focused($isFocused)
            .onAppear(perform: seed)
            .onChange(of: Sync(value: value, revision: revision)) { sync in
                latest = sync.value
                guard !isFocused else { return }
                draft = sync.value
                base = sync.value
            }
            .onChange(of: draft) { text in
                guard hasSeeded, isFocused, text != base else { return }
                base = text
                onType(text)
            }
            .onChange(of: isFocused) { focused in
                guard !focused else { return }
                onEnd()
                draft = latest
                base = latest
            }
            .onChange(of: resetToken) { _ in
                draft = value
                base = value
                latest = value
            }
            .onSubmit(onEnd)
            .onDisappear(perform: onEnd)
    }

    // The field's name is above it, so an empty field shows no placeholder.
    @ViewBuilder
    private var field: some View {
        if isMultiline {
            TextField(text: $draft, prompt: Text(verbatim: ""), axis: .vertical) { Text(label) }
                .lineLimit(2...6)
                .labelsHidden()
        } else {
            TextField(text: $draft, prompt: Text(verbatim: "")) { Text(label) }
                .labelsHidden()
        }
    }

    private func seed() {
        guard !hasSeeded else { return }
        hasSeeded = true
        draft = value
        base = value
        latest = value
    }
}

// Free text with the engine's types and the database's own types to pick from, grouped as the grid's type picker
// groups them.
struct StructureInspectorTypeField: View {
    let value: String
    let revision: Int
    let label: String
    let identifier: String
    let databaseType: DatabaseType
    let scope: DatabaseScope?
    let onType: (String) -> Void
    let onPick: (String) -> Void
    let onEnd: () -> Void

    var body: some View {
        UserDefinedTypeAwarePicker(scope: scope) { userDefinedTypes in
            StructureInspectorSuggestionField(
                label: label,
                value: value,
                revision: revision,
                identifier: identifier,
                groups: Self.groups(userDefinedTypes: userDefinedTypes, databaseType: databaseType),
                onType: onType,
                onPick: onPick,
                onEnd: onEnd
            )
        }
    }

    static func groups(userDefinedTypes: [String], databaseType: DatabaseType) -> [StructureInspectorChoices.ItemGroup] {
        var categories = PluginManager.shared.columnTypesByCategory(for: databaseType)
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, types: $0.value) }
        if !userDefinedTypes.isEmpty {
            categories.insert((name: String(localized: "User-Defined"), types: userDefinedTypes), at: 0)
        }
        var nextID = 0
        var groups: [StructureInspectorChoices.ItemGroup] = []
        for (offset, category) in categories.enumerated() {
            var items: [StructureInspectorChoices.Item] = []
            for type in category.types {
                items.append(StructureInspectorChoices.Item(id: nextID, title: type, value: type))
                nextID += 1
            }
            groups.append(StructureInspectorChoices.ItemGroup(id: offset, header: category.name, items: items))
        }
        return groups
    }
}

// A text field with its common values one click away, the way a combo box offers them. A SwiftUI field and a
// pull-down menu, so it draws like every other field in the pane; an AppKit combo box keeps the pre-glass bezel.
struct StructureInspectorSuggestionField: View {
    let label: String
    let value: String
    let revision: Int
    let identifier: String
    let groups: [StructureInspectorChoices.ItemGroup]
    let onType: (String) -> Void
    let onPick: (String) -> Void
    let onEnd: () -> Void

    @State private var pickRevision = 0

    var body: some View {
        HStack(spacing: 4) {
            StructureInspectorTextField(
                label: label, value: value, revision: revision, resetToken: pickRevision, onType: onType, onEnd: onEnd
            )
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            Menu {
                ForEach(groups) { group in
                    if let header = group.header {
                        Section(header) { items(group) }
                    } else {
                        items(group)
                    }
                }
            } label: {
                Label(String(format: String(localized: "Choose %@"), label), systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(format: String(localized: "Choose %@"), label))
            .accessibilityIdentifier("\(identifier)-choices")
        }
    }

    // A pick is its own undo step and replaces whatever is typed in the field.
    private func items(_ group: StructureInspectorChoices.ItemGroup) -> some View {
        ForEach(group.items) { item in
            Button(item.title) {
                pickRevision &+= 1
                guard item.value != value else { return }
                onPick(item.value)
            }
        }
    }
}

// One field: its name above, the control the pane's full width below, so every field shares the pane's leading edge
// as the Data view's inspector and the statistics do. Modified settings read bold, the way Xcode marks them.
struct StructureInspectorRow<Control: View>: View {
    let label: String
    var isModified = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .fontWeight(isModified ? .semibold : .regular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The inspector's section title, the style the table statistics below it use.
struct StructureInspectorSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct StructureInspectorFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
