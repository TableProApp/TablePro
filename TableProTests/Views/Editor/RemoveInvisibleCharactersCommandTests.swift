//
//  RemoveInvisibleCharactersCommandTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProEditorKit
import TableProTextEngine
import Testing

@MainActor
struct RemoveInvisibleCharactersCommandTests {
    private func makeEditor(_ text: String) -> (SQLEditorCoordinator, TextViewController) {
        let controller = EditorControllerFixture.make(string: text)
        let coordinator = SQLEditorCoordinator()
        coordinator.controller = controller
        coordinator.databaseType = .mysql
        controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        return (coordinator, controller)
    }

    @Test("A line separator becomes a plain line break, without the typing filters re-indenting it")
    func separatorIsNotReindented() {
        let (coordinator, controller) = makeEditor("    SELECT a,\u{A0}\u{2028}b")
        coordinator.performRemoveInvisibleCharacters()
        #expect(controller.textView.string == "    SELECT a, \nb")
    }

    @Test("Every edit undoes as one step")
    func singleUndo() throws {
        let original = "\u{8}SELECT\u{A0}1\u{2028}FROM t"
        let (coordinator, controller) = makeEditor(original)
        coordinator.performRemoveInvisibleCharacters()
        #expect(controller.textView.string == "SELECT 1\nFROM t")
        let undoManager = try #require(controller.textView.undoManager)
        undoManager.undo()
        #expect(controller.textView.string == original)
    }

    /// The command turns the editor's typing filters off for the length of its own edit, which is what
    /// `separatorIsNotReindented` above measures. Asserting on the flag that does it only says a flag was
    /// cleared; typing a newline afterwards and getting the leading indent back says the same filter is
    /// running again.
    @Test("Typing filters still run for ordinary edits afterwards")
    func filtersResume() {
        let (coordinator, controller) = makeEditor("    SELECT\u{A0}1")
        coordinator.performRemoveInvisibleCharacters()
        #expect(controller.textView.string == "    SELECT 1")

        let end = (controller.textView.string as NSString).length
        controller.textView.selectionManager.setSelectedRange(NSRange(location: end, length: 0))
        controller.textView.insertText("\n", replacementRange: NSRange(location: end, length: 0))

        #expect(controller.textView.string == "    SELECT 1\n    ")
    }

    @Test("A read-only editor is left alone")
    func readOnlyEditor() {
        let (coordinator, controller) = makeEditor("SELECT\u{A0}1")
        controller.textView.isEditable = false
        coordinator.performRemoveInvisibleCharacters()
        #expect(controller.textView.string == "SELECT\u{A0}1")
    }
}
