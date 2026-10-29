//
//  CreateTablePropertiesView.swift
//  TablePro
//

import SwiftUI

// The drafted table's comment and engine options, when nothing on the Definition page is selected. The lists come
// from the server's catalog and start from the target database's defaults; nil writes no clause.
struct CreateTablePropertiesView: View {
    @ObservedObject var draft: CreateTableDraft

    private var catalog: TableOptionsCatalog? {
        guard case .loaded(let catalog) = draft.optionsCatalog else { return nil }
        return catalog
    }

    private var offersComment: Bool {
        let driver = DatabaseManager.shared.driver(for: draft.editor.context.connection.id)
        return DatabaseObjectToolEligibility.Support.of(driver).commentableTypes.contains(.table)
    }

    var body: some View {
        let offersComment = draft.form == nil && self.offersComment
        let catalog = draft.form == nil ? self.catalog : nil
        if !offersComment, catalog == nil {
            UnavailableStateView(
                String(localized: "No Selection"),
                systemImage: TrailingPaneSurface.inspector.symbolName,
                description: Text(String(localized: "Select a definition to edit it"))
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    StructureInspectorSectionHeader(title: String(localized: "Table"))
                    VStack(alignment: .leading, spacing: 10) {
                        if offersComment {
                            StructureInspectorRow(label: String(localized: "Comment")) {
                                TextField(String(localized: "Optional"), text: $draft.tableOptions.comment, axis: .vertical)
                                    .lineLimit(2...6)
                                    .textFieldStyle(.squareBorder)
                                    .accessibilityLabel(String(localized: "Comment"))
                                    .accessibilityIdentifier("create-table-comment")
                            }
                        }
                        if let catalog {
                            engineRows(catalog)
                        }
                    }
                }
                .padding(.horizontal, InspectorMetrics.horizontalInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .controlSize(.small)
            .disabled(draft.editor.isReadOnly)
        }
    }

    @ViewBuilder
    private func engineRows(_ catalog: TableOptionsCatalog) -> some View {
        let options = draft.tableOptions
        if !catalog.engines.isEmpty || options.engine != nil {
            StructureInspectorRow(label: String(localized: "Engine")) {
                Picker(String(localized: "Engine"), selection: $draft.tableOptions.engine) {
                    if options.engine == nil {
                        Text(String(localized: "Default")).tag(String?.none)
                    }
                    ForEach(TableOptionsForm.engines(in: catalog, keeping: options.engine)) { choice in
                        Text(choice.title).tag(Optional(choice.name))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("create-table-engine")
            }
        }

        StructureInspectorRow(label: String(localized: "Character Set")) {
            Picker(String(localized: "Character Set"), selection: characterSetBinding) {
                if options.charset == nil {
                    Text(String(localized: "Default")).tag(String?.none)
                }
                ForEach(TableOptionsForm.characterSets(in: catalog, keeping: options.charset), id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("create-table-charset")
        }

        StructureInspectorRow(label: String(localized: "Collation")) {
            Picker(String(localized: "Collation"), selection: $draft.tableOptions.collation) {
                if options.collation == nil {
                    Text(String(localized: "Default")).tag(String?.none)
                }
                ForEach(
                    TableOptionsForm.collations(in: catalog, characterSet: options.charset, keeping: options.collation)
                ) { choice in
                    Text(choice.title).tag(Optional(choice.name))
                }
            }
            .labelsHidden()
            .disabled(options.charset == nil)
            .accessibilityIdentifier("create-table-collation")
        }
    }

    // One whole-value write: the collation follows the character set, so a second write would resolve against a
    // stale draft.
    private var characterSetBinding: Binding<String?> {
        Binding(
            get: { draft.tableOptions.charset },
            set: { draft.selectCharacterSet($0) }
        )
    }
}
