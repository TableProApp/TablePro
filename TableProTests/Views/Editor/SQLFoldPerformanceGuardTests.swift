//
//  SQLFoldPerformanceGuardTests.swift
//  TableProTests
//
//  Code folding walks the whole document, which is the path that froze the editor on a large paste (#1654). These
//  tests hold the guards that make it safe to enable folding by default.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL folding performance guards")
@MainActor
struct SQLFoldPerformanceGuardTests {

    private func makeController(text: String, foldingSizeLimit: Int) -> TextViewController {
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: .init(foldingSizeLimit: foldingSizeLimit)
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

    @Test("The provider returns no folds for a document past the size limit")
    func providerStopsAboveSizeLimit() {
        let text = String(repeating: "CREATE TABLE t (\n  id INT\n);\n", count: 400)
        let controller = makeController(text: text, foldingSizeLimit: 64)
        let provider = SQLLineFoldProvider(dialect: .postgres)

        let info = provider.foldLevelAtLine(
            lineNumber: 0,
            lineRange: NSRange(location: 0, length: 16),
            previousDepth: 0,
            controller: controller
        )
        #expect(info.isEmpty)
    }

    @Test("The provider still folds a document inside the size limit")
    func providerWorksBelowSizeLimit() {
        let text = "CREATE TABLE t (\n  id INT\n);\n"
        let controller = makeController(text: text, foldingSizeLimit: .max)
        let provider = SQLLineFoldProvider(dialect: .postgres)

        let info = provider.foldLevelAtLine(
            lineNumber: 0,
            lineRange: NSRange(location: 0, length: 17),
            previousDepth: 0,
            controller: controller
        )
        #expect(!info.isEmpty)
    }

    @Test("Scanning a large document stays linear enough to run on a paste")
    func scanOfLargeDocumentIsFast() {
        let text = String(repeating: "CREATE TABLE t (\n  id INT,\n  name TEXT\n);\n", count: 4_000) as NSString
        #expect(text.length > 100_000)

        let start = ProcessInfo.processInfo.systemUptime
        let structure = SQLFoldScanner.scan(text, dialect: .postgres)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(!structure.startsByLine.isEmpty)
        #expect(elapsed < 1.0)
    }

    @Test("A single line of millions of characters does not stall the scanner")
    func singleEnormousLine() {
        let text = ("SELECT '" + String(repeating: "x", count: 2_000_000) + "';") as NSString

        let start = ProcessInfo.processInfo.systemUptime
        _ = SQLFoldScanner.scan(text, dialect: .postgres)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        #expect(elapsed < 1.0)
    }
}
