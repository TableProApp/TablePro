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
            if let stored = Self.unrecognizedValue(of: context.valueState) {
                Text(verbatim: stored).tag(stored)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(context.isReadOnly)
    }

    // The selection follows `valueState`, so a value just picked on a NULL column shows instead of snapping back to NULL.
    private var selectionBinding: Binding<String> {
        Binding(
            get: {
                FieldPickerSentinel.tag(for: context.valueState)
                    ?? Self.normalized(context.valueState.editableText)
            },
            set: { newValue in
                FieldPickerSentinel.choose(newValue, onSetNull: onSetNull, onSetDefault: onSetDefault) {
                    context.value.wrappedValue = $0
                }
            }
        )
    }

    internal static func normalized(_ value: String) -> String {
        guard let isTrue = StoredBoolean.value(of: value) else { return value.isEmpty ? "0" : value }
        return isTrue ? "1" : "0"
    }

    // A TINYINT(1) can hold 2, which is neither choice, so the picker shows it rather than reading it as false.
    internal static func unrecognizedValue(of state: FieldValueState) -> String? {
        guard FieldPickerSentinel.tag(for: state) == nil else { return nil }
        let text = state.editableText
        guard !text.isEmpty, StoredBoolean.value(of: text) == nil else { return nil }
        return text
    }
}
