import SwiftUI
import TableProAutocomplete
import TableProPluginKit

struct AdvancedFacetView: View {
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
        store.layout.facet(.advanced)?.sections ?? []
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow) -> some View {
        switch row {
        case .builtIn(.connectTimeout):
            EditorOptionalNumberRow(
                String(localized: "Connect Timeout"),
                value: store.binding(\.options.connectTimeoutSeconds),
                defaultValue: ConnectionTimeoutPolicy.defaultConnectTimeoutSeconds,
                range: DatabaseConnection.connectTimeoutSecondsRange,
                unit: String(localized: "seconds"),
                row: row,
                store: store
            )
            .help(connectTimeoutHelp)
        case .builtIn(.queryTimeout):
            AdvancedQueryTimeoutRow(row: row, store: store, settings: store.services.appSettings)
        case .builtIn(.binaryInlineLimit):
            EditorOptionalNumberRow(
                String(localized: "Binary Value Limit"),
                value: store.binding(\.options.binaryInlineLimitKilobytes),
                defaultValue: UnloadedValuePlan.defaultInlineByteLimit / 1_024,
                range: DatabaseConnection.binaryInlineLimitKilobytesRange,
                unit: String(localized: "KB"),
                row: row,
                store: store
            )
        case .builtIn(.identifierCase):
            Picker(selection: store.tracking(store.binding(\.options.completionIdentifierCase), row: row)) {
                ForEach(SQLIdentifierCase.allCases, id: \.self) { identifierCase in
                    Text(verbatim: Self.title(for: identifierCase)).tag(identifierCase)
                }
            } label: {
                EditorRowLabel(String(localized: "Identifier Case"), row: row, store: store)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
            .editorRowFocus(row, store: store)
        case .builtIn(.localOnly):
            Toggle(isOn: store.tracking(store.binding(\.options.localOnly), row: row)) {
                EditorRowLabel(String(localized: "Local Only"), row: row, store: store)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
            .editorRowFocus(row, store: store)
        case .plugin(let fieldID):
            pluginRow(fieldID)
        default:
            EmptyView()
        }
    }

    // A list's entries are rows of its section, never a List nested in the form.
    @ViewBuilder
    private func pluginRow(_ fieldID: String) -> some View {
        switch store.pluginFieldKind(fieldID) {
        case .attachedDatabases?:
            AdvancedAttachedDatabaseRows(fieldID: fieldID, store: store)
        case .loadableExtensions?:
            AdvancedExtensionRows(fieldID: fieldID, store: store)
        default:
            PluginFieldRow(fieldID: fieldID, store: store)
        }
    }

    private func footer(for section: SectionLayout) -> String? {
        guard section.rows.contains(.builtIn(.localOnly)), store.removesSyncedSecretsOnSave else {
            return section.footer
        }
        let removal = String(localized: "Saving removes its passwords from iCloud Keychain. Your other devices will need them entered again.")
        return [section.footer, removal].compactMap { $0 }.joined(separator: "\n")
    }

    // A file database has no network setup to wait for, only the open.
    private var connectTimeoutHelp: String {
        guard store.traits.connectionMode != .fileBased else {
            return String(
                format: String(localized: "Maximum time to open the database. Leave blank to use the %d-second default."),
                ConnectionTimeoutPolicy.defaultConnectTimeoutSeconds
            )
        }
        return String(
            format: String(localized: """
                Maximum time for TCP, TLS, authentication, tunnel, and proxy setup. \
                Leave blank to use the %d-second default.
                """),
            ConnectionTimeoutPolicy.defaultConnectTimeoutSeconds
        )
    }

    private static func title(for identifierCase: SQLIdentifierCase) -> String {
        switch identifierCase {
        case .asStored: return String(localized: "As Stored")
        case .lower: return String(localized: "lowercase")
        case .upper: return String(localized: "UPPERCASE")
        case .matchTyped: return String(localized: "Match What I Type")
        }
    }
}

// Observes Settings itself: the inherited limit changes there while this window stays open.
private struct AdvancedQueryTimeoutRow: View {
    let row: EditorRow
    @ObservedObject var store: ConnectionEditorStore
    @ObservedObject var settings: AppSettingsManager

    var body: some View {
        let globalSeconds = settings.general.queryTimeoutSeconds
        EditorOptionalNumberRow(
            String(localized: "Query Timeout"),
            value: store.binding(\.options.queryTimeoutSeconds),
            defaultValue: QueryTimeoutInheritance.inheritedSeconds(globalSeconds: globalSeconds),
            range: DatabaseConnection.queryTimeoutSecondsRange,
            unit: String(localized: "seconds"),
            row: row,
            store: store
        )
        .help(QueryTimeoutInheritance.subtitle(globalSeconds: globalSeconds))
    }
}
