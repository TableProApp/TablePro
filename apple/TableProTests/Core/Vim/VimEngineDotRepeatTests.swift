// `.` repeats the last command that changed the text, with what was typed in Insert mode after it.

import Foundation
@testable import TablePro
import Testing

@MainActor
struct VimEngineDotRepeatTests {
    private let buffer: VimTextBufferMock
    private let engine: VimEngine

    init() {
        buffer = VimTextBufferMock(text: "")
        engine = VimEngine(buffer: buffer)
        buffer.editObserver = engine
    }

    private func load(_ text: String, caret: Int = 0) {
        buffer.text = text
        buffer.setSelectedRange(NSRange(location: caret, length: 0))
    }

    // A key the engine leaves to the text view is applied as the editor does: Backspace deletes, anything else types.
    private func keys(_ chars: String) {
        for char in chars where !engine.process(char, shift: char.isUppercase) {
            if char == "\u{7F}" {
                guard caret > 0 else { continue }
                buffer.replaceCharacters(in: NSRange(location: caret - 1, length: 1), with: "")
            } else {
                buffer.replaceCharacters(in: buffer.selectedRange(), with: String(char))
            }
        }
    }

    private var caret: Int { buffer.selectedRange().location }

    @Test("dd, then . on the next line deletes that line, after an x before it")
    func dotRepeatsDeleteLineAfterX() {
        load("one\ntwo\nthree\nfour\n")
        keys("x")
        keys("jdd")
        #expect(buffer.text == "ne\nthree\nfour\n")
        keys(".")
        #expect(buffer.text == "ne\nfour\n")
    }

    @Test("cw with typed text, then . changes the next word the same way")
    func dotRepeatsChangeWordWithItsText() {
        load("SELECT a, b FROM t", caret: 7)
        keys("cwid\u{1B}")
        #expect(buffer.text == "SELECT id, b FROM t")
        #expect(engine.mode == .normal)
        keys("w")
        keys("w")
        #expect(caret == 11)
        keys(".")
        #expect(buffer.text == "SELECT id, id FROM t")
        #expect(engine.mode == .normal)
    }

    @Test("J, then . joins the next line too")
    func dotRepeatsJoin() {
        load("a\nb\nc\n")
        keys("J")
        #expect(buffer.text == "a b\nc\n")
        keys(".")
        #expect(buffer.text == "a b c\n")
    }

    @Test("~, then . toggles the next character")
    func dotRepeatsToggleCase() {
        load("abc")
        keys("~")
        keys(".")
        #expect(buffer.text == "ABc")
    }

    @Test("A with typed text, then . on the next line appends the same text")
    func dotRepeatsAppend() {
        load("SELECT 1\nSELECT 2\n")
        keys("A;\u{1B}")
        keys("j.")
        #expect(buffer.text == "SELECT 1;\nSELECT 2;\n")
    }

    @Test("Backspace past where the typing began deletes as much again on .")
    func dotRepeatsBackspacePastTheInsertStart() {
        load("abc\ndefgh")
        keys("A\u{7F}\u{7F}X\u{1B}")
        #expect(buffer.text == "aX\ndefgh")
        keys("j.")
        #expect(buffer.text == "aX\ndefX")
    }

    @Test("Ctrl-U in Insert mode replays as the key, deleting to the start of the line it is on")
    func dotRepeatsControlU() {
        load("abc\ndefgh")
        keys("A\u{15}X\u{1B}")
        #expect(buffer.text == "X\ndefgh")
        keys("j.")
        #expect(buffer.text == "X\nX")
    }

    @Test("Ctrl-W in Insert mode replays as the key, deleting the word before the caret")
    func dotRepeatsControlW() {
        load("SELECT abc\nSELECT defgh")
        keys("A\u{17}x\u{1B}")
        #expect(buffer.text == "SELECT x\nSELECT defgh")
        keys("j.")
        #expect(buffer.text == "SELECT x\nSELECT x")
    }

    @Test("A yank between a change and . leaves the change to repeat")
    func yankIsNotAChange() {
        load("abcdef\nxyz\n")
        keys("x")
        keys("yy")
        keys(".")
        #expect(buffer.text == "cdef\nxyz\n")
    }

    @Test("A count on . replaces the change's count, and the next . keeps it")
    func countOnDotReplacesTheCount() {
        load("abcdefghij")
        keys("2x")
        #expect(buffer.text == "cdefghij")
        keys("3.")
        #expect(buffer.text == "fghij")
        keys(".")
        #expect(buffer.text == "ij")
    }
}
