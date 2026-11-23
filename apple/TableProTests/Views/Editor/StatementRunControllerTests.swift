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

    // MARK: - Completion's statement

    private static let mixedScript = """
    SELECT 'a;b' FROM t;
    -- a note; still a comment
    INSERT INTO t VALUES (1);
    /* block ; */ UPDATE t SET x = "q;" WHERE y = 1;
    CREATE PROCEDURE p() BEGIN SELECT 1; END;
    SELECT $$ dollar ; body $$;
    SELECT 1 # hash ; comment
    ;

    """

    private static let completionGrammars: [SQLLexicalGrammar] = [
        TestGrammar.standard, TestGrammar.mysql, TestGrammar.postgres, TestGrammar.sqlite,
        TestGrammar.sqlServer, TestGrammar.oracle,
    ]

    private func expectFreshScan(
        _ statement: SQLStatementScanner.LocatedStatement?,
        at caret: Int,
        in text: String,
        grammar: SQLLexicalGrammar,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let fresh = SQLStatementScanner.locatedStatementAtCursor(in: text, cursorPosition: caret, grammar: grammar)
        #expect(statement?.range == fresh.range, "caret \(caret)", sourceLocation: sourceLocation)
        #expect(statement?.hasContent == fresh.hasContent, "caret \(caret)", sourceLocation: sourceLocation)
    }

    @Test("Completion's statement equals a fresh scan at any caret, across edits", arguments: 0..<6)
    func maintainedStatementEqualsAFreshScan(grammarIndex: Int) throws {
        let grammar = Self.completionGrammars[grammarIndex]
        let controller = makeController(text: String(repeating: Self.mixedScript, count: 30))
        let subject = makeSubject(grammar: grammar)
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)
        let insertions = ["x", ";", "'", "\n", "--", "/*", "*/", " ", "$$", "#"]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(grammarIndex)
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }

        for _ in 0..<40 {
            let length = storage.length
            if next(3) == 0, length > 3 {
                controller.textView.replaceCharacters(in: NSRange(location: next(length - 3), length: next(3) + 1), with: "")
            } else {
                controller.textView.replaceCharacters(
                    in: NSRange(location: next(length + 1), length: 0),
                    with: insertions[next(insertions.count)]
                )
            }
            let text = controller.textView.string
            for _ in 0..<5 {
                let caret = next((text as NSString).length + 1)
                if next(2) == 0 {
                    _ = band(at: caret, in: controller, subject: subject)
                }
                let found = subject.maintainedStatement(at: caret, in: text, storage: storage)
                #expect(found?.grammar == grammar)
                expectFreshScan(found?.statement, at: caret, in: text, grammar: grammar)
            }
        }
    }

    @Test("Completion gets no statement where the band does not keep the index")
    func maintainedStatementOnlyWhereTheBandKeepsTheIndex() throws {
        let controller = makeController(text: threeStatements)
        let storage = try #require(controller.textView.textStorage)
        let text = controller.textView.string

        for model in [QueryStatementModel.redis, .javascript] {
            let subject = makeSubject()
            subject.statementModel = model
            subject.install(on: controller)
            #expect(subject.maintainedStatement(at: 3, in: text, storage: storage) == nil)
        }

        let bandOff = makeSubject()
        bandOff.isHighlightEnabled = false
        #expect(bandOff.maintainedStatement(at: 3, in: text, storage: storage) == nil)

        let tooLong = makeSubject(sizeLimit: 10)
        #expect(tooLong.maintainedStatement(at: 3, in: text, storage: storage) == nil)

        #expect(makeSubject().maintainedStatement(at: 3, in: text, storage: storage) != nil)
    }

    @Test("Asking for the caret the band just resolved scans nothing")
    func secondAskForTheSameCaretScansNothing() throws {
        let controller = makeController(text: String(repeating: "SELECT 1;\n", count: 5_000) + "SELECT * FROM t WHERE ")
        let subject = makeSubject()
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)
        let text = controller.textView.string
        let caret = storage.length

        _ = band(at: caret, in: controller, subject: subject)
        let scanned = subject.caretIndexUnitsScanned
        let found = subject.maintainedStatement(at: caret, in: text, storage: storage)

        #expect(subject.caretIndexUnitsScanned == scanned)
        expectFreshScan(found?.statement, at: caret, in: text, grammar: TestGrammar.standard)
    }

    @Test("An edit, a grammar change and another storage each drop the remembered statement")
    func rememberedStatementIsDroppedWhenTheTextOrSplitChanges() throws {
        let script = "SELECT 1 # note ; still the note\nSELECT 2;\nSELECT * FROM t"
        let controller = makeController(text: script)
        let subject = makeSubject(grammar: TestGrammar.mysql)
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)
        let caret = (script as NSString).range(of: "still").location

        let first = subject.maintainedStatement(at: caret, in: controller.textView.string, storage: storage)
        expectFreshScan(first?.statement, at: caret, in: controller.textView.string, grammar: TestGrammar.mysql)

        subject.grammar = TestGrammar.standard
        let regrammared = subject.maintainedStatement(at: caret, in: controller.textView.string, storage: storage)
        expectFreshScan(regrammared?.statement, at: caret, in: controller.textView.string, grammar: TestGrammar.standard)
        #expect(regrammared?.statement.range != first?.statement.range)

        controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "SELECT 0;")
        let edited = subject.maintainedStatement(at: caret, in: controller.textView.string, storage: storage)
        expectFreshScan(edited?.statement, at: caret, in: controller.textView.string, grammar: TestGrammar.standard)

        let other = makeController(text: "SELECT 9;\nSELECT 8; SELECT 7; SELECT 6; SELECT 5; SELECT 4;")
        let otherStorage = try #require(other.textView.textStorage)
        let swapped = subject.maintainedStatement(at: caret, in: other.textView.string, storage: otherStorage)
        expectFreshScan(swapped?.statement, at: caret, in: other.textView.string, grammar: TestGrammar.standard)
    }

    // MARK: - Completion's statement where the band does not keep the index

    @Test("Past the size limit completion's statement is warmed off the main thread and equals a fresh scan")
    func warmedStatementPastTheSizeLimitEqualsAFreshScan() async throws {
        let controller = makeController(text: String(repeating: Self.mixedScript, count: 30))
        let subject = makeSubject(grammar: TestGrammar.mysql, sizeLimit: 100)
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)
        var seed: UInt64 = 0x51_7CC1_B727_220A
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }

        for _ in 0..<20 {
            controller.textView.replaceCharacters(
                in: NSRange(location: next(storage.length + 1), length: 0),
                with: [";", "'", "x", "\n", "#"][next(5)]
            )
            let text = controller.textView.string
            for _ in 0..<3 {
                let caret = next((text as NSString).length + 1)
                let statement = await subject.warmedStatement(
                    at: caret, in: text, storage: storage, grammar: TestGrammar.mysql
                )
                expectFreshScan(statement, at: caret, in: text, grammar: TestGrammar.mysql)
            }
        }
    }

    @Test("A warmed index is kept, so the next request near the caret rescans only near it")
    func warmedIndexIsKeptForTheNextRequest() async throws {
        let controller = makeController(text: String(repeating: "SELECT 1;\n", count: 5_000))
        let subject = makeSubject(sizeLimit: 100)
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)
        _ = await subject.warmedStatement(
            at: storage.length, in: controller.textView.string, storage: storage, grammar: TestGrammar.standard
        )
        let warmed = subject.caretIndexUnitsScanned
        #expect(warmed >= storage.length)

        controller.textView.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "SELECT ")
        let text = controller.textView.string
        let statement = await subject.warmedStatement(
            at: storage.length, in: text, storage: storage, grammar: TestGrammar.standard
        )

        expectFreshScan(statement, at: storage.length, in: text, grammar: TestGrammar.standard)
        #expect(subject.caretIndexUnitsScanned - warmed <= SQLStatementCursorIndex.defaultCheckpointSpacing + 40)
    }

    @Test("An edit made while a warm runs trims the index it leaves to the text as it is now")
    func editDuringAWarmTrimsTheIndex() throws {
        let script = String(repeating: "SELECT 1;\n", count: 3_000)
        let controller = makeController(text: script)
        let subject = makeSubject(sizeLimit: 100)
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)
        let caret = storage.length

        let ticket = subject.beginWarm(storage: storage)
        var warmed = ticket.index
        let statement = warmed.statementAtCursor(caret, in: script)
        controller.textView.replaceCharacters(in: NSRange(location: 15_000, length: 0), with: "/*")
        subject.finishWarm(ticket, warmed: warmed, cursor: caret, statement: statement)

        let text = controller.textView.string
        let ends = [storage.length, 20_000, 14_000]
        for end in ends {
            expectFreshScan(
                subject.statement(at: end, in: text, storage: storage),
                at: end, in: text, grammar: TestGrammar.standard
            )
        }
    }

    @Test("A warm that comes back after the grammar changed is not kept, and another grammar gets no statement")
    func warmAcrossAGrammarChangeIsDropped() async throws {
        let controller = makeController(text: String(repeating: "SELECT 1;\n", count: 1_000))
        let subject = makeSubject(sizeLimit: 100)
        subject.install(on: controller)
        let storage = try #require(controller.textView.textStorage)

        let ticket = subject.beginWarm(storage: storage)
        var warmed = ticket.index
        let statement = warmed.statementAtCursor(storage.length, in: controller.textView.string)
        subject.grammar = TestGrammar.mysql
        subject.finishWarm(ticket, warmed: warmed, cursor: storage.length, statement: statement)

        #expect(subject.caretIndexUnitsScanned == 0)
        let other = await subject.warmedStatement(
            at: 0, in: controller.textView.string, storage: storage, grammar: TestGrammar.standard
        )
        #expect(other == nil)
    }
}
