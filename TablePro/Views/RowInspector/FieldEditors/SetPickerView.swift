//
//  SetPickerView.swift
//  TablePro
//

import SwiftUI

internal struct SetPickerView: View {
    internal let context: FieldEditorContext
    internal let values: [String]
    internal var onSetNull: (() -> Void)?
    internal var onSetDefault: (() -> Void)?

    @State private var isSetPopoverPresented = false

    var body: some View {
        Menu {
            Button {
                isSetPopoverPresented = true
            } label: {
                Text("Edit Values…")
            }
            if context.canMutate, onSetNull != nil || onSetDefault != nil {
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
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                    .foregroundStyle(context.valueState.placeholder == nil ? .primary : .secondary)
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
                initialSelections: Self.selections(from: context.valueState.editableText, allowed: values),
                onCommit: { context.value.wrappedValue = $0 ?? "" },
                onDismiss: { isSetPopoverPresented = false }
            )
        }
    }

    /// Follows `valueState`, so a set the user has just edited on a NULL column shows what they
    /// chose, and a multi-row selection that disagrees says so instead of reporting NULL.
    private var displayLabel: String {
        if let placeholder = context.valueState.placeholder { return placeholder }
        let text = context.valueState.editableText
        return text.isEmpty ? String(localized: "No selection") : text
    }

    private static func selections(from value: String, allowed: [String]) -> [String: Bool] {
        let selected = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return allowed.reduce(into: [:]) { result, candidate in
            result[candidate] = selected.contains(candidate)
        }
    }
}
