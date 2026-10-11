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
        control
            .accessibilityIdentifier("connection-field-\(field.id)")
    }

    @ViewBuilder private var control: some View {
        if field.dynamicOptions == .awsProfiles {
            LabeledContent(field.label) {
                AWSProfileField(placeholder: field.placeholder, value: $value)
            }
        } else {
            defaultControl
        }
    }

    @ViewBuilder private var defaultControl: some View {
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
                text: $value,
                prompt: field.placeholder.isEmpty ? nil : Text(field.placeholder)
            )
            .onChange(of: value) { newValue in
                let sanitized = ConnectionField.IntRange.wholeNumbers.fieldText(sanitizing: newValue)
                guard sanitized != newValue else { return }
                value = sanitized
            }
        case .toggle:
            Toggle(
                field.label,
                isOn: Binding(
                    get: { value == "true" },
                    set: { value = $0 ? "true" : "false" }
                )
            )
        case .stepper(let range):
            ConnectionStepperField(
                label: field.label,
                range: range,
                defaultValue: field.defaultValue,
                value: $value
            )
        case .hostList:
            EmptyView()
        }
    }
}
