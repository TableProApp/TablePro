//
//  VimEngineInsertEntryTests.swift
//  TableProTests
//
//  Specification tests for entering and leaving Insert mode (i, I, a, A, o, O, s, S, gi).
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineInsertEntryTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
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

    func testILowerEntersInsertMode() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("i")
        XCTAssertEqual(engine.mode, .insert)
    }

    func testILowerDoesNotMoveCursor() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("i")
        XCTAssertEqual(pos, 3, "i keeps cursor in place; insertions happen before it")
    }

    func testILowerConsumesKey() {
        XCTAssertTrue(engine.process("i", shift: false))
    }

    // MARK: - I: Insert at First Non-Blank

    func testICapitalEntersInsertModeAtFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        key("I", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(pos, 3, "I should land at first non-blank, not column 0")
    }

    func testICapitalAtLineStartWithoutLeadingSpace() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("I", shift: true)
        XCTAssertEqual(pos, 0)
    }

    // MARK: - a: Append After Cursor

    func testAAppendsAfterCursor() {
        buffer.setSelectedRange(NSRange(location: 2, length: 0))
        keys("a")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(pos, 3)
    }

    func testAAtEndOfLineLandsAfterLastChar() {
        // 'd' is at offset 10, '\n' is at 11. Append should land at 11 (between 'd' and '\n').
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("a")
        XCTAssertEqual(pos, 11, "a at end of line should land after last char, before newline")
    }

    func testAAtBufferEndStaysAtEnd() {
        buffer.setSelectedRange(NSRange(location: buffer.length, length: 0))
        keys("a")
        XCTAssertEqual(pos, buffer.length)
    }

    // MARK: - A: Append at End of Line

    func testACapitalEntersInsertAtLineEnd() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        key("A", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(pos, 11, "A should land just before the newline of the current line")
    }

    func testACapitalOnLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "hello")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("A", shift: true)
        XCTAssertEqual(pos, 5, "A on last line without newline should land at end-of-buffer")
    }

    // MARK: - o: Open Line Below

    func testOOpensLineBelowAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertTrue(buffer.text.hasPrefix("hello world\n\n"),
            "o should insert a newline after the current line")
    }

    func testOPositionsCursorOnNewLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        XCTAssertEqual(pos, 12, "o cursor should sit at the start of the new blank line")
    }

    func testOOnLastLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "one\ntwo")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        XCTAssertEqual(buffer.text, "one\ntwo\n",
            "o on the last line without a newline should append a newline")
        XCTAssertEqual(pos, 8)
    }

    // MARK: - O: Open Line Above

    func testCapitalOOpensLineAbove() {
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("O")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(pos, 12, "O should place cursor at the new blank line above")
    }

    func testCapitalOOnFirstLine() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("O")
        XCTAssertEqual(pos, 0)
        XCTAssertTrue(buffer.text.hasPrefix("\nhello world"))
    }

    // MARK: - s: Substitute Character

    func testSLowerDeletesCharAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("s")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "ello world\nsecond line\nthird line\n",
            "s should delete the char under the cursor and enter insert mode")
    }

    func testSLowerWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3s")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "lo world\nsecond line\nthird line\n",
            "3s should delete three chars and enter insert mode")
    }

    func testSLowerDoesNotCrossNewline() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("9s")
        XCTAssertEqual(buffer.text, "hello worl\nsecond line\nthird line\n",
            "s should not consume the newline even with large count")
    }

    // MARK: - S: Substitute Entire Line

    func testCapitalSDeletesLineContentAndEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("S", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "\nsecond line\nthird line\n",
            "S should delete the entire line content but keep the newline")
        XCTAssertEqual(pos, 0)
    }

    func testCapitalSWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("S", shift: true)
        XCTAssertEqual(buffer.text, "\nthird line\n",
            "2S should delete two lines' content")
    }

    // MARK: - Escape: Insert → Normal

    func testEscapeReturnsToNormalMode() {
        keys("i")
        escape()
        XCTAssertEqual(engine.mode, .normal)
    }

    func testEscapeMovesCursorBackOne() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(pos, 4, "Escape from insert should move cursor back one (Vim convention)")
    }

    func testEscapeAtLineStartDoesNotCrossBoundary() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(pos, 12, "Escape at line start should not move cursor onto previous line")
    }

    func testEscapeAtBufferStartStays() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(pos, 0)
    }

    // MARK: - Escape at End-of-Buffer (regression for ";" cursor-past-last-char bug)

    func testEscapePastLastCharOfBufferWithoutTrailingNewline() {
        // Reproduces the reported bug: typing "SELECT * FROM users;" leaves the cursor
        // at offset == length (past the last char). Pressing Esc must still switch
        // to normal mode and step the cursor back onto the last char.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("i")
        XCTAssertEqual(engine.mode, .insert)
        escape()
        XCTAssertEqual(engine.mode, .normal, "Esc at end-of-buffer must switch to normal mode")
        XCTAssertEqual(pos, 19, "Cursor should step back from end onto ';' at offset 19")
    }

    func testEscapePastLastCharOfBufferWithTrailingNewline() {
        // Same buffer but with a trailing newline. Cursor lands between ';' (offset 19)
        // and '\n' (offset 20). That is the "end of last content line", not the phantom
        // line after the newline.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(pos, 19, "Cursor steps back from line-end (just before '\\n') onto ';'")
    }

    func testEscapeOnPhantomLineAfterTrailingNewline() {
        // Cursor at offset == length on a buffer with a trailing newline ends up on
        // the phantom empty line after the '\n'. The Vim convention is that Esc still
        // switches mode and does NOT cross back over the newline (since the phantom
        // line is its own line, and there is no content to step back onto).
        buffer = VimTextBufferMock(text: "SELECT;\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(engine.mode, .normal, "Esc on the phantom line must still switch to normal mode")
        XCTAssertEqual(pos, 8, "Cursor stays on phantom line (no content to step onto)")
    }

    func testEscapeAfterTypingSemicolonAtEndIsConsumed() {
        // The interceptor's pass-through behavior depends on the engine returning
        // true (consumed) when Esc is processed in insert mode. Regression-safe.
        buffer = VimTextBufferMock(text: "SELECT * FROM users;")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("i")
        let consumed = engine.process("\u{1B}", shift: false)
        XCTAssertTrue(consumed, "Escape must be consumed by the engine at end-of-buffer")
    }

    // MARK: - Insert Mode Pass-Through

    func testCharactersInInsertModeAreNotConsumed() {
        keys("i")
        let consumed = engine.process("x", shift: false)
        XCTAssertFalse(consumed, "Regular characters in insert mode must pass through to the text view")
    }

    func testEscapeInInsertIsConsumed() {
        keys("i")
        let consumed = engine.process("\u{1B}", shift: false)
        XCTAssertTrue(consumed)
    }

    // MARK: - gi: Resume Insert at Last Position

    func testGIResumesInsertAtLastInsertLocation() {
        // Enter insert at offset 5, type implicitly via test, escape, move, then gi.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("i")
        escape()
        // Move away
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gi")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(pos, 5, "gi should re-enter insert mode at the previous insert position")
    }

    // MARK: - Insert Mode Callbacks

    func testModeChangeCallbackFiresOnInsertEntry() {
        var capturedMode: VimMode?
        engine.onModeChange = { mode in capturedMode = mode }
        keys("i")
        XCTAssertEqual(capturedMode, .insert)
    }

    func testModeChangeCallbackFiresOnInsertExit() {
        keys("i")
        var capturedMode: VimMode?
        engine.onModeChange = { mode in capturedMode = mode }
        escape()
        XCTAssertEqual(capturedMode, .normal)
    }
}
