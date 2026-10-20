//
//  SuggestionComboBox.swift
//  TablePro
//

import AppKit
import SwiftUI

// AppKit on purpose: SwiftUI has no editable field with a suggestion list before macOS 15.
struct SuggestionComboBox: NSViewRepresentable {
    let suggestions: @MainActor () -> [String]
    var placeholder = ""
    var controlSize: NSControl.ControlSize = .regular
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    @Binding var value: String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = false
        comboBox.controlSize = controlSize
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        if !placeholder.isEmpty {
            comboBox.placeholderString = placeholder
        }
        if let accessibilityLabel {
            comboBox.setAccessibilityLabel(accessibilityLabel)
        }
        if let accessibilityIdentifier {
            comboBox.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        comboBox.addItems(withObjectValues: suggestions())
        comboBox.stringValue = value
        comboBox.delegate = context.coordinator
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.value = $value
        if comboBox.stringValue != value {
            comboBox.stringValue = value
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var value: Binding<String>

        init(value: Binding<String>) {
            self.value = value
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            value.wrappedValue = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            DispatchQueue.main.async {
                if let selected = comboBox.objectValueOfSelectedItem as? String {
                    self.value.wrappedValue = selected
                }
            }
        }
    }
}
