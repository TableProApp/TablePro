//
//  VimEngineInsertEntryTests.swift
//  TableProTests
//
//  Specification tests for entering and leaving Insert mode (i, I, a, A, o, O, s, S, gi).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineInsertEntryTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private func escape() { _ = engine.process("\u{1B}", shift: false) }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - i: Insert Before Cursor

    @Test
    func iLowerEntersInsertMode() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("i")
        #expect(engine.mode == .insert)
    }

    @Test
    func iLowerDoesNotMoveCursor() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("i")
        #expect(pos == 3, "i keeps cursor in place; insertions happen before it")
    }

    @Test
    func iLowerConsumesKey() {
        #expect(engine.process("i", shift: false))
    }

    // MARK: - I: Insert at First Non-Blank

    @Test
    func iCapitalEntersInsertModeAtFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        key("I", shift: true)
        #expect(engine.mode == .insert)
        #expect(pos == 3, "I should land at first non-blank, not column 0")
    }

    @Test
    func iCapitalAtLineStartWithoutLeadingSpace() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("I", shift: true)
        #expect(pos == 0)
    }

    // MARK: - a: Append After Cursor

    @Test
    func aAppendsAfterCursor() {
        buffer.setSelectedRange(NSRange(location: 2, length: 0))
        keys("a")
        #expect(engine.mode == .insert)
        #expect(pos == 3)
    }

    @Test
    func aAtEndOfLineLandsAfterLastChar() {
        // 'd' is at offset 10, '\n' is at 11. Append should land at 11 (between 'd' and '\n').
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("a")
        #expect(pos == 11, "a at end of line should land after last char, before newline")
    }

    @Test
    func aAtBufferEndStaysAtEnd() {
        buffer.setSelectedRange(NSRange(location: buffer.length, length: 0))
        keys("a")
        #expect(pos == buffer.length)
    }

    // MARK: - A: Append at End of Line

    @Test
    func aCapitalEntersInsertAtLineEnd() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        key("A", shift: true)
        #expect(engine.mode == .insert)
        #expect(pos == 11, "A should land just before the newline of the current line")
    }

    @Test
    func aCapitalOnLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "hello")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("A", shift: true)
        #expect(pos == 5, "A on last line without newline should land at end-of-buffer")
    }

    // MARK: - o: Open Line Below

    @Test
    func oOpensLineBelowAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        #expect(engine.mode == .insert)
        #expect(buffer.text.hasPrefix("hello world\n\n"),
            "o should insert a newline after the current line")
    }

    @Test
    func oPositionsCursorOnNewLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        #expect(pos == 12, "o cursor should sit at the start of the new blank line")
    }

    @Test
    func oOnLastLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "one\ntwo")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        #expect(buffer.text == "one\ntwo\n",
            "o on the last line without a newline should append a newline")
        #expect(pos == 8)
    }

    // MARK: - O: Open Line Above

    @Test
    func capitalOOpensLineAbove() {
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("O")
        #expect(engine.mode == .insert)
        #expect(pos == 12, "O should place cursor at the new blank line above")
    }

    @Test
    func capitalOOnFirstLine() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("O")
        #expect(pos == 0)
        #expect(buffer.text.hasPrefix("\nhello world"))
    }

    // MARK: - s: Substitute Character

    @Test
    func sLowerDeletesCharAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("s")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "ello world\nsecond line\nthird line\n",
            "s should delete the char under the cursor and enter insert mode")
    }

    @Test
    func sLowerWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3s")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "lo world\nsecond line\nthird line\n",
            "3s should delete three chars and enter insert mode")
    }

    @Test
    func sLowerDoesNotCrossNewline() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("9s")
        #expect(buffer.text == "hello worl\nsecond line\nthird line\n",
            "s should not consume the newline even with large count")
    }

    // MARK: - S: Substitute Entire Line

    @Test
    func capitalSDeletesLineContentAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("S", shift: true)
        #expect(engine.mode == .insert)
        #expect(buffer.text == "\nsecond line\nthird line\n",
            "S should delete the entire line content but keep the newline")
        #expect(pos == 0)
    }

    @Test
    func capitalSWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("S", shift: true)
        #expect(buffer.text == "\nthird line\n",
            "2S should delete two lines' content")
    }

    // MARK: - Escape: Insert → Normal

    @Test
    func escapeReturnsToNormalMode() {
        keys("i")
        escape()
        #expect(engine.mode == .normal)
    }

    @Test
    func escapeMovesCursorBackOne() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("i")
        escape()
        #expect(pos == 4, "Escape from insert should move cursor back one (Vim convention)")
    }

    @Test
    func escapeAtLineStartDoesNotCrossBoundary() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("i")
        escape()
        #expect(pos == 12, "Escape at line start should not move cursor onto previous line")
    }

    @Test
    func escapeAtBufferStartStays() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        escape()
        #expect(pos == 0)
    }

    // MARK: - Escape at End-of-Buffer (regression for ";" cursor-past-last-char bug)

    @Test
    func escapePastLastCharOfBufferWithoutTrailingNewline() {
        // Reproduces the reported bug: typing "SELECT * FROM users;" leaves the cursor
        // at offset == length (past the last char). Pressing Esc must still switch
        // to normal mode and step the cursor back onto the last char.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("i")
        #expect(engine.mode == .insert)
        escape()
        #expect(engine.mode == .normal, "Esc at end-of-buffer must switch to normal mode")
        #expect(pos == 19, "Cursor should step back from end onto ';' at offset 19")
    }

    @Test
    func escapePastLastCharOfBufferWithTrailingNewline() {
        // Same buffer but with a trailing newline. Cursor lands between ';' (offset 19)
        // and '\n' (offset 20). That is the "end of last content line", not the phantom
        // line after the newline.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("i")
        escape()
        #expect(engine.mode == .normal)
        #expect(pos == 19, "Cursor steps back from line-end (just before '\\n') onto ';'")
    }

    @Test
    func escapeOnPhantomLineAfterTrailingNewline() {
        // Cursor at offset == length on a buffer with a trailing newline ends up on
        // the phantom empty line after the '\n'. The Vim convention is that Esc still
        // switches mode and does NOT cross back over the newline (since the phantom
        // line is its own line, and there is no content to step back onto).
        buffer = VimTextBufferMock(text: "SELECT;\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("i")
        escape()
        #expect(engine.mode == .normal, "Esc on the phantom line must still switch to normal mode")
        #expect(pos == 8, "Cursor stays on phantom line (no content to step onto)")
    }

    @Test
    func escapeAfterTypingSemicolonAtEndIsConsumed() {
        // The interceptor's pass-through behavior depends on the engine returning
        // true (consumed) when Esc is processed in insert mode. Regression-safe.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("i")
        let consumed = engine.process("\u{1B}", shift: false)
        #expect(consumed, "Escape must be consumed by the engine at end-of-buffer")
    }

    // MARK: - Insert Mode Pass-Through

    @Test
    func charactersInInsertModeAreNotConsumed() {
        keys("i")
        let consumed = engine.process("x", shift: false)
        #expect(!consumed, "Regular characters in insert mode must pass through to the text view")
    }

    @Test
    func escapeInInsertIsConsumed() {
        keys("i")
        let consumed = engine.process("\u{1B}", shift: false)
        #expect(consumed)
    }

    // MARK: - gi: Resume Insert at Last Position

    @Test
    func gIResumesInsertAtLastInsertLocation() {
        // Enter insert at offset 5, type implicitly via test, escape, move, then gi.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("i")
        escape()
        // Move away
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gi")
        #expect(engine.mode == .insert)
        #expect(pos == 5, "gi should re-enter insert mode at the previous insert position")
    }

    // MARK: - Insert Mode Callbacks

    @Test
    func modeChangeCallbackFiresOnInsertEntry() {
        var capturedMode: VimMode?
        engine.onModeChange = { mode in capturedMode = mode }
        keys("i")
        #expect(capturedMode == .insert)
    }

    @Test
    func modeChangeCallbackFiresOnInsertExit() {
        keys("i")
        var capturedMode: VimMode?
        engine.onModeChange = { mode in capturedMode = mode }
        escape()
        #expect(capturedMode == .normal)
    }
}
