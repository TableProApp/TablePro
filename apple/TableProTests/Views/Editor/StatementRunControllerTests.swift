//
//  StatementRunControllerTests.swift
//  TableProTests
//
//  The gutter's run controls and the caret-statement band both come from here. A control that names the wrong range
//  runs the wrong statement, which is worse than having no control at all.
//

import AppKit
import Foundation
@testable import TablePro
import TableProEditorKit
import TableProGrammars
import TableProPluginKit
import TableProSQLGrammar
import TableProTextEngine
import Testing

@MainActor
struct StatementRunControllerTests {

    private func makeController(text: String) -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: EditorPeripherals.editor(lineNumbers: true, folding: true, statementRunControls: true)
        )
        let controller = TextViewController(
            string: text,
            language: .sql,
            configuration: configuration,
            cursorPositions: []
        )
        controller.loadView()
        return controller
    }

    private func makeSubject(
        grammar: SQLLexicalGrammar = TestGrammar.standard,
        sizeLimit: Int? = nil
    ) -> StatementRunController {
        let subject = StatementRunController()
        subject.grammar = grammar
        if let sizeLimit {
            subject.sizeLimit = sizeLimit
        }
        return subject
    }

    private let threeStatements = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    // MARK: - Run controls

    @Test("One run control per statement with content")
    func oneControlPerStatement() {
        let controller = makeController(text: "SELECT 1;\n\n-- just a note\n\nSELECT 2;\n   ")
        let subject = makeSubject()
        subject.install(on: controller)

        let ranges = controller.runnableStatements.map(\.range)
        let text = controller.textView.string as NSString
        #expect(ranges.count == 2)
        #expect(text.substring(with: ranges[0]) == "SELECT 1;")
        #expect(text.substring(with: ranges[1]) == "-- just a note\n\nSELECT 2;")
    }

    @Test("A routine body gets one control, not one per inner statement")
    func routineBodyGetsOneControl() {
        let text = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\nSELECT 3;"
        let controller = makeController(text: text)
        let subject = makeSubject(grammar: TestGrammar.mysql)
        subject.install(on: controller)

        #expect(controller.runnableStatements.count == 2)
    }

    @Test("A document past the size limit gets no controls and no band")
    func aboveSizeLimitDecoratesNothing() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject(sizeLimit: 8)
        subject.install(on: controller)

        #expect(controller.runnableStatements.isEmpty)
        #expect(controller.highlightedStatementRange == nil)
    }

    @Test("The shipped size limit matches the one folding uses")
    func shippedSizeLimitMatchesFolding() {
        #expect(StatementRunController.defaultSizeLimit == 2_000_000)
        #expect(makeSubject().sizeLimit == StatementRunController.defaultSizeLimit)
    }

    @Test("Disabling the controls leaves them drawn")
    func disablingKeepsControls() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        subject.setEnabled(false, in: controller)
        #expect(!controller.statementRunControlsEnabled)
        #expect(controller.runnableStatements.count == 3)

        subject.setEnabled(true, in: controller)
        #expect(controller.statementRunControlsEnabled)
    }

    @Test("Clearing removes both decorations and the callback")
    func clearingRemovesEverything() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        subject.clear(in: controller)
        #expect(controller.runnableStatements.isEmpty)
        #expect(controller.highlightedStatementRange == nil)
        #expect(controller.onRunStatement == nil)
    }

    // MARK: - The band

    @Test("The caret's statement is the one banded")
    func caretPicksTheStatement() throws {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 13, length: 0))])
        subject.refreshHighlight(in: controller)

        let banded = try #require(controller.highlightedStatementRange)
        #expect(banded == NSRange(location: 10, length: 9))
    }

    /// A non-empty selection runs verbatim rather than being widened to its statement, so banding the statement would
    /// mark something other than what runs.
    @Test("A selection turns the band off")
    func selectionTurnsTheBandOff() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 8))])
        subject.refreshHighlight(in: controller)

        #expect(controller.highlightedStatementRange == nil)
    }

    /// A comment carries no statement, so the caret sitting in one has nothing to run and nothing to mark. The scan
    /// never sets content for characters inside a comment, which is what makes this fall out rather than be special
    /// cased.
    @Test("A caret in a comment-only segment bands nothing")
    func commentOnlySegmentBandsNothing() {
        let controller = makeController(text: "SELECT 1;\n-- trailing note only\n")
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 15, length: 0))])
        subject.refreshHighlight(in: controller)

        #expect(controller.highlightedStatementRange == nil)
        #expect(controller.runnableStatements.count == 1)
    }

    @Test("An empty document bands nothing")
    func emptyDocumentBandsNothing() {
        let controller = makeController(text: "")
        let subject = makeSubject()
        subject.install(on: controller)

        #expect(controller.runnableStatements.isEmpty)
        #expect(controller.highlightedStatementRange == nil)
    }

    // MARK: - The band across edits

    // Long enough that the band's index records boundaries, which an edit near the top has to drop.
    private let indexedScript = String(repeating: "SELECT 1;\n", count: 1_000)

    private func freshBand(in controller: TextViewController, caret: Int) -> NSRange? {
        let statement = SQLStatementScanner.locatedStatementAtCursor(in: controller.textView.string, cursorPosition: caret)
        guard statement.hasContent, statement.contentRange.length > 0 else { return nil }
        return statement.contentRange
    }

    private func band(at caret: Int, in controller: TextViewController, subject: StatementRunController) -> NSRange? {
        controller.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
        subject.refreshHighlight(in: controller)
        return controller.highlightedStatementRange
    }

    @Test("An edit typed into the editor reaches a band that already read the script")
    func typedEditReachesTheBand() throws {
        let controller = makeController(text: indexedScript)
        let subject = makeSubject()
        subject.install(on: controller)
        #expect(band(at: 9_995, in: controller, subject: subject) == NSRange(location: 9_990, length: 9))

        // An open comment, because the editor pairs a typed quote, and it swallows every boundary the band had read.
        controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/*")
        try #require(controller.textView.string.hasPrefix("/*SELECT"))

        #expect(freshBand(in: controller, caret: 9_995) == nil)
        #expect(band(at: 9_995, in: controller, subject: subject) == nil)
    }

    @Test("Text set on the text view without the editor's edit path reaches the band")
    func textSetDirectlyReachesTheBand() {
        let controller = makeController(text: indexedScript)
        let subject = makeSubject()
        subject.install(on: controller)
        #expect(band(at: 9_995, in: controller, subject: subject) == NSRange(location: 9_990, length: 9))

        controller.textView.string = "'" + indexedScript

        #expect(band(at: 9_995, in: controller, subject: subject) == freshBand(in: controller, caret: 9_995))
    }

    @Test("A replaced document gets a band read from the new text")
    func replacedDocumentReachesTheBand() {
        let controller = makeController(text: indexedScript)
        let subject = makeSubject()
        subject.install(on: controller)
        #expect(band(at: 9_995, in: controller, subject: subject) == NSRange(location: 9_990, length: 9))

        controller.setText("'" + indexedScript)

        #expect(band(at: 9_995, in: controller, subject: subject) == freshBand(in: controller, caret: 9_995))
    }

    // 5,000 statements: resolving from the top walks about 50,000 units per caret move.
    @Test("Moving the caret through a long script rescans only near the caret")
    func caretMovesRescanOnlyNearTheCaret() {
        let controller = makeController(text: String(repeating: "SELECT 1;\n", count: 5_000))
        let subject = makeSubject()
        subject.install(on: controller)
        let start = 49_995
        _ = band(at: start, in: controller, subject: subject)
        let warmed = subject.caretIndexUnitsScanned

        let moves = 500
        for step in 1...moves {
            _ = band(at: start - step, in: controller, subject: subject)
        }

        #expect(controller.highlightedStatementRange == freshBand(in: controller, caret: start - moves))
        #expect(subject.caretIndexUnitsScanned - warmed <= moves * (SQLStatementCursorIndex.defaultCheckpointSpacing + 20))
    }

    // MARK: - Callback

    @Test("Pressing a control reports that control's own statement, not the caret's")
    func pressReportsItsOwnStatement() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        var reported: String?
        subject.onRun = { sql, _ in reported = sql; return true }
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        controller.onRunStatement?(controller.runnableStatements[2])

        #expect(reported == "SELECT 3;")
    }

    /// The controls are drawn from a scan that a large document lets fall up to one debounce behind the text. Running
    /// a stale range against the live document is how a `DELETE ... WHERE ...` gets truncated into a `DELETE`, so a
    /// press whose statement no longer starts where it did is refused rather than guessed at.
    @Test("A press against a document that moved underneath is refused")
    func staleRangeIsRefused() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        var reported: String?
        subject.onRun = { sql, _ in reported = sql; return true }
        subject.install(on: controller)

        let third = controller.runnableStatements[2]
        controller.textView.string = "SELECT 99;"
        controller.onRunStatement?(third)

        #expect(reported == nil)
    }

    @Test("The enabled state set before the editor exists is applied when it does")
    func enabledStateLatchesUntilInstall() {
        let subject = makeSubject()
        subject.setEnabled(false, in: nil)

        let controller = makeController(text: threeStatements)
        subject.install(on: controller)

        #expect(!controller.statementRunControlsEnabled)
    }

    // MARK: - Result jumps

    @Test("Selecting a result moves the caret to its statement and leaves the query as it was")
    func resultJumpMovesOnlyTheCaret() throws {
        let controller = makeController(text: threeStatements)
        let coordinator = SQLEditorCoordinator()
        coordinator.controller = controller
        let statements = SQLStatementScanner.executableStatements(in: threeStatements, grammar: .ansi)
        try #require(statements.count == 3)

        for index in [2, 0, 0] {
            #expect(coordinator.jumpToStatement(StatementAnchor(statements[index])), "result \(index)")
            #expect(
                controller.textView.selectionManager.textSelections.first?.range
                    == NSRange(location: statements[index].range.location, length: 0),
                "result \(index)"
            )
            #expect(controller.textView.string == threeStatements, "result \(index)")
        }
    }
}
