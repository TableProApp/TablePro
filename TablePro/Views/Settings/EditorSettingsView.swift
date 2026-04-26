//
//  EditorSettingsView.swift
//  TablePro
//

import SwiftUI

struct EditorSettingsView: View {
    @Binding var settings: EditorSettings
    @Binding var dataGridSettings: DataGridSettings

    var body: some View {
        Form {
            Section("SQL Editor") {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Highlight current line", isOn: $settings.highlightCurrentLine)
                Toggle("Word wrap", isOn: $settings.wordWrap)
                Picker("Tab width:", selection: $settings.tabWidth) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("8 spaces").tag(8)
                }
                Toggle("Auto-uppercase keywords", isOn: $settings.uppercaseKeywords)
                Toggle("Vim mode", isOn: $settings.vimModeEnabled)
            }

            Section("Inline Suggestions") {
                Picker(
                    String(localized: "Inline suggestion provider"),
                    selection: $settings.inlineSuggestionProvider
                ) {
                    ForEach(InlineSuggestionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }

            Section("JSON Viewer") {
                Picker("Default view:", selection: $settings.jsonViewerPreferredMode) {
                    Text("Text").tag(JSONViewMode.text)
                    Text("Tree").tag(JSONViewMode.tree)
                }
            }

            DataGridSection(settings: $dataGridSettings)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    EditorSettingsView(settings: .constant(.default), dataGridSettings: .constant(.default))
        .frame(width: 450, height: 500)
}
