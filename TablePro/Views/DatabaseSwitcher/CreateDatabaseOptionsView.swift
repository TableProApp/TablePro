//
//  CreateDatabaseOptionsView.swift
//  TablePro
//
//  The driver's own create-database options, wherever a database is created.
//
//  Two callers: the New Database sheet, and Duplicate Database, which offers the
//  same charset and collation so a duplicate does not silently take the server's
//  default instead of the source's.
//

import SwiftUI

internal struct CreateDatabaseOptionsView: View {
    internal let spec: CreateDatabaseFormSpec
    @Binding internal var values: [String: String]

    internal var body: some View {
        Group {
            ForEach(spec.textInputs) { input in
                TextField(
                    input.label,
                    text: textBinding(for: input),
                    prompt: input.placeholder.map { Text($0) }
                )
            }
            ForEach(CreateDatabaseFormRules.visibleFields(in: spec, values: values)) { field in
                picker(for: field)
                    .pickerStyle(.menu)
            }
            if let footnote = spec.footnote {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func textBinding(for input: CreateDatabaseFormSpec.TextInput) -> Binding<String> {
        Binding<String>(
            get: { values[input.id] ?? "" },
            set: { values[input.id] = $0 }
        )
    }

    private func picker(for field: CreateDatabaseFormSpec.Field) -> some View {
        let sources = CreateDatabaseFormRules.groupSourceFieldIds(in: spec)
        let binding = Binding<String>(
            get: { values[field.id] ?? "" },
            set: { newValue in
                var updated = values
                updated[field.id] = newValue
                guard sources.contains(field.id) else {
                    values = updated
                    return
                }
                values = CreateDatabaseFormRules.resettingGroupedFields(
                    after: field.id, in: spec, values: updated
                )
            }
        )
        return Picker(field.label, selection: binding) {
            ForEach(CreateDatabaseFormRules.filteredOptions(for: field, values: values), id: \.value) { option in
                Text(CreateDatabaseFormRules.displayLabel(for: option)).tag(option.value)
            }
        }
    }
}
