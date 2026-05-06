import Testing
import AppKit
@testable import CodeEditTextView

/// Regression tests for cmd+arrow (visualLine destination) when the cursor sits at, or one
/// position before, the end of a line that has no trailing newline.
/// See TableProApp/TablePro#1007.
@Suite
@MainActor
struct VisualLineEndOfDocumentTests {
    private func makeLaidOutTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        return textView
    }

    @Test("Cmd+Left at end of single-line query moves to beginning of line")
    func cmdLeftAtEndOfSingleLineDocument() {
        let textView = makeLaidOutTextView("SELECT * FROM users")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .backward,
            destination: .visualLine
        )

        #expect(range.location == 0)
        #expect(range.length == length)
    }

    @Test("Cmd+Right at last character of line extends selection to the line end")
    func cmdRightAtLastCharacter() {
        let textView = makeLaidOutTextView("SELECT * FROM users")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length - 1,
            direction: .forward,
            destination: .visualLine
        )

        #expect(range.location == length - 1)
        #expect(range.max == length)
    }

    @Test("Cmd+Right at end of single-line query stays at end")
    func cmdRightAtEndOfSingleLineDocument() {
        let textView = makeLaidOutTextView("SELECT * FROM users")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .forward,
            destination: .visualLine
        )

        #expect(range.max == length)
    }

    @Test("Cmd+Right on last line without trailing newline extends to line end")
    func cmdRightOnLastLineWithoutTrailingNewline() {
        let textView = makeLaidOutTextView("abc\ndef")
        // Cursor between 'e' and 'f' (offset 6); end of doc is 7.
        let range = textView.selectionManager.rangeOfSelection(
            from: 6,
            direction: .forward,
            destination: .visualLine
        )

        #expect(range.max == 7)
    }

    @Test("Cmd+Right on first line stops before trailing newline")
    func cmdRightOnFirstLineStopsBeforeNewline() {
        let textView = makeLaidOutTextView("abc\ndef")
        let range = textView.selectionManager.rangeOfSelection(
            from: 0,
            direction: .forward,
            destination: .visualLine
        )

        // Should land between 'c' and '\n' (offset 3), not include the newline.
        #expect(range.max == 3)
    }

    @Test("Cmd+Left at end of last line moves to start of last line")
    func cmdLeftAtEndOfLastLine() {
        let textView = makeLaidOutTextView("abc\ndef")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .backward,
            destination: .visualLine
        )

        // Should move to the start of the last line (offset 4).
        #expect(range.location == 4)
        #expect(range.max == length)
    }
}
