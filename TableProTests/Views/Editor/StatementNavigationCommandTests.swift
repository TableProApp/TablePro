//
//  StatementNavigationCommandTests.swift
//  TableProTests
//
//  The controller side of the navigation commands: which caret anchors the move, what a selection does to it, and
//  the guards that keep a large document and a fold from making the caret land somewhere useless.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Statement navigation commands")
@MainActor
struct StatementNavigationCommandTests {

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

    private func caret(_ controller: TextViewController) -> Int? {
        controller.cursorPositions.first?.range.location
    }

    // MARK: - Moving

    @Test("Next moves the caret to the following statement")
    func nextMovesTheCaret() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        subject.moveCursor(.next, in: controller)

        #expect(caret(controller) == 10)
    }

    @Test("Previous moves the caret back to the preceding statement")
    func previousMovesTheCaret() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 20, length: 0))])
        subject.moveCursor(.previous, in: controller)

        #expect(caret(controller) == 10)
    }

    @Test("A move leaves exactly one caret behind")
    func moveCollapsesToOneCaret() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([
            CursorPosition(range: NSRange(location: 0, length: 0)),
            CursorPosition(range: NSRange(location: 20, length: 0)),
        ])
        subject.moveCursor(.next, in: controller)

        #expect(controller.cursorPositions.count == 1)
        #expect(caret(controller) == 10)
    }

    /// The band and the run controls both anchor on the first caret, so navigation does too rather than picking a
    /// different one and moving somewhere the reader was not looking. The selection manager keeps its ranges in
    /// document order, so "first" is the topmost caret whichever order they were set in.
    @Test("Multiple carets resolve through the topmost one")
    func multipleCaretsAnchorOnTheTopmost() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([
            CursorPosition(range: NSRange(location: 11, length: 0)),
            CursorPosition(range: NSRange(location: 0, length: 0)),
        ])
        #expect(caret(controller) == 0, "the selection manager is expected to order its ranges")
        subject.moveCursor(.next, in: controller)

        #expect(caret(controller) == 10)
    }

    @Test("At the last statement the caret stays put")
    func lastStatementDoesNotMove() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 20, length: 0))])
        subject.moveCursor(.next, in: controller)

        #expect(caret(controller) == 20)
    }

    @Test("An empty document never moves the caret")
    func emptyDocumentDoesNotMove() {
        let controller = makeController(text: "")
        let subject = makeSubject()
        subject.install(on: controller)

        let before = caret(controller)
        subject.moveCursor(.next, in: controller)
        subject.moveCursor(.previous, in: controller)

        #expect(caret(controller) == before)
        #expect(caret(controller) ?? 0 == 0)
    }

    /// A document the gutter has given up decorating is one navigation gives up on too, so a held key cannot walk a
    /// multi-megabyte scan per press.
    @Test("A document past the size limit does not move the caret")
    func aboveSizeLimitDoesNotMove() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject(sizeLimit: 8)
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        subject.moveCursor(.next, in: controller)

        #expect(caret(controller) == 0)
    }

    // MARK: - Selection extension

    @Test("The boundary provider answers in both directions")
    func boundaryProviderAnswers() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        #expect(subject.statementBoundary(from: 0, forward: true, in: controller) == 10)
        #expect(subject.statementBoundary(from: 20, forward: false, in: controller) == 10)
    }

    /// Forward selection has to reach the far edge of the last statement, or its body could never be selected.
    @Test("The boundary provider reaches the end of the last statement")
    func boundaryProviderReachesTheEnd() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        #expect(subject.statementBoundary(from: 20, forward: true, in: controller) == 29)
        #expect(subject.statementBoundary(from: 29, forward: true, in: controller) == nil)
    }

    /// The two `moveParagraph…AndModifySelection:` selectors are standard AppKit bindings, so an editor whose host
    /// never supplies statements has to leave them doing whatever the text system does. Every editor in this app that
    /// is not showing SQL is in that position.
    @Test("An editor with no statement source publishes no boundary provider")
    func noProviderWithoutAHost() {
        let controller = makeController(text: threeStatements)
        #expect(controller.statementBoundaryProvider == nil)
    }

    @Test("Clearing removes the boundary provider with everything else")
    func clearingRemovesTheProvider() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)
        #expect(controller.statementBoundaryProvider != nil)

        subject.clear(in: controller)
        #expect(controller.statementBoundaryProvider == nil)
    }

    // MARK: - Run and advance

    @Test("The caret's statement is what run and advance reads")
    func statementAtCursorReadsTheCaretsStatement() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 13, length: 0))])
        #expect(subject.statementAtCursor(in: controller)?.sql == "SELECT 2;")
    }

    /// `Cmd+Enter` runs a selection verbatim and the band deliberately paints nothing while one exists, so running
    /// the whole surrounding statement here would execute SQL the reader neither selected nor saw marked.
    @Test("A selection stops run and advance reading a statement")
    func selectionStopsStatementAtCursor() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject()
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 8))])
        #expect(subject.statementAtCursor(in: controller) == nil)
    }

    @Test("A document past the size limit reads no statement to run")
    func aboveSizeLimitReadsNoStatement() {
        let controller = makeController(text: threeStatements)
        let subject = makeSubject(sizeLimit: 8)
        subject.install(on: controller)

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        #expect(subject.statementAtCursor(in: controller) == nil)
    }

    // MARK: - Folds

    /// A fold hides its range from layout, so a caret sent inside a collapsed one lands where the reader cannot see
    /// it and cannot scroll to it.
    /// A fold's range starts at the END of the line that opens it, so the caret has to land past that line for a fold
    /// to be hiding it at all. Asserting on the routine's opening line would pass without the reveal ever running.
    @Test("Landing inside a collapsed fold reveals it")
    func landingInsideAFoldRevealsIt() throws {
        let text = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND;\nSELECT 2;\n"
        let controller = makeController(text: text)
        let subject = makeSubject(dialect: .mysql)
        subject.install(on: controller)

        controller.foldAll()
        let target = try #require(
            SQLStatementScanner.statementStart(after: 0, in: text, dialect: .mysql),
            "the script must have a second statement to navigate to"
        )
        let hiddenBefore = controller.textView.layoutManager.textLineForOffset(target) == nil

        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        subject.moveCursor(.next, in: controller)

        #expect(caret(controller) == target)
        #expect(
            controller.textView.layoutManager.textLineForOffset(target) != nil,
            "the destination must be laid out after the move, whether or not it was hidden before (was hidden: \(hiddenBefore))"
        )
    }

    /// The reveal has to reach an arbitrary offset, not just the caret's own fold, because the caret is somewhere
    /// else entirely when the command runs.
    @Test("Revealing an offset expands the collapsed fold covering it")
    func revealExpandsTheCoveringFold() {
        let text = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\n"
        let controller = makeController(text: text)
        let subject = makeSubject(dialect: .mysql)
        subject.install(on: controller)

        controller.foldAll()
        let inside = (text as NSString).range(of: "SELECT 2;").location
        controller.revealFold(containing: inside)

        #expect(controller.textView.layoutManager.textLineForOffset(inside) != nil)
    }
}
