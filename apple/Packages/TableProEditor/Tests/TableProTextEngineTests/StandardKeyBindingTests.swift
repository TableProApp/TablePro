import AppKit
@testable import TableProTextEngine
import Testing

// The selectors `StandardKeyBinding.dict` sends for keys every macOS text view answers. Expected values were measured
// on `NSTextView` (#2539).
@MainActor
struct StandardKeyBindingTests {
    private func textView(_ string: String, caret: Int) -> TextView {
        let view = TextView(string: string)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        view.updateFrameIfNeeded()
        view.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        view.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        return view
    }

    private func selection(_ view: TextView) -> NSRange? {
        view.selectionManager.textSelections.first?.range
    }

    private func send(_ selector: Selector, to view: TextView, times: Int = 1) {
        for _ in 0..<times {
            view.doCommand(by: selector)
        }
    }

    @Test("Ctrl+F and Ctrl+B move one character, Ctrl+Shift+F and Ctrl+Shift+B extend")
    func controlFAndB() {
        let view = textView("abc", caret: 1)
        send(#selector(NSResponder.moveForward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 2, length: 0))
        send(#selector(NSResponder.moveBackward(_:)), to: view, times: 2)
        #expect(selection(view) == NSRange(location: 0, length: 0))
        send(#selector(NSResponder.moveForwardAndModifySelection(_:)), to: view, times: 2)
        #expect(selection(view) == NSRange(location: 0, length: 2))
        send(#selector(NSResponder.moveBackwardAndModifySelection(_:)), to: view)
        #expect(selection(view) == NSRange(location: 0, length: 1))
    }

    @Test("Ctrl+F with a selection collapses it to its end, Ctrl+B to its start")
    func moveCollapsesSelection() {
        let view = textView("abcdef", caret: 0)
        view.selectionManager.setSelectedRange(NSRange(location: 1, length: 3))
        send(#selector(NSResponder.moveForward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 4, length: 0))
        view.selectionManager.setSelectedRange(NSRange(location: 1, length: 3))
        send(#selector(NSResponder.moveBackward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 1, length: 0))
    }

    @Test("Ctrl+Option+F and Ctrl+Option+B move by word")
    func wordMoves() {
        let view = textView("foo bar", caret: 0)
        send(#selector(NSResponder.moveWordForward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 3, length: 0))
        send(#selector(NSResponder.moveWordForwardAndModifySelection(_:)), to: view)
        #expect(selection(view) == NSRange(location: 3, length: 4))
        view.selectionManager.setSelectedRange(NSRange(location: 7, length: 0))
        send(#selector(NSResponder.moveWordBackward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 4, length: 0))
        send(#selector(NSResponder.moveWordBackwardAndModifySelection(_:)), to: view)
        #expect(selection(view) == NSRange(location: 0, length: 4))
    }

    @Test(
        "Ctrl+T swaps around the caret, or the two before it at a line end",
        arguments: [
            ("abcd", 2, "acbd", 3),
            ("abcd", 4, "abdc", 4),
            ("abcd", 0, "abcd", 0),
            ("ab\ncd", 2, "ba\ncd", 2),
            ("ab\ncd", 3, "abc\nd", 4),
            ("a", 1, "a", 1)
        ]
    )
    func transpose(_ text: String, _ caret: Int, _ expected: String, _ expectedCaret: Int) {
        let view = textView(text, caret: caret)
        send(#selector(NSResponder.transpose(_:)), to: view)
        #expect(view.string == expected)
        #expect(selection(view) == NSRange(location: expectedCaret, length: 0))
    }

    @Test("Ctrl+T beside a CR LF line ending moves the pair whole")
    func transposeKeepsCRLFTogether() {
        let view = textView("ab\r\ncd", caret: 4)
        send(#selector(NSResponder.transpose(_:)), to: view)
        #expect(view.string == "abc\r\nd")
        #expect(selection(view) == NSRange(location: 5, length: 0))
    }

    @Test("Ctrl+F, Ctrl+B and Backspace step over a CR LF line ending whole")
    func crlfIsOneCaretStep() {
        let view = textView("a\r\nb", caret: 3)
        send(#selector(NSResponder.moveBackward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 1, length: 0))
        send(#selector(NSResponder.moveForward(_:)), to: view)
        #expect(selection(view) == NSRange(location: 3, length: 0))
        send(#selector(NSResponder.deleteBackward(_:)), to: view)
        #expect(view.string == "ab")
    }

    @Test("Ctrl+O in a CR LF document opens a CR LF line and leaves the caret where it was")
    func controlOInCRLFDocument() {
        let view = textView("ab\r\ncd", caret: 1)
        send(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: view)
        send(#selector(NSResponder.moveBackward(_:)), to: view)
        #expect(view.string == "a\r\nb\r\ncd")
        #expect(selection(view) == NSRange(location: 1, length: 0))
    }

    @Test("Ctrl+T at several carets swaps at each")
    func transposeAtEveryCaret() {
        let view = textView("ab cd", caret: 0)
        view.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 4, length: 0)])
        send(#selector(NSResponder.transpose(_:)), to: view)
        #expect(view.string == "ba dc")
    }

    @Test("One undo reverses Ctrl+T at every caret")
    func transposeUndoesInOneStep() {
        let view = textView("ab cd", caret: 0)
        view.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 4, length: 0)])
        send(#selector(NSResponder.transpose(_:)), to: view)
        view.undoManager?.undo()
        #expect(view.string == "ab cd")
    }

    @Test("Ctrl+O opens a line after the caret and leaves the caret where it was")
    func controlO() {
        let view = textView("abc", caret: 1)
        send(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: view)
        send(#selector(NSResponder.moveBackward(_:)), to: view)
        #expect(view.string == "a\nbc")
        #expect(selection(view) == NSRange(location: 1, length: 0))
    }

    @Test("Option+Tab inserts a tab")
    func optionTab() {
        let view = textView("ab", caret: 1)
        send(#selector(NSResponder.insertTabIgnoringFieldEditor(_:)), to: view)
        #expect(view.string == "a\tb")
    }

    @Test("Ctrl+A and Ctrl+E stay at the line boundary when pressed again")
    func paragraphMovesStay() {
        let view = textView("aaa\nbbb\nccc", caret: 5)
        send(#selector(NSResponder.moveToBeginningOfParagraph(_:)), to: view, times: 2)
        #expect(selection(view) == NSRange(location: 4, length: 0))
        send(#selector(NSResponder.moveToEndOfParagraph(_:)), to: view, times: 2)
        #expect(selection(view) == NSRange(location: 7, length: 0))
    }

    @Test("Ctrl+E on the last line reaches the end of the text")
    func endOfLastLine() {
        let view = textView("aaa\nSELECT 1", caret: 4)
        send(#selector(NSResponder.moveToEndOfParagraph(_:)), to: view)
        #expect(selection(view) == NSRange(location: 12, length: 0))
    }

    @Test("Ctrl+Shift+A and Ctrl+Shift+E extend to the line boundary and stop there")
    func paragraphExtends() {
        let view = textView("aaa\nbbbb\nccc", caret: 6)
        send(#selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:)), to: view, times: 2)
        #expect(selection(view) == NSRange(location: 6, length: 2))
        view.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))
        send(#selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:)), to: view, times: 2)
        #expect(selection(view) == NSRange(location: 4, length: 2))
    }
}
