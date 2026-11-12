//
//  EditorSettingsView.swift
//  TablePro
//

import SwiftUI
import TableProAutocomplete

struct EditorSettingsView: View {
    @Binding var settings: EditorSettings
    @Binding var formatter: SQLFormatterSettings
    @Binding var typography: TypographySettings

    var body: some View {
        Form {
            TypographySection(domain: .editor, settings: $typography)

            Section("Display") {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Highlight current line", isOn: $settings.highlightCurrentLine)
                Toggle("Highlight current statement", isOn: $settings.highlightCurrentStatement)
                Toggle("Show invisible characters", isOn: $settings.showInvisibleCharacters)
                Toggle("Word wrap", isOn: $settings.wordWrap)
                Toggle("Show the query bar on two rows", isOn: $settings.queryBarTwoRows)
                    .help(Text("""
                        Puts Save, Query Builder, Format, Snippets and AI above the editor, and the connection, \
                        the database and the run controls on a second row.
                        """))
                Toggle("Show Message and Summary tabs above query results", isOn: $settings.queryResultTabs)
                    .help(Text("""
                        After a run, Message lists what each statement did and Summary puts the same in a table, \
                        beside a tab for each result.
                        """))
            }

            Section("Gutter") {
                Toggle("Code folding", isOn: $settings.codeFoldingEnabled)
                Toggle("Run button beside each statement", isOn: $settings.showStatementRunControls)
                    .disabled(!settings.showLineNumbers)
                    .help(Text("The run button sits in the gutter, which needs line numbers."))
            }

            Section("Editing") {
                Picker("Tab width:", selection: $settings.tabWidth) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                    Text("8 spaces").tag(8)
                }
                Picker("Keyword case:", selection: $settings.keywordCase) {
                    ForEach(SQLKeywordCase.allCases, id: \.self) { keywordCase in
                        Text(keywordCase.displayName).tag(keywordCase)
                    }
                }
                Toggle("Query parameters (:name syntax)", isOn: $settings.queryParametersEnabled)
                Picker("Key bindings:", selection: $settings.keyBindings) {
                    Text("Standard").tag(EditorKeyBindings.standard)
                    Text(verbatim: "Vim").tag(EditorKeyBindings.vim)
                    Text(verbatim: "Emacs").tag(EditorKeyBindings.emacs)
                }
                .accessibilityIdentifier("key-bindings-picker")
            }

            FormatterSection(settings: $formatter, editor: settings)
        }
        .formStyle(.grouped)
    }
}

#Preview {
    EditorSettingsView(settings: .constant(.default), formatter: .constant(.default), typography: .constant(.default))
        .frame(width: 450, height: 500)
}
