//
//  SetPickerView.swift
//  TablePro
//

import SwiftUI

internal struct SetPickerView: View {
    let context: FieldEditorContext
    let values: [String]
    var isPendingNull: Bool = false
    var isPendingDefault: Bool = false
    var onSetNull: (() -> Void)?
    var onSetDefault: (() -> Void)?

    @State private var isSetPopoverPresented = false

    var body: some View {
        let isNullValue = context.originalValue == nil && !isPendingDefault
        let displayLabel: String = {
            if isPendingNull || isNullValue { return "NULL" }
            if isPendingDefault { return "DEFAULT" }
            return context.value.wrappedValue.isEmpty
                ? String(localized: "No selection")
                : context.value.wrappedValue
        }()

        Menu {
            Button { isSetPopoverPresented = true } label: {
                Text("Edit Values...")
            }
            if onSetNull != nil || onSetDefault != nil {
                Divider()
                if let onSetNull {
                    Button("Set NULL", action: onSetNull)
                }
                if let onSetDefault {
                    Button("Set DEFAULT", action: onSetDefault)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayLabel)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
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
