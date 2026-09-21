//
//  ConnectionStepperField.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionStepperField: View {
    let label: String
    let range: ConnectionField.IntRange
    let defaultValue: String?
    @Binding var value: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, text: $value, prompt: Text(verbatim: String(emptyValue)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                Stepper(label, value: steppedValue, in: range.closedRange)
                    .labelsHidden()
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: value) { newValue in
            sanitize(newValue)
        }
    }

    private var emptyValue: Int {
        range.stepperValue(fromFieldText: "", defaultValue: defaultValue)
    }

    private var steppedValue: Binding<Int> {
        Binding(
            get: { range.stepperValue(fromFieldText: value, defaultValue: defaultValue) },
            set: { value = String($0) }
        )
    }

    private func sanitize(_ text: String) {
        let sanitized = range.fieldText(sanitizing: text)
        guard sanitized != text else { return }
        value = sanitized
    }
}
