import AppKit
@testable import CodeEditTextView
import Testing

/// Covers the empty-selection line cut that backs Cmd+X cutting the current
/// line when nothing is selected.
@Suite
struct CutLineTests {
    @Test("Empty selection expands to the whole line including the trailing newline")
    func emptySelectionExpandsToLine() {
        let text = "line1\nline2\nline3" as NSString
        let caret = NSRange(location: 8, length: 0)
        let range = TextView.cutRange(for: caret, in: text)
        #expect(range == text.lineRange(for: caret))
        #expect(text.substring(with: range) == "line2\n")
    }

    @Test("Non-empty selection is returned unchanged")
    func nonEmptySelectionUnchanged() {
        let text = "line1\nline2" as NSString
        let selection = NSRange(location: 0, length: 5)
        #expect(TextView.cutRange(for: selection, in: text) == selection)
    }

    @Test("Multi-line non-empty selection is returned unchanged")
    func multiLineSelectionUnchanged() {
        let text = "line1\nline2\nline3" as NSString
        let selection = NSRange(location: 3, length: 6)
        #expect(TextView.cutRange(for: selection, in: text) == selection)
    }

    @Test("Caret on the first line cuts the line plus its trailing newline")
    func firstLineCutsWithNewline() {
        let text = "line1\nline2\nline3" as NSString
        let range = TextView.cutRange(for: NSRange(location: 2, length: 0), in: text)
        #expect(range == NSRange(location: 0, length: 6))
        #expect(text.substring(with: range) == "line1\n")
    }

    @Test("Caret at the start of a middle line cuts that line plus its newline")
    func middleLineFromStartCutsWithNewline() {
        let text = "line1\nline2\nline3" as NSString
        let range = TextView.cutRange(for: NSRange(location: 6, length: 0), in: text)
        #expect(range == NSRange(location: 6, length: 6))
        #expect(text.substring(with: range) == "line2\n")
    }

    @Test("Caret on an empty line cuts just the newline")
    func emptyLineCutsJustNewline() {
        let text = "line1\n\nline3" as NSString
        let range = TextView.cutRange(for: NSRange(location: 6, length: 0), in: text)
        #expect(text.substring(with: range) == "\n")
    }

    @Test("Empty text returns an empty range")
    func emptyTextReturnsEmptyRange() {
        let text = "" as NSString
        let range = TextView.cutRange(for: NSRange(location: 0, length: 0), in: text)
        #expect(range.length == 0)
    }

    @Test("Caret on the last line without a trailing newline cuts to the end")
    func lastLineWithoutTrailingNewline() {
        let text = "a\nb" as NSString
        let range = TextView.cutRange(for: NSRange(location: 2, length: 0), in: text)
        #expect(text.substring(with: range) == "b")
    }

    @Test("Out-of-bounds caret is returned unchanged")
    func outOfBoundsCaretUnchanged() {
        let text = "abc" as NSString
        let caret = NSRange(location: 99, length: 0)
        #expect(TextView.cutRange(for: caret, in: text) == caret)
    }
}
