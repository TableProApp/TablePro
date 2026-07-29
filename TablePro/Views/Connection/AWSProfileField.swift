import AppKit
import SwiftUI
import TableProPluginKit

struct AWSProfileField: NSViewRepresentable {
    let placeholder: String
    @Binding var value: String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = false
        comboBox.controlSize = .small
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        if !placeholder.isEmpty {
            comboBox.placeholderString = placeholder
        }
        comboBox.addItems(withObjectValues: Self.discoveredProfiles())
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

    private static func discoveredProfiles() -> [String] {
        AWSConfigFile.discoverProfiles(
            configContents: AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath),
            credentialsContents: AWSConfigFile.readFile(AWSConfigFile.defaultCredentialsPath)
        )
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
