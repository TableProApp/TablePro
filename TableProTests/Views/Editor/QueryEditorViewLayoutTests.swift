//
//  QueryEditorViewLayoutTests.swift
//  TableProTests
//
//  The query split stops its editor pane at a fixed minimum. The editor, its bar and the divider
//  between them have to fit inside it, or the stack overflows the pane: the bar is cut off at the
//  top and the editor's text runs up over it.
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct QueryEditorViewLayoutTests {
    private func makeEditor() -> QueryEditorView {
        QueryEditorView(
            queryText: .constant("SELECT 1"),
            cursorPositions: .constant([]),
            parameters: .constant([]),
            isParameterPanelVisible: .constant(false),
            scope: QueryScopeBarModel(
                containers: [],
                selectedName: "shop",
                entityName: String(localized: "Database"),
                isReadOnly: false,
                schemaName: nil
            ),
            commands: QueryCommandAvailability(
                isConnected: true,
                hasQueryText: true,
                isExecuting: false,
                isStoppable: true,
                hasResults: false,
                explainVariants: [],
                shortcutHint: { label, _ in label }
            ),
            onRun: {},
            onRunAllStatements: {},
            onRunWithoutLimit: {},
            onStop: {},
            onExplain: { _ in },
            onFormat: {},
            onSaveAsFavoriteCommand: {},
            onClearQuery: {},
            onClearResults: {},
            onContainerChanged: { _ in }
        )
    }

    @Test("The editor and its bar fit the editor pane's minimum height")
    func editorFitsThePaneMinimum() {
        let paneMinimum = VerticalCollapsibleSplitView<EmptyView, EmptyView>.defaultTopMinimumThickness
        let controller = NSHostingController(rootView: makeEditor())

        let squeezed = controller.sizeThatFits(in: CGSize(width: 900, height: 1))

        #expect(
            squeezed.height <= paneMinimum,
            "the editor stack needs \(squeezed.height)pt inside a pane that can be \(paneMinimum)pt"
        )
    }
}
