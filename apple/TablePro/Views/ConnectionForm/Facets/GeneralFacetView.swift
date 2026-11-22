//
//  GeneralFacetView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct GeneralFacetView: View {
    @ObservedObject var store: ConnectionEditorStore

    @Environment(\.undoManager) private var undoManager

    init(store: ConnectionEditorStore) {
        self.store = store
    }

    var body: some View {
        Form {
            if let facet = store.layout.facet(.general) {
                ForEach(facet.sections) { section in
                    Section {
                        ForEach(section.rows, id: \.self) { row in
                            rowView(row, in: section)
                        }
                    } header: {
                        if let title = section.title {
                            Text(verbatim: title)
                        }
                    } footer: {
                        if let footer = section.footer {
                            Text(verbatim: footer)
                        } else if let status = socketStatus(for: section) {
                            Text(verbatim: status)
                                .accessibilityIdentifier("connection-form-socket-status")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: placeInitialFocus)
    }

    // A new connection starts where its address goes; an existing one at its name.
    private func placeInitialFocus() {
        guard store.focusRequest == nil, store.selectedFacet == .general else { return }
        let rows = store.layout.facet(.general)?.sections.flatMap(\.rows) ?? []
        let target: EditorRow
        if !store.isNew {
            target = .builtIn(.name)
        } else if let first = [EditorRow.builtIn(.host), .builtIn(.databaseFile)].first(where: { rows.contains($0) }) {
            target = first
        } else {
            target = .builtIn(.name)
        }
        store.focus(facet: .general, row: target)
    }

    private func socketStatus(for section: SectionLayout) -> String? {
        guard section.id == "connection", store.usesLocalSocket else { return nil }
        return GeneralSocketStatus.message(
            status: store.localSocketFileStatus,
            socketFile: store.localSocketEndpoint?.socketFile,
            isDirectory: store.traits.localSocketIsDirectory
        )
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow, in section: SectionLayout) -> some View {
        switch row {
        case .plugin(let fieldID):
            PluginFieldRow(fieldID: fieldID, store: store, title: pluginTitle(fieldID, in: section))
        case .builtIn(let builtIn):
            builtInRow(builtIn, in: section)
        }
    }

    // A plugin's method picker labelled like its section would read "Authentication" under "Authentication".
    private func pluginTitle(_ fieldID: String, in section: SectionLayout) -> String? {
        guard let label = store.pluginField(fieldID)?.label, let title = section.title,
              label.caseInsensitiveCompare(title) == .orderedSame
        else { return nil }
        return String(localized: "Method")
    }

    @ViewBuilder
    private func builtInRow(_ row: BuiltInRow, in section: SectionLayout) -> some View {
        switch row {
        case .name:
            EditorTextRow(
                String(localized: "Name"),
                text: store.binding(\.name),
                prompt: String(localized: "Connection name"),
                row: .builtIn(.name),
                store: store
            )
        case .type:
            GeneralTypeRow(store: store)
        case .environment:
            GeneralEnvironmentRow(store: store)
        case .endpointKind:
            Picker(selection: store.endpointBinding) {
                Text(String(localized: "Host and Port")).tag(ConnectionDraft.Endpoint.hostAndPort)
                Text(String(localized: "Socket")).tag(ConnectionDraft.Endpoint.localSocket)
            } label: {
                EditorRowLabel(String(localized: "Connect Using"), row: .builtIn(.endpointKind), store: store)
            }
            .accessibilityIdentifier(BuiltInRow.endpointKind.accessibilityIdentifier)
        case .localSocketPath:
            GeneralSocketPathRow(store: store)
        case .host:
            EditorTextRow(
                String(localized: "Host"),
                text: store.hostBinding(undoManager: undoManager),
                prompt: store.traits.defaultHost ?? "localhost",
                row: .builtIn(.host),
                store: store
            )
            .disabled(store.hostAndPortAreUnused)
            if let notice = store.pastedURLNotice {
                GeneralPastedURLNoticeRow(notice: notice, store: store)
            }
        case .port:
            EditorTextRow(
                String(localized: "Port"),
                text: store.portBinding,
                prompt: store.traits.defaultPortText,
                row: .builtIn(.port),
                store: store
            )
            .disabled(store.hostAndPortAreUnused)
        case .portTLSNotice:
            if let notice = store.portTLSNotice {
                GeneralPortTLSNoticeRow(notice: notice, store: store)
            }
        case .databaseFile:
            EditorDatabaseFileRow(
                String(localized: "File Path"),
                path: store.binding(\.database),
                prompt: databaseFilePrompt,
                row: .builtIn(.databaseFile),
                store: store,
                chooseIdentifier: "connection-form-file-browse",
                newIdentifier: "connection-form-file-new"
            )
        case .database:
            EditorTextRow(
                store.traits.containerEntityName,
                text: store.binding(\.database),
                prompt: String(format: String(localized: "%@_name"), store.traits.containerEntityName.lowercased()),
                row: .builtIn(.database),
                store: store
            )
        case .credentialProfile:
            GeneralCredentialsRows(store: store)
        case .username:
            EditorTextRow(
                String(localized: "Username"),
                text: store.binding(\.credentials.username),
                row: .builtIn(.username),
                store: store
            )
        case .passwordSource:
            GeneralPasswordSourceRows(store: store)
        case .passwordMode:
            if section.rows.contains(.builtIn(.password)) {
                GeneralPasswordRow(store: store)
            } else {
                GeneralPasswordModeRow(store: store)
            }
        case .password:
            if !section.rows.contains(.builtIn(.passwordMode)) {
                GeneralPasswordRow(store: store)
            }
        case .kerberosNote:
            GeneralKerberosNote(store: store)
        case .pgpassStatus:
            GeneralPgpassStatus(status: store.pgpassStatus)
        default:
            EmptyView()
        }
    }

    private var databaseFilePrompt: String {
        let ext = (store.traits.fileExtensions.first ?? "db").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "/path/to/database.\(ext.isEmpty ? "db" : ext)"
    }
}
