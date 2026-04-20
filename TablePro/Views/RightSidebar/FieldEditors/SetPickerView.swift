//
//  SetPickerView.swift
//  TablePro
//

import SwiftUI

internal struct SetPickerView: View {
    let context: FieldEditorContext
    let values: [String]

    @State private var isSetPopoverPresented = false

    var body: some View {
        let displayLabel = context.value.wrappedValue.isEmpty
            ? String(localized: "No selection")
            : context.value.wrappedValue

        Button {
            isSetPopoverPresented = true
        } label: {
            Text(displayLabel)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        .disabled(context.isReadOnly)
        .popover(isPresented: $isSetPopoverPresented) {
            SetPopoverContentView(
                allowedValues: values,
                initialSelections: parseSetSelections(from: context.value.wrappedValue, allowed: values),
                onCommit: { result in
                    context.value.wrappedValue = result ?? ""
                },
                onDismiss: {
                    isSetPopoverPresented = false
                }
            )
        }
    }

    private func parseSetSelections(from value: String, allowed: [String]) -> [String: Bool] {
        let selected = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var dict: [String: Bool] = [:]
        for val in allowed {
            dict[val] = selected.contains(val)
        }
        return dict
    }
}
