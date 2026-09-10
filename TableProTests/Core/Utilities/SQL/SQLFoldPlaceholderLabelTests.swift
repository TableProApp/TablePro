//
//  SQLFoldPlaceholderLabelTests.swift
//  TableProTests
//

import CodeEditSourceEditor
import Foundation
import Testing
@testable import TablePro

@Suite("Fold placeholder summary")
struct FoldPlaceholderSummaryTests {

    private func summarize(_ text: String, from lower: Int, to upper: Int, lines: Int) -> FoldPlaceholderSummary {
        FoldPlaceholderSummary.summarize(
            content: text as NSString,
            foldRange: lower..<upper,
            hiddenLineCount: lines
        )
    }

    @Test("Newlines and runs of spaces collapse to single spaces")
    func collapsesWhitespace() {
        let text = "(\n    id BIGSERIAL,\n    name TEXT\n)"
        let summary = summarize(text, from: 1, to: text.utf16.count, lines: 3)
        #expect(summary.previewText == "id BIGSERIAL, name TEXT )")
        #expect(summary.hiddenLineCount == 3)
    }

    @Test("A long preview is truncated with an ellipsis")
    func truncatesLongPreview() {
        let text = String(repeating: "a", count: 300)
        let summary = summarize(text, from: 0, to: text.utf16.count, lines: 5)
        #expect(summary.previewText.hasSuffix("\u{2026}"))
        #expect(summary.previewText.count == FoldPlaceholderSummary.maxPreviewLength + 1)
    }

    @Test("Only the scan window is read, so a huge fold costs the same as a small one")
    func readsOnlyTheScanWindow() {
        let text = String(repeating: "x", count: 5_000_000)
        let summary = summarize(text, from: 0, to: text.utf16.count, lines: 1)
        #expect(summary.previewText.count <= FoldPlaceholderSummary.maxPreviewLength + 1)
    }

    @Test("An empty fold yields an empty preview")
    func emptyFold() {
        let summary = summarize("abc", from: 1, to: 1, lines: 0)
        #expect(summary.previewText.isEmpty)
        #expect(summary.hiddenLineCount == 0)
    }

    @Test("A range beyond the content is clamped instead of trapping")
    func clampsOutOfBoundsRange() {
        let summary = summarize("abc", from: 2, to: 900, lines: 2)
        #expect(summary.previewText == "c")
    }

    @Test("A negative hidden line count is clamped to zero")
    func clampsNegativeLineCount() {
        #expect(summarize("abc", from: 0, to: 3, lines: -4).hiddenLineCount == 0)
    }
}

@Suite("SQL fold placeholder label")
@MainActor
struct SQLFoldPlaceholderLabelTests {

    @Test("The label pairs the preview with the hidden line count")
    func labelPairsPreviewAndCount() {
        let provider = SQLLineFoldProvider()
        let label = provider.foldPlaceholderLabel(
            for: FoldPlaceholderSummary(previewText: "id BIGSERIAL", hiddenLineCount: 12)
        )
        #expect(label.contains("id BIGSERIAL"))
        #expect(label.contains("12"))
    }

    @Test("A fold with no preview still reports its line count")
    func labelWithoutPreview() {
        let provider = SQLLineFoldProvider()
        let label = provider.foldPlaceholderLabel(
            for: FoldPlaceholderSummary(previewText: "", hiddenLineCount: 3)
        )
        #expect(label.contains("3"))
    }

    @Test("A fold hiding no lines shows only its preview")
    func labelWithoutHiddenLines() {
        let provider = SQLLineFoldProvider()
        let label = provider.foldPlaceholderLabel(
            for: FoldPlaceholderSummary(previewText: "id INT", hiddenLineCount: 0)
        )
        #expect(label == "id INT")
    }
}
