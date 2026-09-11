import AppKit
@testable import CodeEditTextView
import Testing

@Suite("Control characters from text input")
@MainActor
struct TextInputControlCharacterTests {
    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(string: text)
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        textView.selectionManager.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }

    private func caret(_ textView: TextView) -> NSRange? {
        textView.selectionManager.textSelections.first?.range
    }

    @Test("A typed control character never reaches the document", arguments: ["\u{8}", "\u{7}", "\u{1D}", "\u{7F}"])
    func controlIsDropped(control: String) {
        let textView = makeTextView("SELECT 1")
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText(control, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "SELECT 1")
        #expect(caret(textView) == NSRange(location: 0, length: 0))
    }

    @Test("Text committed with a stray control keeps the text")
    func mixedCommitKeepsText() {
        let textView = makeTextView("")
        textView.insertText("SELECT\u{8}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "SELECT")
    }

    @Test("A dropped control character leaves a selection in place")
    func droppedControlKeepsSelection() {
        let textView = makeTextView("SELECT 1")
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 6))
        textView.insertText("\u{8}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "SELECT 1")
        #expect(caret(textView) == NSRange(location: 0, length: 6))
    }

    @Test("Inserting nothing over a selection still deletes it, which is how a drag moves text")
    func emptyInsertDeletesSelection() {
        let textView = makeTextView("SELECT 1")
        textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 7))
        textView.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "1")
    }

    @Test("Tab, newline and carriage return still type")
    func whitespaceStillTypes() {
        let textView = makeTextView("")
        textView.insertText("a\tb", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "a\tb\n")
    }

    @Test("A composition that commits a backspace character is cleared, not corrupted")
    func markedTextCommittedAsControlClearsComposition() {
        let textView = makeTextView("SELECT ")
        textView.selectionManager.setSelectedRange(NSRange(location: 7, length: 0))
        textView.setMarkedText(
            "s",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText("\u{8}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "SELECT ")
        #expect(!textView.hasMarkedText())
    }

    @Test("Marked text carrying a control character shows only the text")
    func markedTextDropsControls() {
        let textView = makeTextView("")
        textView.setMarkedText(
            "le\u{8}",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.string == "le")
    }

    @Test("Paste keeps what was copied, control characters included")
    func pasteKeepsControls() {
        let textView = makeTextView("")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\u{8}SELECT 1", forType: .string)
        textView.paste(NSObject())
        #expect(textView.string == "\u{8}SELECT 1")
    }
}
