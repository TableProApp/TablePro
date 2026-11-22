import SwiftUI

struct AIAndMCPFacetView: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        Form {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows, id: \.self) { row in
                        rowView(row)
                    }
                } header: {
                    if let title = section.title {
                        Text(verbatim: title)
                    }
                } footer: {
                    if let footer = footer(for: section) {
                        Text(verbatim: footer)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sections: [SectionLayout] {
        store.layout.facet(.aiAndMCP)?.sections ?? []
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow) -> some View {
        switch row {
        case .builtIn(.externalAccess):
            Picker(selection: store.tracking(store.binding(\.ai.externalAccess), row: row)) {
                ForEach(ExternalAccessLevel.allCases) { level in
                    Text(verbatim: level.displayName).tag(level)
                }
            } label: {
                EditorRowLabel(String(localized: "Access"), row: row, store: store)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(row.accessibilityIdentifier)
            .editorRowFocus(row, store: store)
        case .builtIn(.aiPolicy):
            Picker(selection: store.tracking(store.binding(\.ai.policy), row: row)) {
                Text(String(localized: "Use Default"))
                    .tag(AIConnectionPolicy?.none)
                ForEach(AIConnectionPolicy.allCases) { policy in
                    Text(verbatim: policy.displayName)
                        .tag(AIConnectionPolicy?.some(policy))
                }
            } label: {
                EditorRowLabel(String(localized: "AI Policy"), row: row, store: store)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
            .editorRowFocus(row, store: store)
        case .builtIn(.alwaysAllowedTools):
            ForEach(store.draft.ai.alwaysAllowedTools, id: \.self) { tool in
                LabeledContent {
                    Button(String(localized: "Forget")) {
                        store.noteEdited(row)
                        store.forgetAlwaysAllowed(tool)
                    }
                    .accessibilityLabel(String(format: String(localized: "Forget %@"), tool))
                } label: {
                    Text(verbatim: tool)
                    Text(String(localized: "Always allowed"))
                }
            }
        case .builtIn(.aiRules):
            EditorCodeEditor(text: store.binding(\.ai.rules), language: .plain, row: row, store: store, minHeight: 120)
        case .plugin(let fieldID):
            PluginFieldRow(fieldID: fieldID, store: store)
        default:
            EmptyView()
        }
    }

    // The engine leaves these footers to the view: they read live state the layout does not carry.
    private func footer(for section: SectionLayout) -> String? {
        var lines = section.footer.map { [$0] } ?? []
        if section.rows.contains(.builtIn(.externalAccess)) {
            if section.footer == nil {
                // swiftlint:disable:next line_length
                lines.append(String(localized: "Controls how external clients (Raycast, Cursor, Claude Desktop, AppleScript, Shortcuts) access this connection. Tokens cannot exceed this level even with full-access scope."))
            }
            if let note = store.externalClientsReadOnlyNote {
                lines.append(note)
            }
        }
        if section.rows.contains(.builtIn(.aiPolicy)), section.footer == nil {
            lines.append(String(localized: "AI Policy applies to AI features and MCP clients."))
        }
        if section.rows.contains(.builtIn(.alwaysAllowedTools)) {
            lines.append(String(localized: "Always Allow on an assistant tool card adds the tool here. Forget makes its next call ask again."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
