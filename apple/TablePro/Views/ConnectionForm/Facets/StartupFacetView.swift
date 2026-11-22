import SwiftUI

struct StartupFacetView: View {
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
        store.layout.facet(.startup)?.sections ?? []
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow) -> some View {
        switch row {
        case .builtIn(.startupCommands):
            EditorCodeEditor(
                text: store.binding(\.options.startupCommands),
                language: store.startupCommandsAreSQL ? .sql : .plain,
                row: row,
                store: store
            )
        case .builtIn(.preConnectScript):
            EditorCodeEditor(text: store.binding(\.options.preConnectScript), language: .shell, row: row, store: store)
        case .builtIn(.scriptTimeout):
            EditorOptionalNumberRow(
                String(localized: "Timeout"),
                value: store.binding(\.options.scriptTimeoutSeconds),
                defaultValue: ConnectionScriptRunner.defaultTimeoutSeconds,
                range: ConnectionScriptRunner.timeoutSecondsRange,
                unit: String(localized: "seconds"),
                row: row,
                store: store
            )
            .help(String(localized: "How long each script may run, from 1 to 300 seconds."))
        case .builtIn(.postDisconnectScript):
            EditorCodeEditor(text: store.binding(\.options.postDisconnectScript), language: .shell, row: row, store: store)
        case .plugin(let fieldID):
            PluginFieldRow(fieldID: fieldID, store: store)
        default:
            EmptyView()
        }
    }

    // The engine's copy and example are SQL; another engine's commands are its own language.
    private func footer(for section: SectionLayout) -> String? {
        guard section.rows.contains(.builtIn(.startupCommands)), !store.startupCommandsAreSQL else {
            return section.footer
        }
        return String(localized: "Commands to run after connecting. One per line or separated by semicolons.")
    }
}
