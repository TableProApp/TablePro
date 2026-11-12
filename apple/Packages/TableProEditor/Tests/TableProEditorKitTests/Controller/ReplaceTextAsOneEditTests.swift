import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct ReplaceTextAsOneEditTests {
    @Test("A command's replacement keeps the undo history and undoes in one step")
    func replacementIsUndoable() {
        let (window, controller) = Mock.focusedTextViewController(string: "SELECT 1")
        defer { window.orderOut(nil) }
        let whole = NSRange(location: 0, length: controller.textView.textStorage.length)

        #expect(controller.replaceTextAsOneEdit(in: whole, with: "SELECT * FROM users"))
        #expect(controller.textView.string == "SELECT * FROM users")
        #expect(controller.textView.undoManager?.canUndo == true)

        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "SELECT 1")
    }

    @Test("A command's replacement skips the typing filters a typed edit runs")
    func replacementSkipsTypingFilters() {
        let typed = Mock.loadedTextViewController(string: "")
        typed.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\t")
        #expect(typed.textView.string == "    ")

        let controller = Mock.loadedTextViewController(string: "")
        #expect(controller.replaceTextAsOneEdit(in: NSRange(location: 0, length: 0), with: "\t"))
        #expect(controller.textView.string == "\t")
    }

    @Test("An editor that takes no edits refuses, so the caller writes the text itself")
    func uneditableEditorRefuses() {
        let controller = Mock.loadedTextViewController(string: "SELECT 1")
        controller.textView.isEditable = false

        #expect(!controller.replaceTextAsOneEdit(in: NSRange(location: 0, length: 8), with: "SELECT 2"))
        #expect(controller.textView.string == "SELECT 1")
    }

    @Test("A range past the end of the text is refused")
    func rangePastTheTextIsRefused() {
        let controller = Mock.loadedTextViewController(string: "SELECT 1")

        #expect(!controller.replaceTextAsOneEdit(in: NSRange(location: 4, length: 20), with: "x"))
        #expect(controller.textView.string == "SELECT 1")
    }
}
