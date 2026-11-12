import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct UndoHistoryTests {
    private func makeTextView() throws -> (TextView, CEUndoManager) {
        let textView = TextView(string: "")
        return (textView, try #require(textView.editorUndoManager))
    }

    @Test("A history taken out and put back undoes the edits it recorded")
    func undoStackRoundTrip() throws {
        let (textView, undoManager) = try makeTextView()
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "SELECT 1")
        textView.replaceCharacters(in: NSRange(location: 7, length: 1), with: "2")
        let history = undoManager.history
        undoManager.clearStack()
        #expect(undoManager.history.isEmpty)
        #expect(!undoManager.canUndo)

        undoManager.restore(history)
        undoManager.undo()
        #expect(textView.string == "SELECT 1")
        undoManager.undo()
        #expect(textView.string == "")
    }

    @Test("A restored history keeps the steps Redo can apply")
    func redoStackRoundTrip() throws {
        let (textView, undoManager) = try makeTextView()
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "SELECT 1")
        undoManager.undo()
        let history = undoManager.history
        undoManager.clearStack()

        undoManager.restore(history)
        undoManager.redo()

        #expect(textView.string == "SELECT 1")
    }

    @Test("Typing after a restore is its own undo step")
    func typingAfterRestoreStartsANewStep() throws {
        let (textView, undoManager) = try makeTextView()
        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a")
        let history = undoManager.history
        undoManager.clearStack()
        undoManager.restore(history)

        textView.replaceCharacters(in: NSRange(location: 1, length: 0), with: "b")
        undoManager.undo()

        #expect(textView.string == "a")
    }
}
