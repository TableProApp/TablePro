import Testing
import AppKit
@testable import CodeEditTextView

/// Regression tests for IME commits (Pinyin / Rime / any system that uses marked text).
///
/// `TextView.insertText(_:replacementRange:)` used to call `unmarkText()` first and then
/// `_insertText` with the same `replacementRange` AppKit had supplied, which by then pointed
/// at characters that no longer existed because `unmarkText` had already shrunk the document.
/// The result was either content corruption (range still in bounds, but pointing at the wrong
/// chars) or a cursor that landed at `documentLength` after a clamped out-of-bounds replace —
/// the latter is what users see as "scrolls to end of script after typing a Chinese word".
/// See TableProApp/TablePro#1012.
@Suite
@MainActor
struct IMEInputTests {
    private func makeLaidOutTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        return textView
    }

    /// Builds marked text "ceshi" character-by-character at the current selection,
    /// matching how an IME progressively shows the in-progress romaji string.
    private func typeMarkedCeshi(on textView: TextView) {
        for (index, segment) in ["c", "ce", "ces", "cesh", "ceshi"].enumerated() {
            textView.setMarkedText(
                segment,
                selectedRange: NSRange(location: index + 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
    }

    @Test("IME commit on an empty middle line preserves surrounding content")
    func imeCommitInTheMiddleDoesNotCorruptText() throws {
        let textView = makeLaidOutTextView("alpha\n\nbeta")
        textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))

        typeMarkedCeshi(on: textView)

        // After typing five characters of marked text starting at offset 6, the IME owns
        // the range (6, 5) and may pass it as `replacementRange` at commit.
        textView.insertText("测试", replacementRange: NSRange(location: 6, length: 5))

        #expect(textView.string == "alpha\n测试\nbeta")
        let caret = try #require(textView.selectionManager.textSelections.first)
        #expect(caret.range == NSRange(location: 8, length: 0))
    }

    @Test("IME commit at end of document keeps caret at the inserted text, not at length")
    func imeCommitAtEndKeepsCaretAtInsertedText() throws {
        let textView = makeLaidOutTextView("alpha")
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))

        typeMarkedCeshi(on: textView)
        textView.insertText("测试", replacementRange: NSRange(location: 5, length: 5))

        #expect(textView.string == "alpha测试")
        let caret = try #require(textView.selectionManager.textSelections.first)
        #expect(caret.range == NSRange(location: 7, length: 0))
    }

    @Test("IME commit with NSNotFound replacement range still inserts at the marked range")
    func imeCommitWithNotFoundReplacementRange() throws {
        let textView = makeLaidOutTextView("alpha\n\nbeta")
        textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))

        typeMarkedCeshi(on: textView)
        textView.insertText(
            "测试",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.string == "alpha\n测试\nbeta")
        let caret = try #require(textView.selectionManager.textSelections.first)
        #expect(caret.range == NSRange(location: 8, length: 0))
    }

    @Test("Marked-text state is cleared after a commit")
    func markedTextStateClearedAfterCommit() {
        let textView = makeLaidOutTextView("alpha\n\nbeta")
        textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))

        typeMarkedCeshi(on: textView)
        textView.insertText("测试", replacementRange: NSRange(location: 6, length: 5))

        #expect(textView.hasMarkedText() == false)
        #expect(textView.markedRange().location == NSNotFound)
    }

    @Test("Plain Latin insertText path is unaffected")
    func plainInsertTextIsUnaffected() {
        let textView = makeLaidOutTextView("alpha")
        textView.selectionManager.setSelectedRange(NSRange(location: 5, length: 0))

        // No setMarkedText calls — this is the non-IME path.
        textView.insertText(
            " beta",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.string == "alpha beta")
        #expect(textView.selectionManager.textSelections.first?.range == NSRange(location: 10, length: 0))
    }
}
