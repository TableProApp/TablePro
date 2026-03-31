//
//  EnumPickerView.swift
//  TablePro
//

import SwiftUI

internal struct EnumPickerView: View {
    let context: FieldEditorContext
    let values: [String]

    var body: some View {
        let label = context.value.wrappedValue.isEmpty ? (values.first ?? "") : context.value.wrappedValue
        dropdownField(label: label, isDisabled: context.isReadOnly) {
            ForEach(values, id: \.self) { val in
                Button(val) { context.value.wrappedValue = val }
            }
        }
    }
}
