//
//  FoldCommandBehaviourTests.swift
//  TableProTests
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Fold commands")
@MainActor
struct FoldCommandBehaviourTests {
    private let script = """
    CREATE TABLE users (
        id BIGSERIAL,
        name TEXT,
        email TEXT
    );
    """

    private func makeController(
        _ text: String,
        peripherals: SourceEditorConfiguration.Peripherals = .init(showGutter: true, showFoldingRibbon: true)
    ) -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: peripherals
        )
        let controller = TextViewController(
            string: text,
            language: .sql,
            configuration: configuration,
            cursorPositions: [CursorPosition(range: NSRange(location: 0, length: 0))],
            foldProvider: SQLLineFoldProvider(dialect: .postgres)
        )
        controller.loadView()
        controller.textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 800, height: 600))
        return controller
    }

    private func waitForFolds(_ controller: TextViewController) async throws {
        for _ in 0..<40 {
            if !controller.foldRanges.isEmpty { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Hiding the line numbers hides the gutter with them, and the chevrons go with it, but the reader turned off
    /// line numbers rather than folding. Folds have to keep being calculated so the Query menu, the right-click menu
    /// and the collapsed chips still work.
    @Test("Folding survives the reader hiding the line numbers")
    func foldingSurvivesAHiddenGutter() async throws {
        let controller = makeController(
            script,
            peripherals: EditorPeripherals.editor(lineNumbers: false, folding: true)
        )
        try await waitForFolds(controller)

        #expect(controller.textView.textInsets.left == 0, "No gutter means no reserved rail beside the code")
        #expect(!controller.foldRanges.isEmpty, "Folds are still calculated with nothing drawing them")

        controller.foldAll()
        #expect(!controller.collapsedFoldRanges.isEmpty, "Fold All still works from the menu")
    }

    @Test("Fold All collapses the document")
    func foldAllCollapses() async throws {
        let controller = makeController(script)
        try await waitForFolds(controller)

        #expect(!controller.foldRanges.isEmpty, "The provider must report folds before Fold All can run")

        controller.foldAll()
        #expect(!controller.collapsedFoldRanges.isEmpty, "Fold All must collapse at least one region")
    }

    @Test("Unfold All expands everything Fold All collapsed")
    func unfoldAllExpands() async throws {
        let controller = makeController(script)
        try await waitForFolds(controller)

        controller.foldAll()
        #expect(!controller.collapsedFoldRanges.isEmpty)

        controller.unfoldAll()
        #expect(controller.collapsedFoldRanges.isEmpty, "Unfold All must leave nothing collapsed")
    }

    @Test("Toggle collapses the region at the cursor and expands it again")
    func toggleAtCursor() async throws {
        let controller = makeController(script)
        try await waitForFolds(controller)

        #expect(controller.toggleFoldAtCursor(), "There must be a fold at the start of the statement")
        #expect(!controller.collapsedFoldRanges.isEmpty, "Toggling must collapse the region")

        #expect(controller.toggleFoldAtCursor())
        #expect(controller.collapsedFoldRanges.isEmpty, "Toggling again must expand it")
    }

    @Test("Collapsing never changes the document text")
    func textIsUntouched() async throws {
        let controller = makeController(script)
        try await waitForFolds(controller)

        controller.foldAll()
        #expect(controller.textView.string == script)
    }
}
