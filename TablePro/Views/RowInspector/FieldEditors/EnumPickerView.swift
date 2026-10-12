//
//  EnumPickerView.swift
//  TablePro
//

import SwiftUI

internal struct EnumPickerView: View {
    internal let context: FieldEditorContext
    internal let values: [String]
    internal var onSetNull: (() -> Void)?
    internal var onSetDefault: (() -> Void)?

    var body: some View {
        Picker(selection: selectionBinding) {
            FieldPickerStateRows(
                state: context.valueState,
                onSetNull: context.canMutate ? onSetNull : nil,
                onSetDefault: context.canMutate ? onSetDefault : nil
            )
            ForEach(values, id: \.self) { value in
                Text(value).tag(value)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(context.isReadOnly)
    }

    /// Reads `valueState`, so a multi-row selection whose rows disagree shows "Multiple values"
    /// rather than NULL, and a value picked on a NULL column stays picked.
    private var selectionBinding: Binding<String> {
        Binding(
            get: { FieldPickerSentinel.tag(for: context.valueState) ?? context.valueState.editableText },
            set: { newValue in
                FieldPickerSentinel.choose(newValue, onSetNull: onSetNull, onSetDefault: onSetDefault) {
                    context.value.wrappedValue = $0
                }
            }
        )
    }
}
