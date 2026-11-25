import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct ChatComposerReplaceTests {
    private func composer(_ text: String, caret: Int) -> ChatComposerNSTextView {
        let textView = ChatComposerNSTextView.make()
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return textView
    }

    @Test("A slash pick into an empty composer leaves the caret after the command")
    func emptyComposerCaretFollowsText() {
        let textView = composer("", caret: 0)
        textView.replaceAll(with: "/explain ")
        #expect(textView.string == "/explain ")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
    }

    @Test("A caret at the end of the old text moves to the end of the new text")
    func caretAtEndFollowsText() {
        let textView = composer("select 1", caret: 8)
        textView.replaceAll(with: "/optimize select 1")
        #expect(textView.selectedRange() == NSRange(location: 18, length: 0))
    }

    @Test("A caret inside the text stays where it was")
    func caretInsideStays() {
        let textView = composer("select 1", caret: 3)
        textView.replaceAll(with: "select 1 from t")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("A caret past the new end is clamped to it")
    func caretPastNewEndIsClamped() {
        let textView = composer("select 1 from t", caret: 12)
        textView.replaceAll(with: "select")
        #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test("Clearing the composer leaves the caret at the start")
    func clearingLeavesCaretAtStart() {
        let textView = composer("select 1", caret: 8)
        textView.replaceAll(with: "")
        #expect(textView.string.isEmpty)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }
}
