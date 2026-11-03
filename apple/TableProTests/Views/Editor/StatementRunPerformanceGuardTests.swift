//
//  StatementRunPerformanceGuardTests.swift
//  TableProTests
//
//  The run controls need every statement in the document, which is a full pass. Measured at 31ms on a document at the
//  size limit, well past a frame, which is why that refresh is debounced and the band resolves one statement instead.
//  These hold both halves of that bargain.
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

struct StatementRunPerformanceGuardTests {

    @Test("A full scan of a large script stays fast enough to run on a typing pause")
    func fullScanOfLargeScriptIsFast() {
        let text = String(repeating: "SELECT id, name FROM users WHERE active = true;\n", count: 4_000)
        #expect((text as NSString).length > 150_000)

        let start = ProcessInfo.processInfo.systemUptime
        let statements = SQLStatementScanner.locatedStatements(in: text, grammar: TestGrammar.postgres)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(statements.count == 4_001)
        #expect(elapsed < 0.5)
    }

    /// The band resolves through the cursor entry point, which stops at the caret rather than walking the rest of the
    /// document. A caret near the top of a large script therefore costs almost nothing, which is what lets the band
    /// refresh on every keystroke while the controls wait out a debounce.
    @Test("Resolving the caret's statement near the top of a large script is cheap")
    func caretResolutionStopsAtTheCaret() {
        let text = String(repeating: "SELECT id, name FROM users WHERE active = true;\n", count: 40_000)

        let start = ProcessInfo.processInfo.systemUptime
        let statement = SQLStatementScanner.locatedStatementAtCursor(
            in: text,
            cursorPosition: 10,
            grammar: TestGrammar.postgres
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(statement.hasContent)
        #expect(elapsed < 0.01)
    }

    @Test("A single line of millions of characters does not stall the scan")
    func singleEnormousLine() {
        let text = "SELECT '" + String(repeating: "x", count: 2_000_000) + "';"

        let start = ProcessInfo.processInfo.systemUptime
        _ = SQLStatementScanner.locatedStatements(in: text, grammar: TestGrammar.postgres)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 1.0)
    }

    /// The same scan takes up to twice as long on one CI run as on another, so a fixed limit cannot tell a slow runner
    /// from a slow scanner. The scanner is timed against itself instead. Four scans of a script and one scan of a script
    /// four times as long do the same work when scanning is linear, and the long one takes four times as long when it is
    /// quadratic, so a bound of twice sits a factor of two from each. With equal work per sample a stall is as likely to
    /// land on either side, and the fastest of three drops the samples it landed on.
    @Test("Block tracking does not make a script of routine bodies quadratic")
    func routineBodiesStayLinear() {
        let routine = "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\n"
        let short = String(repeating: routine, count: 2_000)
        let long = String(repeating: routine, count: 8_000)

        var shortCount = 0
        var longCount = 0
        var fourShortScans = TimeInterval.infinity
        var oneLongScan = TimeInterval.infinity
        for _ in 0..<3 {
            fourShortScans = min(fourShortScans, Self.secondsSpent {
                for _ in 0..<4 {
                    shortCount = Self.routineCount(in: short)
                }
            })
            oneLongScan = min(oneLongScan, Self.secondsSpent { longCount = Self.routineCount(in: long) })
        }

        #expect(shortCount == 2_000)
        #expect(longCount == 8_000)
        #expect(oneLongScan < fourShortScans * 2)
    }

    @Test("The debounce is short enough to feel immediate and long enough to coalesce typing")
    func refreshDelayIsSane() {
        #expect(StatementRunController.refreshDelay >= .milliseconds(50))
        #expect(StatementRunController.refreshDelay <= .milliseconds(300))
    }

    private static func routineCount(in script: String) -> Int {
        SQLStatementScanner.locatedStatements(in: script, grammar: TestGrammar.mysql).filter(\.hasContent).count
    }

    private static func secondsSpent(_ work: () -> Void) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        return ProcessInfo.processInfo.systemUptime - start
    }
}
