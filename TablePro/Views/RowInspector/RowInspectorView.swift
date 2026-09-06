//
//  RowInspectorView.swift
//  TablePro
//

import SwiftUI

/// The window's inspector: the currently selected row, in one of two renderings.
///
/// It replaces a view that carried four modes plus two full-panel takeovers, each takeover drawing
/// its own back button over the rest of the row. There is no navigation here: a structured value
/// grows in place and the pop-out windows take anything larger, so the fields around it never go
/// away.
internal struct RowInspectorView: View {
    @Bindable internal var state: RowInspectorState
    internal let connection: DatabaseConnection

    @Environment(\.commandActions) private var commandActions

    private var context: RowInspectorContext { state.context }

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeaderView(
                subject: context.subject,
                viewMode: $state.viewMode,
                showsViewModePicker: context.hasRow && context.jsonRow != nil
            )
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if context.hasRow {
            switch state.viewMode {
            case .fields: fieldsMode
            case .json: jsonMode
            }
        } else if let metadata = context.tableMetadata {
            TableInfoView(metadata: metadata)
        } else {
            emptyState
        }
    }

    private var fieldsMode: some View {
        InspectorFieldListView(
            editState: state.editState,
            isEditable: context.isEditable && !context.isRowDeleted,
            databaseType: connection.type,
            userDefinedTypeScope: context.userDefinedTypeScope,
            onPopOut: popOut
        )
    }

    /// The JSON rendering only exists for a data-grid row, because a schema grid's selection is a
    /// column definition with no types and no foreign keys to follow.
    @ViewBuilder
    private var jsonMode: some View {
        if context.jsonRow != nil {
            JSONRowInspectorView(
                viewModel: state.jsonViewModel,
                snapshot: context.jsonRow,
                onOpenReferencedTable: { reference, value in
                    commandActions?.openForeignKeyTable(reference: reference, value: value)
                }
            )
        } else {
            fieldsMode
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "No Row Selected"),
            systemImage: "sidebar.right",
            description: Text(String(localized: "Select a row to see its fields"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pop-out windows are the escape for a value too large for the pane, and the only escape:
    /// no competitor ships an in-panel takeover and neither does this any more.
    private func popOut(field: FieldEditState, text: String, kind: FieldEditorKind) {
        let isEditable = context.isEditable && !context.isRowDeleted && !field.isServerOwned
        let fieldID = field.id
        let commit: ((String) -> Void)? = isEditable
            ? { [editState = state.editState] newValue in
                guard let current = editState.fields.first(where: { $0.id == fieldID }) else { return }
                editState.updateField(at: current.columnIndex, value: newValue)
            }
            : nil

        switch kind {
        case .json:
            JSONViewerWindowController.open(
                text: text,
                columnName: field.columnName,
                isEditable: isEditable,
                onCommit: commit
            )
        case .phpSerialized:
            PhpViewerWindowController.open(text: text, columnName: field.columnName)
        case .multiLine, .singleLine, .schemaText, .blobHex, .image, .boolean,
             .enumPicker, .setPicker, .typePicker:
            TextViewerWindowController.open(
                text: text,
                columnName: field.columnName,
                isEditable: isEditable,
                onCommit: commit
            )
        }
    }
}
