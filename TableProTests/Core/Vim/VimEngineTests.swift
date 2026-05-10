//
//  VimEngineTests.swift
//  TableProTests
//
//  Comprehensive tests for the Vim engine state machine
//

import XCTest
import TableProPluginKit
@testable import TablePro

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!
    private var lastMode: VimMode?
    private var lastCommand: String?

    // Default text: "hello world\nsecond line\nthird line\n"
    //  offsets:      0123456789A B (line 0: 0–11, newline at 11)
    //               C D E F ... (line 1: 12–23, newline at 23)
    //               ...         (line 2: 24–34, newline at 34)
    //  total length = 35

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
        engine.onModeChange = { [weak self] mode in self?.lastMode = mode }
        engine.onCommand = { [weak self] cmd in self?.lastCommand = cmd }
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        lastMode = nil
        lastCommand = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Feed a sequence of characters, each as a separate process() call.
    private func keys(_ chars: String) {
        for char in chars {
            _ = engine.process(char, shift: false)
        }
    }

    /// Feed a single character with optional shift.
    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    /// Send Escape key.
    private func escape() {
        _ = engine.process("\u{1B}", shift: false)
    }

    /// Send Enter key.
    private func enter() {
        _ = engine.process("\r", shift: false)
    }

    /// Send Backspace (DEL) key.
    private func backspace() {
        _ = engine.process("\u{7F}", shift: false)
    }

    /// Current cursor position shorthand.
    private var cursorPos: Int {
        buffer.selectedRange().location
    }

    // MARK: - Initial State

    func testInitialModeIsNormal() {
        XCTAssertEqual(engine.mode, .normal)
    }

    func testInitialCursorAtZero() {
        XCTAssertEqual(cursorPos, 0)
        XCTAssertEqual(engine.cursorOffset, 0)
    }

    func testModeChangeCallbackNotCalledOnInit() {
        XCTAssertNil(lastMode)
    }

    // MARK: - Basic Motions (h, j, k, l)

    func testHMovesLeft() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("h")
        XCTAssertEqual(cursorPos, 4)
    }

    func testHAtStartOfBufferStaysAtZero() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("h")
        XCTAssertEqual(cursorPos, 0)
    }

    func testHDoesNotCrossLineBoundary() {
        // Position at start of second line (offset 12)
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("h")
        XCTAssertEqual(cursorPos, 12, "h should not move past start of current line")
    }

    func testLMovesRight() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        XCTAssertEqual(cursorPos, 1)
    }

    func testLAtEndOfLineClampsToLastChar() {
        // "hello world\n" — last content char is 'd' at offset 10, newline at 11
        // l should not go past offset 10 on this line
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("l")
        XCTAssertEqual(cursorPos, 10, "l should not move past last character before newline")
    }

    func testJMovesDown() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("j")
        // Line 0 col 0 -> Line 1 col 0, offset 12
        XCTAssertEqual(cursorPos, 12)
    }

    func testJAtLastLineStays() {
        // Last line is "third line\n" starting at offset 24
        buffer.setSelectedRange(NSRange(location: 24, length: 0))
        keys("j")
        // Should stay on line 2 (last line)
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 2)
    }

    func testKMovesUp() {
        // Start on second line
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("k")
        // Line 1 col 0 -> Line 0 col 0, offset 0
        XCTAssertEqual(cursorPos, 0)
    }

    func testKAtFirstLineStays() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("k")
        // Already on first line, stays on first line
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 0)
    }

    func testHWithCount() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("3h")
        XCTAssertEqual(cursorPos, 2)
    }

    func testLWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3l")
        XCTAssertEqual(cursorPos, 3)
    }

    func testJWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2j")
        // Line 0 -> Line 2
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 2)
    }

    func testKWithCount() {
        // Start on last line
        buffer.setSelectedRange(NSRange(location: 24, length: 0))
        keys("2k")
        // Line 2 -> Line 0
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 0)
    }

    func testJPreservesGoalColumn() {
        // Position at column 5 in line 0
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("j")
        // Should be at column 5 of line 1 (offset 12+5 = 17)
        XCTAssertEqual(cursorPos, 17)
    }

    // MARK: - Word Motions (w, b, e)

    func testWMovesToNextWordStart() {
        // "hello world\n..." — cursor at 0 ('h'), w should go to 'w' at offset 6
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("w")
        XCTAssertEqual(cursorPos, 6)
    }

    func testWAtEndOfBuffer() {
        // Move to near end, then w should clamp
        buffer.setSelectedRange(NSRange(location: 30, length: 0))
        keys("w")
        XCTAssertEqual(cursorPos, buffer.length, "w at end of buffer should stay at buffer end")
    }

    func testBMovesToPreviousWordStart() {
        // At 'w' (offset 6), b should go back to 'h' (offset 0)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("b")
        XCTAssertEqual(cursorPos, 0)
    }

    func testBAtStartOfBuffer() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("b")
        XCTAssertEqual(cursorPos, 0)
    }

    func testEMovesToWordEnd() {
        // "hello world..." — at 0 ('h'), e should go to end of "hello" = offset 4 ('o')
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("e")
        XCTAssertEqual(cursorPos, 4)
    }

    func testWWithCount() {
        // At 0, 2w should skip "hello" and "world" — go to start of "second"
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2w")
        XCTAssertEqual(cursorPos, 12)
    }

    func testBWithCount() {
        // At offset 18 (' ' between "second" and "line"), first b goes to 's' at 12,
        // second b crosses newline to 'w' at 6 ("world")
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        keys("2b")
        XCTAssertEqual(cursorPos, 6)
    }

    func testEWithCount() {
        // At 0, 2e should go to end of "world" = offset 10 ('d')
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2e")
        XCTAssertEqual(cursorPos, 10)
    }

    // MARK: - Line Motions (0, $)

    func testZeroMovesToLineStart() {
        // Position in middle of first line
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("0")
        XCTAssertEqual(cursorPos, 0)
    }

    func testZeroOnSecondLine() {
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        keys("0")
        XCTAssertEqual(cursorPos, 12)
    }

    func testDollarMovesToLineEnd() {
        // "hello world\n" — $ should go to last content char 'd' at offset 10
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("$")
        XCTAssertEqual(cursorPos, 10)
    }

    func testDollarOnSecondLine() {
        // "second line\n" — starts at 12, last content char 'e' at 22
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("$")
        XCTAssertEqual(cursorPos, 22)
    }

    // MARK: - Document Motions (G, gg)

    func testGGMovesToDocumentStart() {
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("gg")
        XCTAssertEqual(cursorPos, 0)
    }

    func testGMovesToLastLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("G", shift: true)
        // G goes to start of last line. Last line starts at 24.
        let lineRange = buffer.lineRange(forOffset: cursorPos)
        let lastLineRange = buffer.lineRange(forOffset: buffer.length - 1)
        XCTAssertEqual(lineRange.location, lastLineRange.location)
    }

    func testCountGMovesToSpecificLine() {
        // 2G goes to line 2 (1-indexed), which is 0-indexed line 1 starting at offset 12
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        key("G", shift: true)
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 1, "2G should go to line 2 (0-indexed line 1)")
    }

    func testCountGGMovesToSpecificLine() {
        // 2gg goes to line 2 (1-indexed), which is 0-indexed line 1
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2gg")
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 1, "2gg should go to line 2 (0-indexed line 1)")
    }

    // MARK: - Insert Mode Entry (i, a, A, I, o, O)

    func testIEntersInsertMode() {
        let consumed = engine.process("i", shift: false)
        XCTAssertTrue(consumed)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(lastMode, .insert)
    }

    func testIDoesNotMoveCursor() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("i")
        XCTAssertEqual(cursorPos, 5)
    }

    func testAEntersInsertModeAfterCursor() {
        buffer.setSelectedRange(NSRange(location: 2, length: 0))
        keys("a")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(cursorPos, 3)
    }

    func testAAtEndOfBuffer() {
        buffer.setSelectedRange(NSRange(location: buffer.length, length: 0))
        keys("a")
        XCTAssertEqual(engine.mode, .insert)
        // At end, cannot advance further
        XCTAssertEqual(cursorPos, buffer.length)
    }

    func testAUpperEntersInsertModeAtLineEnd() {
        // "hello world\n" — A should position cursor at offset 11 (after 'd', before '\n')
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        key("A", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(cursorPos, 11)
    }

    func testIUpperEntersInsertModeAtLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("I", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(cursorPos, 0)
    }

    func testIUpperOnSecondLine() {
        buffer.setSelectedRange(NSRange(location: 18, length: 0))
        key("I", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(cursorPos, 12)
    }

    func testOOpensLineBelowAndEntersInsert() {
        // Cursor on first line ("hello world\n")
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("o")
        XCTAssertEqual(engine.mode, .insert)
        // "hello world\n" has lineEnd=12, insert "\n" at 12 → "hello world\n\nsecond..."
        // Line ends with \n, so cursor at lineEnd=12 (the inserted \n = blank line)
        XCTAssertEqual(cursorPos, 12, "Cursor should be on the new blank line")
        XCTAssertTrue(buffer.text.contains("hello world\n\n"), "Should insert a newline after current line")
    }

    func testOUpperOpensLineAboveAndEntersInsert() {
        // Cursor on second line
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("O")
        XCTAssertEqual(engine.mode, .insert)
        // O inserts "\n" at start of current line (offset 12), cursor goes to 12
        XCTAssertEqual(cursorPos, 12, "O should place cursor on the new blank line above")
    }

    func testOOnLastLineWithoutTrailingNewline() {
        // Buffer without trailing newline
        buffer = VimTextBufferMock(text: "line one\nline two")
        engine = VimEngine(buffer: buffer)
        // Cursor on last line
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("o")
        XCTAssertEqual(engine.mode, .insert)
        // "line two" has no trailing newline; o inserts "\n" at offset 17 (end of buffer)
        // lineEndsWithNewline is false, so cursorPos = lineEnd + 1 = 17 + 1 = 18
        XCTAssertEqual(buffer.text, "line one\nline two\n", "Should append newline after last line")
        XCTAssertEqual(buffer.selectedRange().location, 18, "Cursor should be on the new blank line past the inserted newline")
    }

    func testEscapeReturnsToNormalMode() {
        keys("i")
        XCTAssertEqual(engine.mode, .insert)
        escape()
        XCTAssertEqual(engine.mode, .normal)
    }

    func testEscapeInInsertMovesCursorBack() {
        // Vim convention: exiting insert mode moves cursor back one position
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(cursorPos, 4)
    }

    func testEscapeInInsertAtLineStartStays() {
        // At start of line, escape should not move cursor back past line boundary
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        escape()
        XCTAssertEqual(cursorPos, 0)
    }

    // MARK: - Delete Operations (x, dd, d+motion)

    func testXDeletesCharacterUnderCursor() {
        // "hello world\n..." — delete 'h' at offset 0
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x")
        XCTAssertEqual(buffer.text, "ello world\nsecond line\nthird line\n")
    }

    func testXWithCount() {
        // 3x at offset 0 deletes "hel"
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3x")
        XCTAssertEqual(buffer.text, "lo world\nsecond line\nthird line\n")
    }

    func testXDoesNotCrossLineBoundary() {
        // Position at 'd' (offset 10), which is the last char before '\n' at 11
        // 5x should only delete 'd' (1 char), not cross into the newline
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("5x")
        // Only 1 char available before newline, so only 'd' is deleted
        XCTAssertEqual(buffer.text, "hello worl\nsecond line\nthird line\n")
    }

    func testXAtEndOfLine() {
        // Position at 'd' (offset 10), last content char
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("x")
        XCTAssertEqual(buffer.text, "hello worl\nsecond line\nthird line\n")
    }

    func testXOnEmptyLine() {
        buffer = VimTextBufferMock(text: "line\n\nline\n")
        engine = VimEngine(buffer: buffer)
        // Cursor on the empty line (offset 5, which is the '\n' at the empty line)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("x")
        // contentEnd == pos for empty line; deleteCount should be 0; no change
        XCTAssertEqual(buffer.text, "line\n\nline\n")
    }

    func testDDDeletesCurrentLine() {
        // Delete first line "hello world\n"
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
    }

    func testDDWithCount() {
        // 2dd deletes first two lines
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2dd")
        XCTAssertEqual(buffer.text, "third line\n")
    }

    func testDDOnLastRemainingLine() {
        buffer = VimTextBufferMock(text: "only line\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "")
    }

    func testDWDeletesWord() {
        // At offset 0, dw deletes "hello " (from 0 to next word boundary)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw")
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
    }

    func testDDollarDeletesToLineEnd() {
        // d$ at offset 5 should delete from 5 through last char before newline (inclusive)
        // "hello world\n" — offset 5 is ' ', d$ should delete " world" (offsets 5-10)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("d$")
        // $ motion moves to offset 10 (last char). d$ with inclusive means deletes 5..10 inclusive = 6 chars
        XCTAssertEqual(buffer.text, "hello\nsecond line\nthird line\n")
    }

    func testDZeroDeletesToLineStart() {
        // d0 at offset 5 should delete from 0 to 5 (exclusive end)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("d0")
        XCTAssertEqual(buffer.text, " world\nsecond line\nthird line\n")
    }

    func testDBDeletesBackwardWord() {
        // At offset 6 ('w' in "world"), db should delete backwards to word boundary
        // b from 6 goes to 6 (start of "world"), then from word start...
        // Actually, from 6 ('w'), b goes to 0 ('h') — no, let's check:
        // wordBoundary(forward: false, from: 6) — pos=5 (' '), not word char, skip; pos=4 ('o'), word char;
        // then go back through word chars to pos=0. So b goes to 0.
        // db deletes from 0 to 6 = "hello "
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("db")
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
    }

    // MARK: - Change Operations (cc, c+motion)

    func testCCChangesEntireLine() {
        // cc deletes line content (keeps newline) and enters insert mode
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("cc")
        XCTAssertEqual(engine.mode, .insert)
        // "hello world\n" content deleted, newline kept
        XCTAssertEqual(buffer.text, "\nsecond line\nthird line\n")
        XCTAssertEqual(cursorPos, 0)
    }

    func testCWChangesWord() {
        // cw at offset 0 should delete "hello" to next word boundary, enter insert
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("cw")
        XCTAssertEqual(engine.mode, .insert)
        // w from 0 goes to 6, so range 0-6 ("hello ") is deleted
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
    }

    func testCDollarChangesToLineEnd() {
        // c$ at offset 5 changes from 5 to end of line
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("c$")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "hello\nsecond line\nthird line\n")
    }

    // MARK: - Yank and Paste (yy, y+motion, p, P)

    func testYYYanksCurrentLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        // Buffer should be unchanged
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
        // Cursor should remain on same line
        let (line, _) = buffer.lineAndColumn(forOffset: cursorPos)
        XCTAssertEqual(line, 0)
    }

    func testYWYanksWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw")
        // Buffer unchanged
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
        // Cursor should be at start of yanked range
        XCTAssertEqual(cursorPos, 0)
    }

    func testPPastesCharacterwiseAfterCursor() {
        // Yank "hello " with yw, then paste after cursor
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw") // Yanks from 0 to word boundary
        // Now cursor is at 0, move to offset 11 (newline)... let's stay at 0
        keys("p")
        // Characterwise paste inserts after cursor position (pos+1)
        // "hello " inserted at offset 1
        XCTAssertEqual(buffer.text, "hhello ello world\nsecond line\nthird line\n",
            "yw should yank 'hello ' and p should paste it after cursor position 0")
    }

    func testPUpperPastesBeforeCursor() {
        // Delete 'h' with x to store in register, then P pastes before cursor
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("x") // Deletes 'l' at offset 3, register = "l"
        XCTAssertEqual(buffer.text, "helo world\nsecond line\nthird line\n")
        keys("P")
        // P pastes before cursor (at position 3)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testPPastesLinewiseAfterCurrentLine() {
        // yy to yank line, j to go to second line, p to paste after
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy") // Yanks "hello world\n"
        keys("j")  // Move to second line
        keys("p")  // Paste linewise after current line
        // Should insert "hello world\n" after "second line\n"
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nhello world\nthird line\n")
    }

    func testPUpperPastesLinewiseBeforeCurrentLine() {
        // yy to yank line, j to second line, P to paste before
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy") // Yanks "hello world\n"
        keys("j")  // Move to second line
        key("P", shift: true) // Paste linewise before current line
        // Should insert "hello world\n" before "second line\n"
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n")
    }

    func testDDThenPRestoresLine() {
        // Delete first line, then paste it back
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd") // Deletes "hello world\n", cursor on "second line"
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
        keys("p") // Linewise paste after current line
        XCTAssertEqual(buffer.text, "second line\nhello world\nthird line\n")
    }

    // MARK: - Undo/Redo

    func testUCallsUndo() {
        XCTAssertEqual(buffer.undoCallCount, 0)
        keys("u")
        XCTAssertEqual(buffer.undoCallCount, 1)
    }

    func testUCallsUndoMultipleTimes() {
        keys("u")
        keys("u")
        keys("u")
        XCTAssertEqual(buffer.undoCallCount, 3)
    }

    func testCtrlRCallsRedo() {
        XCTAssertEqual(buffer.redoCallCount, 0)
        engine.redo()
        XCTAssertEqual(buffer.redoCallCount, 1)
    }

    // MARK: - Count Prefix

    func testCountPrefixWithMotion() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3l")
        XCTAssertEqual(cursorPos, 3)
    }

    func testCountPrefixWithOperator() {
        // 3dd deletes 3 lines
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3dd")
        // All three content lines deleted (plus trailing newline gives empty)
        XCTAssertEqual(buffer.text, "")
    }

    func testCountPrefixOverflow() {
        // Large count should be capped and not crash
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("999999l")
        // Should not crash, cursor should be clamped to valid position
        XCTAssertEqual(cursorPos, 10, "Large count with l should clamp to last content char of line")
    }

    func testZeroAsMotionNotCount() {
        // 0 alone should go to line start (it's a motion, not count digit)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("0")
        XCTAssertEqual(cursorPos, 0)
    }

    func testZeroAfterCountIsCountDigit() {
        // "10l" — 1 starts count, 0 continues it -> count=10, l moves right 10
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("10l")
        XCTAssertEqual(cursorPos, 10)
    }

    func testEscapeClearsCountPrefix() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3")
        escape()
        // Now type l — should move by 1, not 3
        keys("l")
        XCTAssertEqual(cursorPos, 1)
    }

    // MARK: - Pending Operator

    func testPendingOperatorCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d") // Enter pending delete
        escape()   // Cancel
        keys("l") // Should just be a motion, not delete
        XCTAssertEqual(cursorPos, 1)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testPendingOperatorCancelledByUnknownKey() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d")  // Enter pending delete
        keys("z")  // Unknown key cancels operator
        // Buffer should be unchanged
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testDoubleOperatorExecutes() {
        // dd deletes line
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")

        // yy yanks line (buffer unchanged)
        keys("yy")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")

        // cc changes line (enters insert, deletes content)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("cc")
        XCTAssertEqual(engine.mode, .insert)
    }

    // MARK: - Command Line Mode

    func testColonEntersCommandLineMode() {
        keys(":")
        if case .commandLine(let buf) = engine.mode {
            XCTAssertEqual(buf, ":")
        } else {
            XCTFail("Expected commandLine mode")
        }
    }

    func testEscapeExitsCommandLineMode() {
        keys(":")
        escape()
        XCTAssertEqual(engine.mode, .normal)
    }

    func testCommandW() {
        keys(":")
        keys("w")
        enter()
        XCTAssertEqual(lastCommand, "w")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testCommandQ() {
        keys(":")
        keys("q")
        enter()
        XCTAssertEqual(lastCommand, "q")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testCommandWQ() {
        keys(":")
        keys("wq")
        enter()
        XCTAssertEqual(lastCommand, "wq")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testBackspaceInCommandLine() {
        keys(":")
        keys("wq")
        // Command buffer should be ":wq"
        backspace()
        // Should remove last char, leaving ":w"
        if case .commandLine(let buf) = engine.mode {
            XCTAssertEqual(buf, ":w")
        } else {
            XCTFail("Expected commandLine mode after backspace")
        }
    }

    func testBackspaceOnEmptyCommandExitsToNormal() {
        keys(":")
        // Buffer is just ":", backspace should exit to normal
        backspace()
        XCTAssertEqual(engine.mode, .normal)
    }

    func testCommandLineCharsAppend() {
        keys(":")
        keys("s")
        keys("e")
        keys("t")
        if case .commandLine(let buf) = engine.mode {
            XCTAssertEqual(buf, ":set")
        } else {
            XCTFail("Expected commandLine mode")
        }
    }

    func testSlashEntersCommandLineMode() {
        keys("/")
        if case .commandLine(let buf) = engine.mode {
            XCTAssertEqual(buf, "/")
        } else {
            XCTFail("Expected commandLine mode with /")
        }
    }

    // MARK: - Edge Cases

    func testEmptyBuffer() {
        buffer = VimTextBufferMock(text: "")
        engine = VimEngine(buffer: buffer)

        // Motions should not crash
        keys("h")
        XCTAssertEqual(buffer.selectedRange().location, 0)
        keys("l")
        XCTAssertEqual(buffer.selectedRange().location, 0)
        keys("j")
        keys("k")
        keys("w")
        keys("b")
        keys("e")
        keys("0")
        keys("$")
        keys("gg")
        key("G", shift: true)

        // Operations should not crash
        keys("x")
        keys("dd")
        keys("yy")

        XCTAssertEqual(buffer.text, "")
    }

    func testSingleCharacterBuffer() {
        buffer = VimTextBufferMock(text: "a")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))

        // x deletes the single character
        keys("x")
        XCTAssertEqual(buffer.text, "")
    }

    func testSingleCharacterBufferMotions() {
        buffer = VimTextBufferMock(text: "a")
        engine = VimEngine(buffer: buffer)

        keys("l")
        // 'a' is at 0, length 1, no newline. contentEnd=1, maxPos=0. Can't go right.
        XCTAssertEqual(buffer.selectedRange().location, 0)

        keys("h")
        XCTAssertEqual(buffer.selectedRange().location, 0)
    }

    func testCursorAtBufferEnd() {
        // Position at the very end of buffer (past all characters)
        // With trailing newline, offset == length is a phantom empty line
        // h cannot cross line boundary, so cursor stays at length
        buffer.setSelectedRange(NSRange(location: buffer.length, length: 0))
        keys("h")
        // On the phantom empty line after trailing \n, h stays put
        XCTAssertEqual(buffer.selectedRange().location, buffer.length)

        // Use k to move to previous line, then h should work
        keys("k")
        let posAfterK = buffer.selectedRange().location
        XCTAssertTrue(posAfterK < buffer.length, "k should move off the phantom line")
    }

    func testProcessReturnsConsumedStatus() {
        // Normal mode keys should be consumed
        let consumedH = engine.process("h", shift: false)
        XCTAssertTrue(consumedH)

        // Enter insert mode
        _ = engine.process("i", shift: false)
        // In insert mode, non-escape keys pass through (not consumed)
        let consumedA = engine.process("a", shift: false)
        XCTAssertFalse(consumedA, "Insert mode should not consume regular characters")

        // Escape is consumed in insert mode
        let consumedEsc = engine.process("\u{1B}", shift: false)
        XCTAssertTrue(consumedEsc)
    }

    func testResetClearsAllState() {
        // Build up some state
        keys("3d")
        engine.reset()
        XCTAssertEqual(engine.mode, .normal)
        // After reset, l should move by 1 (no lingering count or pending operator)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        XCTAssertEqual(cursorPos, 1)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testUnknownKeyInNormalModeConsumed() {
        let consumed = engine.process("z", shift: false)
        XCTAssertTrue(consumed, "Unknown keys should be consumed in normal mode")
    }

    func testMultipleOperationsSequentially() {
        // Delete first line, then delete second (now first) line
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
        keys("dd")
        XCTAssertEqual(buffer.text, "third line\n")
        keys("dd")
        XCTAssertEqual(buffer.text, "")
    }

    func testDJDeletesTwoLines() {
        // dj should delete the current line and the line below
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dj")
        // Should delete lines 0 and 1 ("hello world\nsecond line\n")
        XCTAssertEqual(buffer.text, "third line\n")
    }

    func testDKDeletesTwoLines() {
        // dk on line 1 should delete lines 0 and 1
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("dk")
        XCTAssertEqual(buffer.text, "third line\n")
    }

    func testXSavesToRegisterAndPCanPaste() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x")  // Delete 'h', stored in register
        XCTAssertEqual(buffer.text, "ello world\nsecond line\nthird line\n")
        keys("p")  // Paste 'h' after cursor
        // 'h' pasted at offset 1
        XCTAssertEqual(buffer.text, "ehllo world\nsecond line\nthird line\n",
            "x deletes 'h', p pastes 'h' at offset 1")
    }

    func testGPendingCancelledByNonG() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("g")  // Enter pending g
        keys("x")  // Not 'g', so pending g is consumed/cancelled
        // Cursor should still be at 5 (unknown g-prefixed key consumed, no motion)
        XCTAssertEqual(engine.mode, .normal)
    }

    func testDEDeletesInclusiveToWordEnd() {
        // de at offset 0 should delete "hello" (inclusive of 'o' at offset 4)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("de")
        // e goes to offset 4, inclusive means delete 0..4 inclusive = 5 chars
        XCTAssertEqual(buffer.text, " world\nsecond line\nthird line\n")
    }

    func testCCWithCount() {
        // 2cc should change two lines
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2cc")
        XCTAssertEqual(engine.mode, .insert)
        // Both "hello world\n" and "second line\n" content deleted, last newline kept
        XCTAssertEqual(buffer.text, "\nthird line\n")
    }

    func testYYThenPAfterDelete() {
        // Yank first line, delete it, then paste
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        keys("dd")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
        // Register now has dd content (linewise), not yy content
        // Actually dd overwrites the register. So p pastes "hello world\n"
        keys("p")
        XCTAssertEqual(buffer.text, "second line\nhello world\nthird line\n")
    }

    func testDDOverwritesYYRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy") // yank "hello world\n"
        keys("j")  // move to second line
        keys("dd") // delete "second line\n" — overwrites register
        XCTAssertEqual(buffer.text, "hello world\nthird line\n")
        // Cursor is on "third line\n" (offset 12). Linewise p inserts AFTER current line.
        keys("p")
        XCTAssertEqual(buffer.text, "hello world\nthird line\nsecond line\n",
            "dd must overwrite the yy register; linewise paste goes after current line")
    }

    // MARK: - First Non-Blank Motions (^, _)

    func testCaretMovesToFirstNonBlank() {
        // Buffer with leading spaces: "   hello world\n..."
        buffer = VimTextBufferMock(text: "   hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("^")
        XCTAssertEqual(cursorPos, 3, "^ should move to first non-blank character")
    }

    func testUnderscoreMovesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello world\nsecond line\nthird line\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("_")
        XCTAssertEqual(cursorPos, 3, "_ should move to first non-blank character")
    }

    func testCaretOnLineWithNoLeadingSpace() {
        // No leading whitespace: ^ should go to position 0
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("^")
        XCTAssertEqual(cursorPos, 0, "^ on line with no leading space should go to col 0")
    }

    func testCaretOnLineWithTabs() {
        buffer = VimTextBufferMock(text: "\t\thello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("^")
        XCTAssertEqual(cursorPos, 2, "^ should skip tabs to reach 'h'")
    }

    func testDeleteToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("d^")
        // d^ from pos 8: motion moves to first non-blank at 3, deletes range [3,8) = "hello"
        XCTAssertEqual(buffer.text, "    world\n")
    }

    func testVisualCaretExtendsSelection() {
        buffer = VimTextBufferMock(text: "   hello world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("v^")
        let sel = buffer.selectedRange()
        XCTAssertEqual(sel.location, 3)
        XCTAssertEqual(sel.length, 8)
    }
}

// swiftlint:enable file_length type_body_length
