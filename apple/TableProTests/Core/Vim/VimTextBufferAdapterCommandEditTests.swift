// The editor runs its typing filters on every edit it is not told is a command: an open bracket wraps a selection,
// deleting one takes its closer, a quote doubles. Vim's edits are commands, so they land exactly as the engine asks.

import AppKit
@testable import TablePro
import TableProEditorKit
import TableProTextEngine
import Testing

// Tells the engine about every edit before it lands, as `SQLEditorCoordinator` does in the app.
@MainActor
private final class EditForwarder: TextViewCoordinator, TextViewDelegate {
    weak var engine: VimEngine?

    func prepareCoordinator(controller: TextViewController) {}

    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        let undoManager = textView.undoManager
        let source: VimEditSource = undoManager?.isUndoing == true ? .undo
            : undoManager?.isRedoing == true ? .redo : .edit
        engine?.textWillChange(in: range, with: string, source: source)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        engine?.selectionDidChange()
    }
}

@MainActor
private final class VimEditor {
    static let leftArrow: Character = "\u{F702}"

    let forwarder = EditForwarder()
    let controller: TextViewController
    let adapter: VimTextBufferAdapter
    let engine: VimEngine

    init(_ text: String, caret: Int) {
        controller = EditorControllerFixture.make(string: text, coordinators: [forwarder])
        adapter = VimTextBufferAdapter(controller: controller)
        engine = VimEngine(buffer: adapter)
        forwarder.engine = engine
        adapter.setSelectedRange(NSRange(location: caret, length: 0))
    }

    var text: String { controller.textView.string }

    // The left arrow goes to the editor, as Vim routes it in Insert mode; a key the engine leaves is typed.
    func keys(_ keys: String) {
        let textView: TextView = controller.textView
        for key in keys {
            if key == Self.leftArrow {
                textView.doCommand(by: #selector(NSResponder.moveLeft(_:)))
            } else if !engine.process(key, shift: key.isUppercase) {
                textView.replaceCharacters(in: textView.selectedRange(), with: String(key))
            }
        }
    }

    func click(at offset: Int) {
        controller.textView.selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
    }
}

@MainActor
struct VimTextBufferAdapterCommandEditTests {
    private func run(_ keys: String, on text: String, at offset: Int) -> String {
        let editor = VimEditor(text, caret: offset)
        editor.keys(keys)
        return editor.text
    }

    @Test("u after 3iXY takes back all three XY")
    func undoTakesBackACountedInsert() {
        #expect(run("3iXY\u{1B}u", on: "abc", at: 0) == "abc")
    }

    @Test("u after 3oX takes back all three lines")
    func undoTakesBackACountedOpenLine() {
        #expect(run("3oX\u{1B}u", on: "abc\ndef", at: 0) == "abc\ndef")
    }

    @Test("u after an insert with no count takes it back as before")
    func undoTakesBackAnUncountedInsert() {
        #expect(run("iXY\u{1B}u", on: "abc", at: 0) == "abc")
    }

    @Test("A move in Insert mode starts a new insert, so . repeats only what was typed after it")
    func moveInInsertModeStartsANewInsert() {
        #expect(run("iab\u{F702}X\u{1B}l.", on: "", at: 0) == "aXXb")
    }

    @Test("A move in Insert mode with nothing typed after it leaves the insert before it for .")
    func moveWithNothingTypedAfterItKeepsTheInsert() {
        #expect(run("iabc\u{F702}\u{1B}.", on: "", at: 0) == "aabcbc")
    }

    @Test("A click in Insert mode starts a new insert, so . repeats only what was typed after it")
    func clickInInsertModeStartsANewInsert() {
        let editor = VimEditor("", caret: 0)
        editor.keys("iab")
        editor.click(at: 1)
        editor.keys("X\u{1B}l.")
        #expect(editor.text == "aXXb")
    }

    @Test("An insert with no move repeats all of it")
    func insertWithoutAMoveRepeatsAllOfIt() {
        #expect(run("iab\u{1B}l.", on: "", at: 0) == "aabb")
    }

    @Test("The closing bracket the editor adds while typing is part of what . repeats")
    func autoClosedBracketIsRepeated() {
        #expect(run("i(x\u{1B}.", on: "", at: 0) == "((x)x)")
    }

    @Test("u after . of cw with typed text puts the changed word back")
    func undoTakesBackTheWholeRepeatedChange() {
        #expect(run("cwX\u{1B}w.u", on: "one two three", at: 0) == "X two three")
    }

    @Test("u after . of 3iX takes back all three X")
    func undoTakesBackARepeatedCountedInsert() {
        #expect(run("3iX\u{1B}w.u", on: "abc def", at: 0) == "XXXabc def")
    }

    @Test("u after . of 3iXY takes back all three XY")
    func undoTakesBackARepeatedCountedInsertOfSeveralCharacters() {
        #expect(run("3iXY\u{1B}w.u", on: "abc def", at: 0) == "XYXYXYabc def")
    }

    @Test("u after . of dd puts the line back")
    func undoTakesBackARepeatedLineDelete() {
        #expect(run("ddj.u", on: "one\ntwo\nthree\nfour\n", at: 0) == "two\nthree\nfour\n")
    }

    @Test("x on an open bracket deletes that bracket only")
    func deleteOpenBracket() {
        #expect(run("x", on: "SELECT COUNT() FROM t", at: 12) == "SELECT COUNT) FROM t")
    }

    @Test("r( replaces the character with a bracket and wraps nothing")
    func replaceWithBracket() {
        #expect(run("r(", on: "a x b", at: 2) == "a ( b")
    }

    @Test("~ on a quote leaves the quote as it is")
    func toggleCaseOnQuote() {
        #expect(run("~", on: "'abc'", at: 0) == "'abc'")
    }

    @Test("R types over a character with a quote, and adds no closing quote")
    func replaceModeQuote() {
        #expect(run("R'\u{1B}", on: "WHERE n = x", at: 10) == "WHERE n = '")
    }

    @Test("o opens an empty line and leaves the next line's indent alone")
    func openLineBelow() {
        #expect(run("o\u{1B}", on: "    a\n    b", at: 4) == "    a\n\n    b")
    }
}
