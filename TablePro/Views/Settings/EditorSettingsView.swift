//
//  EditorSettingsView.swift
//  TablePro
//

import SwiftUI

struct EditorSettingsView: View {
    @Binding var settings: EditorSettings
    @Binding var typography: TypographySettings

    var body: some View {
        Form {
            TypographySection(domain: .editor, settings: $typography)

            Section("SQL Editor") {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Highlight current line", isOn: $settings.highlightCurrentLine)
                Toggle("Highlight current statement", isOn: $settings.highlightCurrentStatement)
                Toggle("Word wrap", isOn: $settings.wordWrap)
                Toggle("Code folding", isOn: $settings.codeFoldingEnabled)
                Toggle("Run button beside each statement", isOn: $settings.showStatementRunControls)
                    .disabled(!settings.showLineNumbers)
                    .help(Text("The run button sits in the gutter, which needs line numbers."))
                Toggle("Show invisible characters", isOn: $settings.showInvisibleCharacters)
                Picker("Tab width:", selection: $settings.tabWidth) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("8 spaces").tag(8)
                }
                Toggle("Auto-uppercase keywords", isOn: $settings.uppercaseKeywords)
                Toggle("Query parameters (:name syntax)", isOn: $settings.queryParametersEnabled)
                Toggle("Vim mode", isOn: $settings.vimModeEnabled)
                    .accessibilityIdentifier("vim-mode-toggle")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    EditorSettingsView(settings: .constant(.default), typography: .constant(.default))
        .frame(width: 450, height: 500)
}
