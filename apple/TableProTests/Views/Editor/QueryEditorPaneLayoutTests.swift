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
    static func input(
        text: Binding<String> = .constant("SELECT 1"),
        twoRow: QueryEditorBar.TwoRowInput? = nil
    ) -> QueryEditorPaneInput {
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
                            supportsQueryBuilder: true,
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
                        onContainerChanged: { _ in },
                        twoRow: twoRow
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

    static func twoRowInput(connectionId: UUID) -> QueryEditorBar.TwoRowInput {
        QueryEditorBar.TwoRowInput(
            connection: QueryConnectionPickerModel(
                connectionId: connectionId,
                name: "Shop Demo",
                color: .blue,
                canMove: true,
                confirm: { _ in false },
                move: { _ in }
            ),
            savedQueries: ConnectionDataCache.shared(for: connectionId),
            onSave: {},
            onOpenQueryBuilder: {},
            onInsertSavedQuery: { _ in }
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

    /// The second row costs one control's height, and the pane's minimum still holds the bar and an
    /// editor below it, so turning the setting on never pushes the bar under the results.
    @Test("The two-row bar is taller than one row and still fits the pane minimum")
    func twoRowBarFitsThePaneMinimum() {
        let connectionId = UUID()
        defer { ConnectionDataCache.removeConnection(connectionId) }
        let paneMinimum = CollapsibleSplitController.defaultTopMinimumThickness
        let single = QueryEditorPaneController(input: QueryEditorPaneFixture.input())
        let double = QueryEditorPaneController(input: QueryEditorPaneFixture.input(
            twoRow: QueryEditorPaneFixture.twoRowInput(connectionId: connectionId)
        ))
        defer {
            single.teardown()
            double.teardown()
        }
        for pane in [single, double] {
            pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: paneMinimum)
            pane.view.layoutSubtreeIfNeeded()
        }

        let oneRow = single.header.frame.height
        let twoRows = double.header.frame.height
        let editor = double.editor.textViewController.view.frame
        #expect(twoRows > oneRow + 10)
        #expect(twoRows == double.header.intrinsicContentSize.height)
        #expect(double.header.frame.maxY <= paneMinimum)
        #expect(editor.maxY <= double.header.frame.minY + 0.5)
        #expect(editor.height > 0)
    }
}
