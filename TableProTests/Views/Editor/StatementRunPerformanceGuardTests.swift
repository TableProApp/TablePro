//
//  StatementRunPerformanceGuardTests.swift
//  TableProTests
//
//  The run controls need every statement in the document, which is a full pass. Measured at 31ms on a document at the
//  size limit, well past a frame, which is why that refresh is debounced and the band resolves one statement instead.
//  These hold both halves of that bargain.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Statement decoration performance guards")
struct StatementRunPerformanceGuardTests {

    @Test("A full scan of a large script stays fast enough to run on a typing pause")
    func fullScanOfLargeScriptIsFast() {
        let text = String(repeating: "SELECT id, name FROM users WHERE active = true;\n", count: 4_000)
        #expect((text as NSString).length > 150_000)

        let start = ProcessInfo.processInfo.systemUptime
        let statements = SQLStatementScanner.locatedStatements(in: text, dialect: .postgres)
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
        let statement = SQLStatementScanner.locatedStatementAtCursor(in: text, cursorPosition: 10, dialect: .postgres)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(statement.hasContent)
        #expect(elapsed < 0.01)
    }

    @Test("A single line of millions of characters does not stall the scan")
    func singleEnormousLine() {
        let text = "SELECT '" + String(repeating: "x", count: 2_000_000) + "';"

        let start = ProcessInfo.processInfo.systemUptime
        _ = SQLStatementScanner.locatedStatements(in: text, dialect: .postgres)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 1.0)
    }

    @Test("Block tracking does not make a script of routine bodies quadratic")
    func routineBodiesStayLinear() {
        let text = String(repeating: "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND;\n", count: 10_000)

        let start = ProcessInfo.processInfo.systemUptime
        let statements = SQLStatementScanner.locatedStatements(in: text, dialect: .mysql)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(statements.filter(\.hasContent).count == 10_000)
        #expect(elapsed < 0.5)
    }

    @Test("The debounce is short enough to feel immediate and long enough to coalesce typing")
    func refreshDelayIsSane() {
        #expect(StatementRunController.refreshDelay >= .milliseconds(50))
        #expect(StatementRunController.refreshDelay <= .milliseconds(300))
    }
}
