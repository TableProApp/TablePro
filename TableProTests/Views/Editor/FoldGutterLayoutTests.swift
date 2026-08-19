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
        let configuration = SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: .init(
                showGutter: true,
                showLineNumbers: showLineNumbers,
                showMinimap: false,
                showFoldingRibbon: showFoldingRibbon
            )
        )
        let controller = TextViewController(
            string: "SELECT 1;\nSELECT 2;\n",
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

    @Test("Line numbers still size the gutter")
    func numbersStillSizeTheGutter() {
        let numbers = gutterInset(showLineNumbers: true, showFoldingRibbon: false)
        let neither = gutterInset(showLineNumbers: false, showFoldingRibbon: false)
        #expect(numbers > neither)
    }
}
