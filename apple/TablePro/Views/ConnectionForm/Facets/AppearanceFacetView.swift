//
//  AppearanceFacetView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct AppearanceFacetView: View {
    @ObservedObject var store: ConnectionEditorStore

    init(store: ConnectionEditorStore) {
        self.store = store
    }

    var body: some View {
        Form {
            if let facet = store.layout.facet(.appearance) {
                ForEach(facet.sections) { section in
                    Section {
                        ForEach(section.rows, id: \.self) { row in
                            rowView(row)
                        }
                    } header: {
                        if let title = section.title {
                            Text(verbatim: title)
                        }
                    } footer: {
                        if let footer = section.footer {
                            Text(verbatim: footer)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow) -> some View {
        switch row {
        case .builtIn(.icon):
            LabeledContent {
                SymbolWell(
                    iconName: store.binding(\.appearance.iconName),
                    subject: .connection(store.draft.type),
                    color: store.draft.appearance.color,
                    accessibilityIdentifier: BuiltInRow.icon.accessibilityIdentifier
                )
            } label: {
                EditorRowLabel(String(localized: "Icon"), row: row, store: store)
            }
        case .builtIn(.color):
            AppearanceColorRow(store: store)
        case .builtIn(.tags):
            // The editor names its tag menu `connection-form-tags` and confirms a delete that reaches every connection.
            LabeledContent {
                ConnectionTagEditor(tagIds: store.binding(\.appearance.tagIds))
            } label: {
                EditorRowLabel(String(localized: "Tags"), row: row, store: store)
            }
        case .builtIn(.group):
            LabeledContent {
                ConnectionGroupPicker(selectedGroupId: store.binding(\.appearance.groupId))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(BuiltInRow.group.accessibilityIdentifier)
            } label: {
                EditorRowLabel(String(localized: "Group"), row: row, store: store)
            }
        case .plugin(let fieldID):
            PluginFieldRow(fieldID: fieldID, store: store)
        default:
            EmptyView()
        }
    }
}

// The colour shows as the tile it paints in the connection list, a tinted symbol per item rather than a swatch.
struct AppearanceColorRow: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        Picker(selection: store.binding(\.appearance.color)) {
            item(.none)
            Divider()
            ForEach(ConnectionColor.allCases.filter { !$0.isDefault }) { color in
                item(color)
            }
        } label: {
            EditorRowLabel(String(localized: "Color"), row: .builtIn(.color), store: store)
        }
        .accessibilityIdentifier(BuiltInRow.color.accessibilityIdentifier)
    }

    @ViewBuilder
    private func item(_ color: ConnectionColor) -> some View {
        if let image = ConnectionLibrarySymbols.image(systemName: color.isDefault ? "app.dashed" : "app.fill", color: color) {
            Label {
                Text(verbatim: color.displayName)
            } icon: {
                Image(nsImage: image)
            }
            .tag(color)
        } else {
            Text(verbatim: color.displayName).tag(color)
        }
    }
}
