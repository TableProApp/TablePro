import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct TextViewTests {
    class MockDelegate: TextViewDelegate {
        var shouldReplaceContents: ((_ textView: TextView, _ range: NSRange, _ string: String) -> Bool)?

        func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool {
            shouldReplaceContents?(textView, range, string) ?? true
        }
    }

    let textView: TextView
    let delegate: MockDelegate

    init() {
        textView = TextView(string: "Lorem Ipsum")
        delegate = MockDelegate()
        textView.delegate = delegate
    }

    @Test
    func delegateChangesText() {
        var hasReplaced = false
        delegate.shouldReplaceContents = { textView, _, _ -> Bool in
            if !hasReplaced {
                hasReplaced.toggle()
                textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: " World ")
            }

            return true
        }

        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hello")

        #expect(textView.string == "Hello World Lorem Ipsum")
        // available in test module
        textView.layoutManager.lineStorage.validateInternalState()
    }

    @Test
    func sharedTextStorage() {
        let storage = NSTextStorage(string: "Hello world")

        let textView1 = TextView(string: "")
        textView1.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView1.layoutSubtreeIfNeeded()
        textView1.setTextStorage(storage)

        let textView2 = TextView(string: "")
        textView2.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        textView2.layoutSubtreeIfNeeded()
        textView2.setTextStorage(storage)

        // Expect both text views to receive edited events from the storage
        #expect(textView1.layoutManager.lineCount == 1)
        #expect(textView2.layoutManager.lineCount == 1)

        storage.replaceCharacters(in: NSRange(location: 11, length: 0), with: "\nMore Lines\n")

        #expect(textView1.layoutManager.lineCount == 3)
        #expect(textView2.layoutManager.lineCount == 3)
    }

    @Test("Custom UndoManager class receives events")
    func customUndoManagerReceivesEvents() {
        let textView = TextView(string: "")

        textView.replaceCharacters(in: .zero, with: "Hello World")
        textView.undo(nil)

        #expect(textView.string == "")

        textView.redo(nil)

        #expect(textView.string == "Hello World")
    }
}
