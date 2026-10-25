//
//  QueryEditorPaneLayoutTests.swift
//  TableProTests
//
//  The query split stops its editor pane at a fixed minimum. The bar and the editor have to fit inside it, or the bar
//  is cut off at the top and the editor's text runs up over it.
//

import AppKit
import SwiftUI
import TableProEditorKit
import Testing

@testable import TablePro

@MainActor
enum QueryEditorPaneFixture {
    static func input(text: Binding<String> = .constant("SELECT 1")) -> QueryEditorPaneInput {
        QueryEditorPaneInput(
            header: { vimMode in
                AnyView(VStack(spacing: 0) {
                    QueryEditorBar(
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
                        isExecuting: false,
                        vimMode: vimMode,
                        showsHistoryTip: false,
                        onAIAction: { _ in },
                        onRun: {},
                        onRunAllStatements: {},
                        onRunWithoutLimit: {},
                        onStop: {},
                        onExplain: { _ in },
                        onFormat: {},
                        onSaveAsFavorite: {},
                        onClearQuery: {},
                        onClearResults: {},
                        onContainerChanged: { _ in }
                    )
                    Divider()
                })
            },
            editor: SQLEditorInput(
                text: text,
                cursorPositions: .constant([]),
                databaseType: .sqlite
            )
        )
    }
}

@MainActor
struct QueryEditorPaneLayoutTests {
    @Test("The bar keeps its height and the editor fits below it at the pane's minimum height")
    func barAndEditorFitThePaneMinimum() {
        let paneMinimum = CollapsibleSplitController.defaultTopMinimumThickness
        let pane = QueryEditorPaneController(input: QueryEditorPaneFixture.input())
        defer { pane.teardown() }
        let view = pane.view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: paneMinimum)
        view.layoutSubtreeIfNeeded()

        let header = pane.header.frame
        let editor = pane.editor.textViewController.view.frame
        #expect(header.height == pane.header.intrinsicContentSize.height)
        #expect(header.maxY <= paneMinimum)
        #expect(editor.maxY <= header.minY + 0.5)
        #expect(editor.height > 0)
    }
}
