//
//  StructureInspectorView.swift
//  TablePro
//

import SwiftUI

// The window inspector while a Structure view or a Create Table tab is on screen: the selected definition's form,
// or the table's own properties when nothing is selected.
struct StructureInspectorView: View {
    let source: StructureInspectorSource
    let tableMetadata: TableMetadata?

    var body: some View {
        switch source {
        case .table(let session):
            StructureInspectorContent(editor: session.editor, tableName: session.tableName) {
                StructureTablePropertiesView(
                    session: session,
                    changeManager: session.changeManager,
                    tableMetadata: tableMetadata
                )
            }
        case .createTable(let draft):
            CreateTableInspectorContent(draft: draft)
        }
    }
}

private struct CreateTableInspectorContent: View {
    @ObservedObject var draft: CreateTableDraft

    var body: some View {
        StructureInspectorContent(editor: draft.editor, tableName: draft.tableName) {
            CreateTablePropertiesView(draft: draft)
        }
    }
}

private struct StructureInspectorContent<TableProperties: View>: View {
    @ObservedObject var editor: StructureDefinitionEditor
    let tableName: String
    @ViewBuilder let tableProperties: () -> TableProperties

    var body: some View {
        let target = editor.inspectorTarget
        let form = selectedForm(target)
        VStack(spacing: 0) {
            InspectorSubjectView(
                subject: StructureInspectorPresentation.subject(
                    for: target,
                    definitionName: form?.name,
                    tableName: tableName
                )
            )
            content(target: target, form: form)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.structureDefinitionEditor, editor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("structure-inspector")
    }

    private func selectedForm(_ target: StructureDefinitionEditor.InspectorTarget) -> StructureInspectorForm? {
        guard case .entity(let section, let id) = target else { return nil }
        return editor.inspectorForm(for: section, id: id)
    }

    @ViewBuilder
    private func content(
        target: StructureDefinitionEditor.InspectorTarget,
        form: StructureInspectorForm?
    ) -> some View {
        switch target {
        case .table:
            tableProperties()
        case .entity:
            if let form {
                StructureDefinitionFormView(editor: editor, form: form, revision: editor.revision)
                    .id(form.entityID)
            }
        case .several(let section, let count):
            UnavailableStateView(
                StructureInspectorPresentation.severalTitle(section, count: count),
                systemImage: TrailingPaneSurface.inspector.symbolName,
                description: Text(String(localized: "Select one to edit it"))
            )
        }
    }
}
