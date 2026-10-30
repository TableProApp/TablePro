//
//  StructureDefinitionFormView.swift
//  TablePro
//

import SwiftUI

// The selected column, index, foreign key or check constraint as a form: each field's name above a control the pane's
// width, the layout the Data view's inspector uses, since a label column leaves a 270pt pane too little room.
struct StructureDefinitionFormView: View {
    let editor: StructureDefinitionEditor
    let form: StructureInspectorForm
    let revision: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if form.isDeleted {
                    Label(
                        String(localized: "Marked for deletion. Undo or Undo Delete brings it back."),
                        systemImage: "trash"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("structure-inspector-deleted-note")
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(form.fields) { field in
                        if case .checkbox = StructureInspectorControl.resolve(field) {
                            control(for: field)
                        } else {
                            StructureInspectorRow(label: field.label, isModified: field.isModified) {
                                control(for: field)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalInset)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .controlSize(.small)
        .onAppear {
            // Reading the character sets is what a Charset or Collation menu opening does in the grid.
            guard form.section == .columns, form.isEditable else { return }
            editor.readCharacterSetCatalogIfNeeded()
        }
    }

    @ViewBuilder
    private func control(for field: StructureInspectorForm.Field) -> some View {
        let identifier = StructureInspectorPresentation.controlIdentifier(section: form.section, field: field.id)
        let value = field.value ?? ""
        switch StructureInspectorControl.resolve(field) {
        case .text:
            StructureInspectorTextField(
                label: field.label, value: value, revision: revision,
                onType: { type($0, into: field) }, onEnd: { editor.endInspectorTyping() }
            )
            .accessibilityLabel(field.label)
            .accessibilityIdentifier(identifier)
        case .multiline:
            StructureInspectorTextField(
                label: field.label, value: value, revision: revision, isMultiline: true,
                onType: { type($0, into: field) }, onEnd: { editor.endInspectorTyping() }
            )
            .accessibilityLabel(field.label)
            .accessibilityIdentifier(identifier)
        case .checkbox:
            Toggle(
                isOn: Binding(
                    get: { value == StructureRowProvider.booleanOptions[0] },
                    set: { isOn in
                        commit(isOn ? StructureRowProvider.booleanOptions[0] : StructureRowProvider.booleanOptions[1], to: field)
                    }
                )
            ) {
                Text(field.label)
                    .fontWeight(field.isModified ? .semibold : .regular)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(field.label)
            .accessibilityIdentifier(identifier)
        case .popUp(let choices):
            popUp(choices, field: field)
                .accessibilityLabel(field.label)
                .accessibilityIdentifier(identifier)
        case .comboBox(let choices):
            StructureInspectorSuggestionField(
                label: field.label,
                value: value,
                revision: revision,
                identifier: identifier,
                groups: choices.groups,
                onType: { type($0, into: field) },
                onPick: { commit($0, to: field) },
                onEnd: { editor.endInspectorTyping() }
            )
        case .typePicker:
            StructureInspectorTypeField(
                value: value,
                revision: revision,
                label: field.label,
                identifier: identifier,
                databaseType: editor.context.databaseType,
                scope: editor.context.scope,
                onType: { type($0, into: field) },
                onPick: { commit($0, to: field) },
                onEnd: { editor.endInspectorTyping() }
            )
        case .readOnly(let text):
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(field.label)
                .accessibilityValue(text)
                .accessibilityIdentifier(identifier)
        }
    }

    private func popUp(_ choices: StructureInspectorChoices, field: StructureInspectorForm.Field) -> some View {
        Picker(
            selection: Binding(
                get: { choices.selectedID ?? Self.noSelection },
                set: { id in
                    guard let value = choices.value(of: id) else { return }
                    commit(value, to: field)
                }
            )
        ) {
            ForEach(choices.groups) { group in
                if let header = group.header {
                    Section {
                        ForEach(group.items) { Text($0.title).tag($0.id) }
                    } header: {
                        Text(header)
                    }
                } else {
                    ForEach(group.items) { Text($0.title).tag($0.id) }
                }
            }
        } label: {
            Text(field.label)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize(horizontal: false, vertical: true)
    }

    // A tag no item carries, so a value the menu does not list shows nothing selected rather than another item.
    private static let noSelection = -1

    private func type(_ value: String, into field: StructureInspectorForm.Field) {
        editor.typeInspectorField(section: form.section, id: form.entityID, field: field.id, value: value)
    }

    private func commit(_ value: String, to field: StructureInspectorForm.Field) {
        guard value != (field.value ?? "") else { return }
        editor.commitInspectorField(section: form.section, id: form.entityID, field: field.id, value: value)
    }
}
