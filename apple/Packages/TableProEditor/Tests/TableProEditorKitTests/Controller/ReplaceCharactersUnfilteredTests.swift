import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct ReplaceCharactersUnfilteredTests {
    @Test("A key command's open bracket over a character replaces it and wraps nothing")
    func openBracketReplacesTheCharacter() {
        let controller = Mock.loadedTextViewController(string: "a x b")
        controller.replaceCharactersUnfiltered(in: NSRange(location: 2, length: 1), with: "(")
        #expect(controller.textView.string == "a ( b")
    }

    @Test("A key command's delete of an open bracket leaves the closing one")
    func deletingAnOpenBracketKeepsTheCloser() {
        let controller = Mock.loadedTextViewController(string: "COUNT()")
        controller.replaceCharactersUnfiltered(in: NSRange(location: 5, length: 1), with: "")
        #expect(controller.textView.string == "COUNT)")
    }

    @Test("Typing after a key command's edit still runs the typing filters")
    func typingAfterwardIsFiltered() {
        let controller = Mock.loadedTextViewController(string: "")
        controller.replaceCharactersUnfiltered(in: NSRange(location: 0, length: 0), with: "\t")
        #expect(controller.textView.string == "\t")

        controller.textView.replaceCharacters(in: NSRange(location: 1, length: 0), with: "\t")
        #expect(controller.textView.string == "\t    ")
    }

    @Test("A key command's edit is undoable")
    func editIsUndoable() {
        let (window, controller) = Mock.focusedTextViewController(string: "a x b")
        defer { window.orderOut(nil) }
        controller.replaceCharactersUnfiltered(in: NSRange(location: 2, length: 1), with: "(")
        controller.textView.undoManager?.undo()
        #expect(controller.textView.string == "a x b")
    }
}
