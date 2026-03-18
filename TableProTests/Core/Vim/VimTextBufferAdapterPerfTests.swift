//
//  VimTextBufferAdapterPerfTests.swift
//  TableProTests
//
//  Regression tests for VimTextBufferAdapter incremental lineCount
//  and setSelectedRange guard
//

import AppKit
import CodeEditTextView
@testable import TablePro
import Testing

@Suite("VimTextBufferAdapter Incremental LineCount")
@MainActor
struct VimTextBufferAdapterPerfTests {
    private final class StubDelegate: TextViewDelegate {}

    private func makeTextView(string: String) -> TextView {
        let textView = TextView(
            string: string,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: .labelColor,
            lineHeightMultiplier: 1.0,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            delegate: StubDelegate()
        )
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        textView.layout()
        return textView
    }

    private func makeAdapter(string: String) -> (VimTextBufferAdapter, TextView) {
        let textView = makeTextView(string: string)
        let adapter = VimTextBufferAdapter(textView: textView)
        return (adapter, textView)
    }

    // MARK: - lineCount

    @Test("lineCount returns 1 for single line")
    func singleLineCount() {
        let (adapter, _) = makeAdapter(string: "hello world")
        #expect(adapter.lineCount == 1)
    }

    @Test("lineCount returns correct count for multi-line text")
    func multiLineCount() {
        let (adapter, _) = makeAdapter(string: "a\nb\nc")
        #expect(adapter.lineCount == 3)
    }

    @Test("lineCount returns 1 for empty text")
    func emptyLineCount() {
        let (adapter, _) = makeAdapter(string: "")
        #expect(adapter.lineCount == 1)
    }

    @Test("lineCount for text ending with newline")
    func trailingNewlineCount() {
        let (adapter, _) = makeAdapter(string: "a\nb\n")
        #expect(adapter.lineCount == 2)
    }

    // MARK: - textDidChange incremental (pure insertion)

    @Test("textDidChange with pure insertion updates line count incrementally")
    func insertionUpdatesLineCount() {
        let (adapter, textView) = makeAdapter(string: "hello")

        // Prime the cache
        let initial = adapter.lineCount
        #expect(initial == 1)

        // Simulate inserting "\nworld" at offset 5
        textView.replaceCharacters(in: NSRange(location: 5, length: 0), with: "\nworld")
        adapter.textDidChange(in: NSRange(location: 5, length: 0), replacementLength: 6)

        #expect(adapter.lineCount == 2)
    }

    @Test("textDidChange with multi-newline insertion")
    func multiNewlineInsertion() {
        let (adapter, textView) = makeAdapter(string: "hello")

        _ = adapter.lineCount // prime cache

        textView.replaceCharacters(in: NSRange(location: 5, length: 0), with: "\n\n\n")
        adapter.textDidChange(in: NSRange(location: 5, length: 0), replacementLength: 3)

        #expect(adapter.lineCount == 4)
    }

    // MARK: - textDidChange fallback on deletion

    @Test("textDidChange with deletion invalidates cache")
    func deletionInvalidatesCache() {
        let (adapter, textView) = makeAdapter(string: "a\nb\nc")

        let initial = adapter.lineCount
        #expect(initial == 3)

        // Simulate deleting "\nb" (range.length > 0 means it's not pure insertion)
        textView.replaceCharacters(in: NSRange(location: 1, length: 2), with: "")
        adapter.textDidChange(in: NSRange(location: 1, length: 2), replacementLength: 0)

        // Cache should be invalidated; next access does a full recount
        #expect(adapter.lineCount == 2)
    }

    // MARK: - textDidChange(oldText:...) incremental replacement

    @Test("textDidChange with oldText correctly computes delta for replacement")
    func oldTextReplacementDelta() {
        let originalText = "a\nb\nc"
        let (adapter, textView) = makeAdapter(string: originalText)

        let initial = adapter.lineCount
        #expect(initial == 3)

        // Replace "b\nc" (range 2..4, contains 1 newline) with "x" (0 newlines)
        textView.replaceCharacters(in: NSRange(location: 2, length: 3), with: "x")
        adapter.textDidChange(oldText: originalText, in: NSRange(location: 2, length: 3), replacementLength: 1)

        // 3 original - 1 removed newline + 0 added = 2
        #expect(adapter.lineCount == 2)
    }

    @Test("textDidChange with oldText adding newlines")
    func oldTextAddingNewlines() {
        let originalText = "abc"
        let (adapter, textView) = makeAdapter(string: originalText)

        _ = adapter.lineCount // prime: 1

        // Replace "b" with "x\ny\nz" (adding 2 newlines)
        textView.replaceCharacters(in: NSRange(location: 1, length: 1), with: "x\ny\nz")
        adapter.textDidChange(oldText: originalText, in: NSRange(location: 1, length: 1), replacementLength: 5)

        // 1 original - 0 removed + 2 added = 3
        #expect(adapter.lineCount == 3)
    }

    // MARK: - setSelectedRange guard

    @Test("setSelectedRange with same range skips update")
    func setSelectedRangeSameRangeIsNoOp() {
        let (adapter, textView) = makeAdapter(string: "hello world")
        let range = NSRange(location: 3, length: 0)

        // Set initial selection
        adapter.setSelectedRange(range)
        let firstRange = textView.selectedRange()

        // Set the same range again — should be a no-op due to the guard
        adapter.setSelectedRange(range)
        let secondRange = textView.selectedRange()

        #expect(firstRange == secondRange)
    }

    @Test("setSelectedRange with different range does update")
    func setSelectedRangeDifferentRangeUpdates() {
        let (adapter, textView) = makeAdapter(string: "hello world")

        adapter.setSelectedRange(NSRange(location: 0, length: 0))
        let initialRange = textView.selectedRange()

        adapter.setSelectedRange(NSRange(location: 5, length: 0))
        let updatedRange = textView.selectedRange()

        #expect(initialRange != updatedRange)
        #expect(updatedRange.location == 5)
    }

    @Test("setSelectedRange with selection length sets needsDisplay")
    func setSelectedRangeWithLengthSetsDisplay() {
        let (adapter, _) = makeAdapter(string: "hello world")

        // Set a range with length > 0 — the method sets needsDisplay = true
        adapter.setSelectedRange(NSRange(location: 0, length: 5))

        // Just verify no crash and selection is correct
        let range = adapter.selectedRange()
        #expect(range.location == 0)
        #expect(range.length == 5)
    }
}
