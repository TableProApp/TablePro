//
//  RowInspectorView.swift
//  TablePro
//

import SwiftUI

// The window's inspector: the selected row in one of two renderings, or a structure definition's form while a
// Structure view or a Create Table tab is on screen. No navigation: a structured value grows in place and the
// pop-out windows take anything larger.
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
            if let structure = context.structure {
                StructureInspectorView(source: structure, tableMetadata: context.tableMetadata)
            } else {
                InspectorSubjectView(subject: context.subject)
                content
            }
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

    // Offered only while `offeredRendering` has a value, so the item it checks is the rendering on screen.
    private var renderingPicker: some View {
        Picker(String(localized: "Inspector View"), selection: $state.viewMode) {
            ForEach(InspectorViewMode.allCases, id: \.self) { mode in
                Text(mode.localizedTitle).tag(mode)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    // Only a data row can be drawn both ways; a structure definition or a pane with no row offers no choice.
    private var offeredRendering: InspectorViewMode? {
        guard context.structure == nil, context.hasRow, context.jsonRow != nil else { return nil }
        return showsFields ? .fields : .json
    }

    // The field list stays mounted and hidden: its search, expansion, focus and scroll position would not survive
    // a rebuild, and a rebuild makes a row per column. The JSON rendering keeps its state in `jsonViewModel`.
    @ViewBuilder
    private var content: some View {
        if context.hasRow {
            ZStack(alignment: .topLeading) {
                fieldsMode
                    .opacity(showsFields ? 1 : 0)
                    .allowsHitTesting(showsFields)
                    // Neither opacity nor hit-testing stops the keyboard: a focused field behind the JSON view
                    // would go on staging cell changes that Save commits unseen.
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

    private var showsFields: Bool {
        state.viewMode == .fields || context.jsonRow == nil
    }

    private var fieldsMode: some View {
        InspectorFieldListView(
            editState: state.editState,
            isEditable: context.isEditable && !context.isRowDeleted,
            databaseType: connection.type,
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

    // The inspector's own glyph, not `sidebar.right`, which the not-connected state draws.
    private var emptyState: some View {
        UnavailableStateView(
            String(localized: "No Row Selected"),
            systemImage: TrailingPaneSurface.inspector.symbolName,
            description: Text(String(localized: "Select a row to see its fields"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func popOut(field: FieldEditState, text: String, kind: FieldEditorKind) {
        let isEditable = context.isEditable && !context.isRowDeleted && !field.isServerOwned
        // Captured, not looked up per keystroke: the field's id is reissued on every selection change.
        let columnIndex = field.columnIndex
        let rowIDs = state.editState.rowIDs
        let commit: ((String) -> Void)? = isEditable
            ? { [editState = state.editState] newValue in
                editState.updateDetachedField(columnIndex: columnIndex, rowIDs: rowIDs, value: newValue)
            }
            : nil

        switch InspectorPopOutWindow.resolve(for: kind) {
        case .json:
            JSONViewerWindowController.open(
                text: text,
                columnName: field.columnName,
                isEditable: isEditable,
                onCommit: commit
            )
        case .php:
            PhpViewerWindowController.open(text: text, columnName: field.columnName)
        case .binary(let format):
            BinaryValueViewerWindowController.open(data: text.storedBytes, format: format, columnName: field.columnName)
        case .text:
            TextViewerWindowController.open(
                text: text,
                columnName: field.columnName,
                isEditable: isEditable,
                onCommit: commit
            )
        }
    }
}

// A geometry field's map opens its own window; its Text segment goes where that editor's kind would.
internal enum InspectorPopOutWindow: Equatable {
    case json
    case php
    case binary(BinaryValueFormat)
    case text

    internal static func resolve(for kind: FieldEditorKind) -> InspectorPopOutWindow {
        switch kind {
        case .json:
            return .json
        case .phpSerialized:
            return .php
        case .binaryValue(let format):
            return .binary(format)
        case .geometry(let descriptor):
            return resolve(for: descriptor.textEditorKind)
        case .multiLine, .singleLine, .blobHex, .image, .boolean, .enumPicker, .setPicker, .arrayElements, .vector:
            return .text
        }
    }
}

// The JSON rendering's commands in the pane header's menu. Its own view so it observes the reader's model, which
// the inspector does not.
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
