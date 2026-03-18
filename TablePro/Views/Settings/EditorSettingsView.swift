//
//  EditorSettingsView.swift
//  TablePro
//
//  Settings for SQL editor behavior (fonts moved to theme)
//

import SwiftUI

struct EditorSettingsView: View {
    @Binding var settings: EditorSettings

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Highlight current line", isOn: $settings.highlightCurrentLine)
                Toggle("Auto-indent", isOn: $settings.autoIndent)
                Toggle("Word wrap", isOn: $settings.wordWrap)
            }

            Section("Editing") {
                Picker("Tab width:", selection: $settings.tabWidth) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("8 spaces").tag(8)
                }
                Toggle("Vim mode", isOn: $settings.vimModeEnabled)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    EditorSettingsView(settings: .constant(.default))
        .frame(width: 450, height: 250)
}
