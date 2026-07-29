//
//  SqlWalkthroughPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SqlWalkthroughPresentation")
struct SqlWalkthroughPresentationTests {
    private func sql(lines count: Int, prefix: String) -> String {
        (1...count).map { "\(prefix)\($0)" }.joined(separator: "\n")
    }

    @Test("a short walkthrough reports nothing hidden in either layout")
    func shortWalkthroughHidesNothing() {
        let presentation = SqlWalkthroughPresentation(beforeSQL: "SELECT *\nFROM t", afterSQL: "SELECT id\nFROM t")

        #expect(presentation.hiddenLines(for: .unified) == 0)
        #expect(presentation.hiddenLines(for: .split) == 0)
        #expect(presentation.droppedInputLines == 0)
        #expect(presentation.unifiedLines.contains { $0.kind == .removed })
        #expect(presentation.unifiedLines.contains { $0.kind == .added })
    }

    @Test("an all-changed diff reports the unified rows it truncated")
    func allChangedDiffReportsHiddenUnifiedRows() {
        let limit = SqlWalkthroughPresentation.maxDisplayedLines
        let lineCount = limit - 50
        let presentation = SqlWalkthroughPresentation(
            beforeSQL: sql(lines: lineCount, prefix: "before"),
            afterSQL: sql(lines: lineCount, prefix: "after")
        )

        #expect(presentation.unifiedLines.count == limit)
        #expect(presentation.hiddenLines(for: .unified) == lineCount * 2 - limit)
    }

    @Test("split truncation is reported, not silent")
    func splitTruncationIsReported() {
        let limit = SqlWalkthroughPresentation.maxDisplayedLines
        let lineCount = limit + 120
        let presentation = SqlWalkthroughPresentation(
            beforeSQL: sql(lines: lineCount, prefix: "line"),
            afterSQL: sql(lines: lineCount, prefix: "line")
        )

        #expect(presentation.splitPairs.count == limit)
        #expect(presentation.hiddenLines(for: .split) == lineCount - limit)
    }

    @Test("an oversized query is capped before diffing and the drop is reported")
    func oversizedInputIsCappedAndReported() {
        let overage = 40
        let lineCount = SqlWalkthroughPresentation.maxInputLines + overage
        let presentation = SqlWalkthroughPresentation(
            beforeSQL: sql(lines: lineCount, prefix: "line"),
            afterSQL: sql(lines: lineCount, prefix: "line")
        )

        #expect(presentation.beforeLines.count == SqlWalkthroughPresentation.maxInputLines)
        #expect(presentation.afterLines.count == SqlWalkthroughPresentation.maxInputLines)
        #expect(presentation.droppedInputLines == overage * 2)
        #expect(presentation.hiddenLines(for: .unified) > 0)
    }

    @Test("a source listing without a rewrite reports its own truncation")
    func sourceListingReportsTruncation() {
        let limit = SqlWalkthroughPresentation.maxDisplayedLines
        let lineCount = limit + 25
        let presentation = SqlWalkthroughPresentation(beforeSQL: sql(lines: lineCount, prefix: "line"), afterSQL: nil)

        #expect(presentation.sourceLines.count == limit)
        #expect(presentation.hiddenSourceListingLines == lineCount - limit)
        #expect(presentation.splitPairs.isEmpty)
        #expect(presentation.unifiedLines.isEmpty)
    }

    @Test("an out-of-range anchor resolves to nil instead of highlighting a wrong line")
    func outOfRangeAnchorResolvesToNil() {
        let presentation = SqlWalkthroughPresentation(beforeSQL: "SELECT 1", afterSQL: "SELECT 2")
        let valid = SqlWalkthroughAnchor(side: .before, startLine: 1, endLine: 1)
        let tooFar = SqlWalkthroughAnchor(side: .before, startLine: 5, endLine: 9)

        #expect(presentation.resolvedAnchor(valid) == valid)
        #expect(presentation.resolvedAnchor(tooFar) == nil)
        #expect(presentation.resolvedAnchor(nil) == nil)
    }

    @Test("an anchor snippet reads from the side it names")
    func anchorSnippetReadsNamedSide() {
        let presentation = SqlWalkthroughPresentation(beforeSQL: "old one\nold two", afterSQL: "new one\nnew two")

        let before = SqlWalkthroughAnchor(side: .before, startLine: 1, endLine: 2)
        let after = SqlWalkthroughAnchor(side: .after, startLine: 2, endLine: 2)
        let both = SqlWalkthroughAnchor(side: .both, startLine: 1, endLine: 1)

        #expect(presentation.anchoredSnippet(for: before) == "old one\nold two")
        #expect(presentation.anchoredSnippet(for: after) == "new two")
        #expect(presentation.anchoredSnippet(for: both) == "old one")
    }

    @Test("building the presentation twice from the same block yields the same value")
    func presentationIsDeterministic() {
        let block = SqlWalkthroughBlock(
            beforeSQL: "SELECT *\nFROM orders",
            envelope: SqlWalkthroughEnvelope(afterSQL: "SELECT id\nFROM orders", steps: [])
        )

        let first = SqlWalkthroughPresentation(block: block)
        let second = SqlWalkthroughPresentation(block: block)

        #expect(first == second)
    }
}
