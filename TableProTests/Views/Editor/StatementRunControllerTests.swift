//
//  StatementRunControllerTests.swift
//  TableProTests
//
//  The gutter's run controls and the caret-statement band both come from here. A control that names the wrong range
//  runs the wrong statement, which is worse than having no control at all.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Statement run controls")
@MainActor
struct StatementRunControllerTests {

    private func makeController(text: String) -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
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

    private func makeSubject(dialect: SqlDialect = .generic, sizeLimit: Int? = nil) -> StatementRunController {
        let subject = StatementRunController()
        subject.dialect = dialect
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
        let subject = makeSubject(dialect: .mysql)
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

    // MARK: - Callback

    @Test("Pressing a control reports that control's own statement, not the caret's")
    func pressReportsItsOwnStatement() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        var reported: String?
        subject.onRun = { reported = $0 }
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
        subject.onRun = { reported = $0 }
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
}
