//
//  CreateTableFormSectionView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct CreateTableFormSectionView: View {
    @ObservedObject internal var draft: CreateTableDraft
    internal let form: CreateTableFormState
    internal let section: PluginFormSection
    internal let footnote: String?

    internal var body: some View {
        Section {
            if section.isRepeating {
                repeatingRows
            } else {
                ForEach(form.visibleFields(in: section, at: .topLevel), id: \.id) { field in
                    CreateTableFormFieldRow(
                        field: field,
                        value: binding(for: field, at: .topLevel),
                        message: form.inlineMessage(for: field.id, at: .topLevel),
                        identifier: "create-table-form-field-\(field.id)"
                    )
                }
            }
        } header: {
            if let title = section.title {
                Text(title)
            }
        } footer: {
            if let footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var repeatingRows: some View {
        ForEach(Array(form.entries(in: section.id).enumerated()), id: \.element.id) { offset, entry in
            let location = CreateTableFormState.Location.entry(sectionId: section.id, entryId: entry.id)
            let title = CreateTableFormState.entryTitle(number: offset + 1)
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    removeEntry(entry.id)
                } label: {
                    Label(String(localized: "Remove"), systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Remove"))
                .accessibilityLabel(String(format: String(localized: "Remove %@"), title))
                .accessibilityIdentifier("create-table-form-remove-\(section.id)-\(offset)")
            }
            ForEach(form.visibleFields(in: section, at: location), id: \.id) { field in
                CreateTableFormFieldRow(
                    field: field,
                    value: binding(for: field, at: location),
                    message: form.inlineMessage(for: field.id, at: location),
                    identifier: "create-table-form-field-\(section.id)-\(offset)-\(field.id)"
                )
            }
        }
        Button(action: addEntry) {
            Label(section.addLabel ?? String(localized: "Add"), systemImage: "plus")
        }
        .disabled(!form.canAddEntry(to: section.id))
        .accessibilityIdentifier("create-table-form-add-\(section.id)")
    }

    private func binding(
        for field: PluginFormField,
        at location: CreateTableFormState.Location
    ) -> Binding<String> {
        Binding(
            get: { draft.form?.value(of: field.id, at: location) ?? "" },
            set: { draft.form?.setValue($0, of: field.id, at: location) }
        )
    }

    private func addEntry() {
        draft.form?.addEntry(to: section.id)
    }

    private func removeEntry(_ entryId: UUID) {
        draft.form?.removeEntry(entryId, from: section.id)
    }
}
