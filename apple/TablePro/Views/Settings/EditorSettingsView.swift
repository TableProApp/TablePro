import SwiftUI
import TableProAutocomplete

struct EditorSettingsView: View {
    static let tabWidths = [2, 4, 8]

    @ObservedObject var editor: SettingsSlice<EditorSettings>
    @ObservedObject var typography: SettingsSlice<TypographySettings>

    var body: some View {
        Form {
            Section {
                TypographyRows(domain: .editor, typography: $typography.value)
            } header: {
                Text("Font")
            }

            Section {
                Toggle("Highlight current line", isOn: $editor.value.highlightCurrentLine)
                    .accessibilityIdentifier("editor-highlight-current-line")
                Toggle(isOn: $editor.value.highlightCurrentStatement) {
                    Text("Highlight current statement")
                    Text("A faint band behind the statement the cursor is in.")
                }
                .accessibilityIdentifier("editor-highlight-current-statement")
                Toggle("Show invisible characters", isOn: $editor.value.showInvisibleCharacters)
                    .accessibilityIdentifier("editor-show-invisibles")
                Toggle("Word wrap", isOn: $editor.value.wordWrap)
                    .accessibilityIdentifier("editor-word-wrap")
            } header: {
                Text("Display")
            }

            Section {
                Toggle("Show line numbers", isOn: $editor.value.showLineNumbers)
                    .accessibilityIdentifier("editor-line-numbers")
                Toggle(isOn: $editor.value.showStatementRunControls) {
                    Text("Run button beside each statement")
                    Text("Needs line numbers.")
                }
                .disabled(!editor.value.showLineNumbers)
                .accessibilityIdentifier("editor-run-buttons")
                Toggle("Code folding", isOn: $editor.value.codeFoldingEnabled)
                    .accessibilityIdentifier("editor-code-folding")
            } header: {
                Text("Gutter")
            }

            Section {
                Picker("Key bindings", selection: $editor.value.keyBindings) {
                    Text("Standard").tag(EditorKeyBindings.standard)
                    Text(verbatim: "Vim").tag(EditorKeyBindings.vim)
                    Text(verbatim: "Emacs").tag(EditorKeyBindings.emacs)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("key-bindings-picker")

                Picker("Tab width", selection: Self.tabWidthBinding($editor.value)) {
                    SettingsChoiceItems(Self.tabWidths, including: editor.value.clampedTabWidth) { width in
                        Text("\(width) spaces")
                    }
                }
                .accessibilityIdentifier("editor-tab-width")

                Picker(selection: $editor.value.keywordCase) {
                    Text(SQLKeywordCase.matchTypedElseUpper.displayName).tag(SQLKeywordCase.matchTypedElseUpper)
                    Text(SQLKeywordCase.matchTypedElseLower.displayName).tag(SQLKeywordCase.matchTypedElseLower)
                    Divider()
                    Text(SQLKeywordCase.upper.displayName).tag(SQLKeywordCase.upper)
                    Text(SQLKeywordCase.lower.displayName).tag(SQLKeywordCase.lower)
                } label: {
                    Text("Keyword case")
                    Text("The case completions use. UPPERCASE and lowercase also change keywords as you type.")
                }
                .accessibilityIdentifier("editor-keyword-case")

                Toggle(isOn: $editor.value.queryParametersEnabled) {
                    Text("Query parameters")
                    Text("Asks for a value for each :name placeholder before the query runs.")
                }
                .accessibilityIdentifier("editor-query-parameters")
            } header: {
                Text("Editing")
            }

            Section {
                SettingsDrillRow(route: SettingsRoute.page(.sqlFormatting), title: SettingsPage.sqlFormatting.title)
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-editor")
    }

    // Shows the width the editor uses; a pick writes the stored field.
    static func tabWidthBinding(_ editor: Binding<EditorSettings>) -> Binding<Int> {
        Binding(
            get: { editor.wrappedValue.clampedTabWidth },
            set: { editor.wrappedValue.tabWidth = $0 }
        )
    }
}
