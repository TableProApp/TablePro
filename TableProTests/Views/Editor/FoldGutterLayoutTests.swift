//
//  FoldGutterLayoutTests.swift
//  TableProTests
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import Testing
@testable import TablePro

@Suite("Fold gutter layout")
@MainActor
struct FoldGutterLayoutTests {

    /// The text view is inset by the gutter's width, so the inset is the gutter width as the reader sees it.
    private func gutterInset(showLineNumbers: Bool, showFoldingRibbon: Bool) -> CGFloat {
        gutterInset(
            peripherals: .init(
                showGutter: true,
                showLineNumbers: showLineNumbers,
                showMinimap: false,
                showFoldingRibbon: showFoldingRibbon
            ),
            text: "SELECT 1;\nSELECT 2;\n"
        )
    }

    private func gutterInset(peripherals: SourceEditorConfiguration.Peripherals, text: String) -> CGFloat {
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
            cursorPositions: []
        )
        controller.loadView()
        controller.textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 800, height: 600))
        return controller.textView.textInsets.left
    }

    @Test("An editor showing only the ribbon keeps a thin gutter")
    func ribbonOnlyGutterIsNarrow() {
        let withNumbers = gutterInset(showLineNumbers: true, showFoldingRibbon: true)
        let ribbonOnly = gutterInset(showLineNumbers: false, showFoldingRibbon: true)

        #expect(ribbonOnly < withNumbers, "Dropping the numbers must shrink the gutter")
        #expect(
            withNumbers - ribbonOnly >= 20,
            """
            A ribbon only gutter must drop the 20pt leading inset that only exists to keep numbers off the edge,             not just the width of the digits, got \(ribbonOnly) against \(withNumbers)
            """
        )
    }

    /// A one line listing used to be charged a 20pt window margin plus room for two digits it does not have, which
    /// put 35pt of nothing to the left of the "1".
    @Test("An inline listing pays for neither a window margin nor digits it has no lines for")
    func inlineGutterFitsItsContent() {
        let statement = "UPDATE `Album` SET `Title` = 'sa' WHERE `AlbumId` = '6';"
        let editor = gutterInset(
            peripherals: EditorPeripherals.editor(lineNumbers: true, folding: true),
            text: statement
        )
        let inline = gutterInset(
            peripherals: EditorPeripherals.inline(lineNumbers: true, folding: true),
            text: statement
        )

        #expect(
            editor - inline >= 30,
            "Dropping the 20pt margin and two unused digits must save over 30pt, got \(inline) against \(editor)"
        )
    }

    @Test("A long inline listing still reserves room for the digits it does have")
    func inlineGutterGrowsWithItsLineCount() {
        let peripherals = EditorPeripherals.inline(lineNumbers: true, folding: true)
        let short = gutterInset(peripherals: peripherals, text: "SELECT 1;")
        let long = gutterInset(
            peripherals: peripherals,
            text: (1...120).map { "SELECT \($0);" }.joined(separator: "\n")
        )

        #expect(long > short, "A 120 line listing needs three digits where a one line listing needs one")
    }

    @Test("Line numbers still size the gutter")
    func numbersStillSizeTheGutter() {
        let numbers = gutterInset(showLineNumbers: true, showFoldingRibbon: false)
        let neither = gutterInset(showLineNumbers: false, showFoldingRibbon: false)
        #expect(numbers > neither)
    }
}
