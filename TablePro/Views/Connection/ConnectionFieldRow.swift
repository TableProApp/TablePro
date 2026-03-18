//
//  ConnectionFieldRow.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionFieldRow: View {
    let field: ConnectionField
    @Binding var value: String

    var body: some View {
        switch field.fieldType {
        case .text:
            TextField(
                field.label,
                text: $value,
                prompt: field.placeholder.isEmpty ? nil : Text(field.placeholder)
            )
        case .secure:
            SecureField(
                field.label,
                text: $value,
                prompt: field.placeholder.isEmpty ? nil : Text(field.placeholder)
            )
        case .dropdown(let options):
            Picker(field.label, selection: $value) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .number:
            TextField(
                field.label,
                text: Binding(
                    get: { value },
                    set: { newValue in
                        value = String(newValue.unicodeScalars.filter {
                            CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "."
                        })
                    }
                ),
                prompt: field.placeholder.isEmpty ? nil : Text(field.placeholder)
            )
        case .toggle:
            Toggle(
                field.label,
                isOn: Binding(
                    get: { value == "true" },
                    set: { value = $0 ? "true" : "false" }
                )
            )
        case .stepper(let range):
            Stepper(
                value: Binding(
                    get: { Int(value) ?? range.lowerBound },
                    set: { value = String($0) }
                ),
                in: range.closedRange
            ) {
                Text("\(field.label): \(Int(value) ?? range.lowerBound)")
            }
        }
    }
}
