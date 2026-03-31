//
//  BooleanPickerView.swift
//  TablePro
//

import SwiftUI

internal struct BooleanPickerView: View {
    let context: FieldEditorContext

    var body: some View {
        dropdownField(
            label: normalizeBooleanValue(context.value.wrappedValue) == "1" ? "true" : "false",
            isDisabled: context.isReadOnly
        ) {
            Button("true") { context.value.wrappedValue = "1" }
            Button("false") { context.value.wrappedValue = "0" }
        }
    }

    private func normalizeBooleanValue(_ val: String) -> String {
        let lower = val.lowercased()
        if lower == "true" || lower == "1" || lower == "t" || lower == "yes" {
            return "1"
        }
        return "0"
    }
}
