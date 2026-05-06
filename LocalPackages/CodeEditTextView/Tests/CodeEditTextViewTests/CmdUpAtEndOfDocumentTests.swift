import Testing
import AppKit
@testable import CodeEditTextView

/// Regression tests for vertical cursor moves when the cursor sits at the end of a line,
/// including the end of the document. Standard macOS NSTextView behavior:
///   - Up arrow on the first line moves to the start of the document.
///   - Down arrow on the last line moves to the end of the document.
///   - Cmd+Up / Cmd+Down jump to start / end of document from anywhere.
@Suite
@MainActor
struct CmdUpAtEndOfDocumentTests {
    private func makeLaidOutTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        return textView
    }

    // MARK: - Cmd+Up / Cmd+Down (destination .document)

    @Test("Cmd+Up at end of single-line query goes to offset 0")
    func cmdUpEndOfSingleLine() {
        let textView = makeLaidOutTextView("SELECT * FROM users")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .up,
            destination: .document
        )

        #expect(range.location == 0)
    }

    @Test("Cmd+Up at end of multi-line query goes to offset 0")
    func cmdUpEndOfMultiLine() {
        let textView = makeLaidOutTextView("abc\ndef")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .up,
            destination: .document
        )

        #expect(range.location == 0)
    }

    @Test("Cmd+Down at end of document stays at end")
    func cmdDownEndOfDocument() {
        let textView = makeLaidOutTextView("abc\ndef")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .down,
            destination: .document
        )

        #expect(range.max == length)
    }

    // MARK: - Plain Up / Down arrow (destination .character)

    @Test("Up arrow on first line moves caret to start of document")
    func upArrowOnFirstLineGoesToStartOfDocument() {
        let textView = makeLaidOutTextView("SELECT * FROM users")
        let length = (textView.string as NSString).length

        let range = textView.selectionManager.rangeOfSelection(
            from: length,
            direction: .up,
            destination: .character
        )

        #expect(range.location == 0)
    }

    @Test("Down arrow on last line moves caret to end of document")
    func downArrowOnLastLineGoesToEndOfDocument() {
        let textView = makeLaidOutTextView("abc\ndef")
        let length = (textView.string as NSString).length

        // Cursor between 'd' and 'e' (offset 5)
        let range = textView.selectionManager.rangeOfSelection(
            from: 5,
            direction: .down,
            destination: .character
        )

        #expect(range.max == length)
    }
}
