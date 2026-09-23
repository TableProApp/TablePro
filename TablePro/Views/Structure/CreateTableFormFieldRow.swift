//
//  CreateTableFormFieldRow.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct CreateTableFormFieldRow: View {
    internal let field: PluginFormField
    @Binding internal var value: String
    internal let message: String?
    internal let identifier: String

    internal var body: some View {
        control
            .accessibilityIdentifier(identifier)
        if let help = field.help {
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .text(let placeholder, _):
            TextField(field.label, text: $value, prompt: placeholder.map { Text($0) })
                .autocorrectionDisabled(true)
        case .integer(let defaultValue, _, _):
            TextField(field.label, text: $value, prompt: defaultValue.map { Text(String($0)) })
                .autocorrectionDisabled(true)
        case .picker(let options, _):
            Picker(field.label, selection: $value) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
        case .toggle:
            Toggle(field.label, isOn: isOn)
        @unknown default:
            TextField(field.label, text: $value)
        }
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { value == "true" },
            set: { value = $0 ? "true" : "false" }
        )
    }
}
