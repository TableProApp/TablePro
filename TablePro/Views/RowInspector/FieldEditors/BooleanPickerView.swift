//
//  BooleanPickerView.swift
//  TablePro
//

import SwiftUI

internal struct BooleanPickerView: View {
    internal let context: FieldEditorContext
    internal var onSetNull: (() -> Void)?
    internal var onSetDefault: (() -> Void)?

    var body: some View {
        Picker(selection: selectionBinding) {
            FieldPickerStateRows(
                state: context.valueState,
                onSetNull: context.canMutate ? onSetNull : nil,
                onSetDefault: context.canMutate ? onSetDefault : nil
            )
            Text("true").tag("1")
            Text("false").tag("0")
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(context.isReadOnly)
    }

    /// The selection follows `valueState`, so a value the user has just picked on a NULL column
    /// shows that value. Reading the stored value instead is what made the control snap back to
    /// NULL over a recorded edit.
    private var selectionBinding: Binding<String> {
        Binding(
            get: {
                FieldPickerSentinel.tag(for: context.valueState)
                    ?? Self.normalized(context.valueState.editableText)
            },
            set: { newValue in
                switch newValue {
                case FieldPickerSentinel.null: onSetNull?()
                case FieldPickerSentinel.defaultValue: onSetDefault?()
                case FieldPickerSentinel.multiple: break
                default: context.value.wrappedValue = newValue
                }
            }
        )
    }

    private static func normalized(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "true" || lower == "1" || lower == "t" || lower == "yes" {
            return "1"
        }
        return "0"
    }
}
