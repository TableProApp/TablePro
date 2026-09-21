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
    @ObservedObject private var state: RowInspectorState
    private let paneState: TrailingPaneState
    private let contentMode: ConnectionWorkspaceContentMode
    private let connection: DatabaseConnection

    @Environment(\.commandActions) private var commandActions

    internal init(
        paneState: TrailingPaneState,
        contentMode: ConnectionWorkspaceContentMode,
        connection: DatabaseConnection
    ) {
        _state = ObservedObject(wrappedValue: paneState.inspector)
        self.paneState = paneState
        self.contentMode = contentMode
        self.connection = connection
    }

    private var context: RowInspectorContext { state.context }

    var body: some View {
        VStack(spacing: 0) {
            TrailingPaneHeaderView(
                surface: .inspector,
                contentMode: contentMode,
                paneState: paneState,
                inspectorRendering: offeredRendering
            ) { section in
                menuSection(section)
            }
            InspectorSubjectView(subject: context.subject)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func menuSection(_ section: TrailingPaneMenuSection) -> some View {
        switch section {
        case .inspectorRendering:
            renderingPicker
        case .jsonReading:
            JSONReadingCommands(viewModel: state.jsonViewModel)
        case .conversations, .clearRecents, .resultView:
            EmptyView()
        }
    }

    /// Both renderings are views of the same selection, which is the case Apple's inspector guidance
    /// covers. The header offers this only while `offeredRendering` has a value, and there the stored
    /// mode is the one drawn, so the item it checks is the one on screen.
    private var renderingPicker: some View {
        Picker(String(localized: "Inspector View"), selection: $state.viewMode) {
            ForEach(InspectorViewMode.allCases, id: \.self) { mode in
                Text(mode.localizedTitle).tag(mode)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// The rendering on screen, for a selection that can be drawn both ways. A schema grid's
    /// selection is a column definition with no types and no foreign keys to follow, and a pane with
    /// no row draws table info or nothing, so neither offers a choice: the stored mode would be
    /// checked there over a pane drawing something else.
    private var offeredRendering: InspectorViewMode? {
        guard context.hasRow, context.jsonRow != nil else { return nil }
        return showsFields ? .fields : .json
    }

    /// The field list stays mounted and is hidden rather than rebuilt.
    ///
    /// It owns its search term, its edited-only setting, which field is expanded, which field has
    /// focus and the `List`'s scroll position, and none of that survives leaving the hierarchy.
    /// Rebuilding it also rebuilds a row per column, which is what scales on a wide table. The JSON
    /// rendering is cheap to rebuild and keeps its own reader state in `jsonViewModel`, so it stays
    /// conditional.
    @ViewBuilder
    private var content: some View {
        if context.hasRow {
            ZStack(alignment: .topLeading) {
                fieldsMode
                    .opacity(showsFields ? 1 : 0)
                    .allowsHitTesting(showsFields)
                    /// Neither opacity nor hit-testing stops the keyboard. Without this a field
                    /// still holding first responder when the mode changed goes on accepting text
                    /// and the list's Ctrl-Option-N and Ctrl-Option-D behind the JSON view, and
                    /// each of those stages a real cell change that Save later commits unseen.
                    .disabled(!showsFields)
                    .accessibilityHidden(!showsFields)

                if !showsFields {
                    jsonMode
                }
            }
        } else if let metadata = context.tableMetadata {
            TableInfoView(metadata: metadata)
        } else {
            emptyState
        }
    }

    /// The JSON rendering only exists for a data-grid row, because a schema grid's selection is a
    /// column definition with no types and no foreign keys to follow.
    private var showsFields: Bool {
        state.viewMode == .fields || context.jsonRow == nil
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

    private var jsonMode: some View {
        JSONRowInspectorView(
            viewModel: state.jsonViewModel,
            snapshot: context.jsonRow,
            onOpenReferencedTable: { reference, value in
                commandActions?.openForeignKeyTable(reference: reference, value: value)
            }
        )
    }

    /// The inspector's own glyph rather than `sidebar.right`, which is the pane and which the pane's
    /// not-connected state drew too: a row not being selected and a connection being down read the
    /// same.
    private var emptyState: some View {
        UnavailableStateView(
            String(localized: "No Row Selected"),
            systemImage: TrailingPaneSurface.inspector.symbolName,
            description: Text(String(localized: "Select a row to see its fields"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pop-out windows are the escape for a value too large for the pane, and the only escape:
    /// no competitor ships an in-panel takeover and neither does this any more.
    private func popOut(field: FieldEditState, text: String, kind: FieldEditorKind) {
        let isEditable = context.isEditable && !context.isRowDeleted && !field.isServerOwned
        /// Captured here rather than looked up on each keystroke: the field's id is reissued on
        /// every selection change, so a window left open over a new selection used to fail its own
        /// lookup and drop everything typed into it without a word.
        let columnIndex = field.columnIndex
        let rowIDs = state.editState.rowIDs
        let commit: ((String) -> Void)? = isEditable
            ? { [editState = state.editState] newValue in
                editState.updateDetachedField(columnIndex: columnIndex, rowIDs: rowIDs, value: newValue)
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
             .enumPicker, .setPicker, .arrayElements, .typePicker, .valuePicker:
            TextViewerWindowController.open(
                text: text,
                columnName: field.columnName,
                isEditable: isEditable,
                onCommit: commit
            )
        }
    }
}

/// The JSON rendering's own commands, in the pane header's menu while that rendering is on screen.
///
/// They were an ellipsis of their own at the end of the JSON filter field, which put two ellipsis
/// menus one above the other in the same column once the pane's header gained one. Its own view so
/// it observes the reader's model: the inspector does not, and a menu built from it would go on
/// showing Always Expand Foreign Keys in the state it had when the pane last redrew.
private struct JSONReadingCommands: View {
    @ObservedObject var viewModel: JSONRowInspectorViewModel

    var body: some View {
        Button(String(localized: "Copy Visible")) { viewModel.copyVisible() }
        Divider()
        Button(String(localized: "Collapse All")) { viewModel.collapseAll() }
        Button(String(localized: "Expand All")) { viewModel.expandAll() }
        Divider()
        Toggle(
            String(localized: "Always Expand Foreign Keys"),
            isOn: Binding(
                get: { viewModel.alwaysExpandForeignKeys },
                set: { viewModel.setAlwaysExpandForeignKeys($0) }
            )
        )
    }
}
