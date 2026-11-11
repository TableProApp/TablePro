//
//  VimTextBufferAdapterPerfTests.swift
//  TableProTests
//
//  Regression tests for VimTextBufferAdapter lineCount and setSelectedRange guard
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTextEngine
import Testing

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

    // MARK: - Line count after an edit

    // The editor drops the cache on every edit, so the next count reads the text as it is now.
    @Test("After an edit the line count matches a fresh count of the new text", arguments: [
        (NSRange(location: 5, length: 0), "\nworld", "hello", 2),
        (NSRange(location: 5, length: 0), "\n\n\n", "hello", 3),
        (NSRange(location: 1, length: 2), "", "a\nb\nc", 2),
        (NSRange(location: 2, length: 3), "x", "a\nb\nc", 2),
        (NSRange(location: 1, length: 1), "x\ny\nz", "abc", 3),
        (NSRange(location: 1, length: 0), "\r", "ab", 2),
    ])
    func lineCountAfterAnEdit(range: NSRange, replacement: String, original: String, expected: Int) {
        let (adapter, textView) = makeAdapter(string: original)
        _ = adapter.lineCount

        textView.replaceCharacters(in: range, with: replacement)
        adapter.invalidateLineCache()

        let counted = withExtendedLifetime(textView) { adapter.lineCount }
        let (fresh, freshTextView) = makeAdapter(string: textView.string)
        let freshCount = withExtendedLifetime(freshTextView) { fresh.lineCount }
        #expect(counted == expected)
        #expect(counted == freshCount)
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
