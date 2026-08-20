//
//  LineFoldRibbonLookupTests.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor

/// The ribbon draws one chevron per line that opens a fold, and that chevron has to fold the largest block starting
/// there. A statement and the parenthesised body inside it commonly begin on the same line, so without a rule the
/// chevron would fold whichever of the two happened to be found first.
@MainActor
struct LineFoldRibbonLookupTests {
    private let controller: TextViewController
    private let ribbon: LineFoldRibbonView

    init() {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.textView.string = "A\nB\nC\nD\nE\nF\n"
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1000, height: 1000))
        ribbon = LineFoldRibbonView(controller: controller)
    }

    private func setFolds(_ folds: [LineFoldStorage.RawFold]) {
        ribbon.model?.foldCache = LineFoldStorage(
            documentLength: controller.textView.textStorage.length,
            folds: folds
        )
    }

    private func lookup() -> [Int: FoldRange] {
        ribbon.foldsByStartLine(
            in: 0..<controller.textView.textStorage.length,
            layoutManager: controller.textView.layoutManager
        )
    }

    @Test("Two folds opening on one line leave the outermost on that line")
    func outermostFoldWins() {
        setFolds([
            LineFoldStorage.RawFold(depth: 2, range: 1..<8),
            LineFoldStorage.RawFold(depth: 1, range: 1..<10)
        ])

        #expect(lookup()[0]?.depth == 1)
    }

    @Test("The order the folds arrive in does not change which one wins")
    func orderDoesNotMatter() {
        setFolds([
            LineFoldStorage.RawFold(depth: 1, range: 1..<10),
            LineFoldStorage.RawFold(depth: 2, range: 1..<8)
        ])

        #expect(lookup()[0]?.depth == 1)
    }

    @Test("A fold is keyed to the line it opens on, not the lines it covers")
    func foldIsKeyedToItsOpeningLine() {
        setFolds([LineFoldStorage.RawFold(depth: 1, range: 5..<10)])

        let result = lookup()
        #expect(result[2]?.range == 5..<10)
        #expect(result[3] == nil, "A line inside the fold does not open it, so it gets no chevron")
        #expect(result[0] == nil)
    }

    @Test("A rect taller than the document still covers every line")
    func rectPastTheLastLineStillResolves() throws {
        // The ribbon is laid out taller than the text beside it, so the rect it is asked to draw routinely reaches
        // past the last line. Resolving that to nothing lost every chevron at the bottom of a document.
        let range = try #require(
            ribbon.documentRange(
                covering: NSRect(x: 0, y: 0, width: 14, height: 5000),
                layoutManager: controller.textView.layoutManager
            )
        )

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == controller.textView.textStorage.length)
    }

    @Test("A document with no folds draws no chevrons")
    func noFoldsNoChevrons() {
        setFolds([])

        #expect(lookup().isEmpty)
    }
}
