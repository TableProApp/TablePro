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
