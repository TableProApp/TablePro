//
//  VimEngineOperatorsTests.swift
//  TableProTests
//
//  Specification tests for the delete (d), change (c), and yank (y) operators,
//  including doublings (dd/cc/yy), shortcuts (D/C/Y/x/X), and operator+motion combos.
//

import XCTest
import TableProPluginKit
@testable import TablePro

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineOperatorsTests: XCTestCase {
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

    // MARK: - x: Delete Character Under Cursor

    func testXDeletesCharUnderCursor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x")
        XCTAssertEqual(buffer.text, "ello world\nsecond line\nthird line\n")
    }

    func testXWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3x")
        XCTAssertEqual(buffer.text, "lo world\nsecond line\nthird line\n")
    }

    func testXDoesNotCrossNewline() {
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("5x")
        XCTAssertEqual(buffer.text, "hello worl\nsecond line\nthird line\n",
            "x with count should clamp at the line-terminating newline")
    }

    func testXOnEmptyLineIsNoOp() {
        buffer = VimTextBufferMock(text: "a\n\nb\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 2, length: 0))
        keys("x")
        XCTAssertEqual(buffer.text, "a\n\nb\n", "x on empty line should leave buffer unchanged")
    }

    func testXOnLastCharOfLineMovesCursorBack() {
        // After deleting last content char, cursor should sit on the new last content char.
        buffer.setSelectedRange(NSRange(location: 10, length: 0))
        keys("x")
        XCTAssertEqual(pos, 9, "After x deletes last content char, cursor moves left")
    }

    // MARK: - X: Delete Character Before Cursor

    func testCapitalXDeletesCharBeforeCursor() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("X", shift: true)
        XCTAssertEqual(buffer.text, "hell world\nsecond line\nthird line\n",
            "X should delete the char to the left of the cursor")
    }

    func testCapitalXWithCount() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("3")
        key("X", shift: true)
        XCTAssertEqual(buffer.text, "he world\nsecond line\nthird line\n")
    }

    func testCapitalXAtLineStartIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        key("X", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "X must not cross line boundary backward")
    }

    func testCapitalXAtBufferStartIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("X", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    // MARK: - dd: Delete Line

    func testDDDeletesCurrentLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
    }

    func testDDWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2dd")
        XCTAssertEqual(buffer.text, "third line\n")
    }

    func testDDOnLastLineLeavesPreviousLineCursorOnIt() {
        // After deleting last line, cursor should sit on the new last line.
        buffer.setSelectedRange(NSRange(location: 28, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\n")
    }

    func testDDOnSoleLineEmptiesBuffer() {
        buffer = VimTextBufferMock(text: "only\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd")
        XCTAssertEqual(buffer.text, "")
    }

    func testDDCountClampsAtBufferEnd() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("99dd")
        XCTAssertEqual(buffer.text, "hello world\n", "dd with large count clamps to remaining lines")
    }

    // MARK: - d + Motion

    func testDWDeletesToNextWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw")
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
    }

    func testDEDeletesToWordEndInclusive() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("de")
        XCTAssertEqual(buffer.text, " world\nsecond line\nthird line\n",
            "de should delete inclusive of the word-end character")
    }

    func testDBDeletesBackwardWord() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("db")
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
    }

    func testDDollarDeletesToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("d$")
        XCTAssertEqual(buffer.text, "hello\nsecond line\nthird line\n")
    }

    func testDZeroDeletesToLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("d0")
        XCTAssertEqual(buffer.text, " world\nsecond line\nthird line\n")
    }

    func testDCaretDeletesToFirstNonBlank() {
        buffer = VimTextBufferMock(text: "   hello\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("d^")
        XCTAssertEqual(buffer.text, "   lo\n")
    }

    func testDGoesGoesAllToEndOfBuffer() {
        // dG from line 0 should delete all lines (linewise).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d")
        key("G", shift: true)
        XCTAssertEqual(buffer.text, "", "dG should delete from current line to end-of-buffer")
    }

    func testDGGFromMidBufferDeletesToTop() {
        buffer.setSelectedRange(NSRange(location: 14, length: 0))
        keys("dgg")
        XCTAssertEqual(buffer.text, "third line\n",
            "dgg should delete from current line to first line (linewise)")
    }

    func testDJDeletesTwoLines() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dj")
        XCTAssertEqual(buffer.text, "third line\n",
            "dj should delete current line and the line below (linewise)")
    }

    func testDKDeletesTwoLines() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("dk")
        XCTAssertEqual(buffer.text, "third line\n",
            "dk should delete current line and the line above (linewise)")
    }

    func testDCountWordsDeletesMultipleWords() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d3w")
        XCTAssertEqual(buffer.text, "line\nthird line\n",
            "d3w from offset 0 should delete 'hello world\\nsecond '")
    }

    // MARK: - D: Delete to End of Line

    func testCapitalDDeletesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("D", shift: true)
        XCTAssertEqual(buffer.text, "hello\nsecond line\nthird line\n",
            "D is shorthand for d$ and deletes through end-of-line content")
    }

    func testCapitalDOnEmptyLineIsNoOp() {
        buffer = VimTextBufferMock(text: "\nfoo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("D", shift: true)
        XCTAssertEqual(buffer.text, "\nfoo\n", "D on an empty line should not delete the newline")
    }

    // MARK: - yy: Yank Line

    func testYYDoesNotModifyBuffer() {
        let original = buffer.text
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        XCTAssertEqual(buffer.text, original)
    }

    func testYYThenPasteRestoresLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yyp")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n")
    }

    func testYYWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2yyp")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nsecond line\nthird line\n",
            "2yy should yank two lines, p pastes them after current line")
    }

    func testYYCursorStaysAtLineStart() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("yy")
        // Yank doesn't move cursor across lines; column may be preserved or cursor returned to motion start.
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 0)
    }

    // MARK: - y + Motion

    func testYWYanksWordIntoRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yw")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "yw must not modify the buffer")
    }

    func testYWThenPasteInsertsWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ywp")
        XCTAssertEqual(buffer.text, "hhello ello world\nsecond line\nthird line\n",
            "After yw, p pastes 'hello ' after the cursor at offset 0")
    }

    func testYDollarYanksToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("y$p")
        XCTAssertEqual(buffer.text, "hello  worldworld\nsecond line\nthird line\n",
            "y$ from offset 5 yanks ' world', p pastes it after cursor")
    }

    // MARK: - Y: Yank Line (synonym of yy)

    func testCapitalYYanksLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("Y", shift: true)
        keys("p")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n",
            "Y is a synonym for yy and yanks the whole line linewise")
    }

    // MARK: - cc: Change Line

    func testCCDeletesLineContentEntersInsert() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("cc")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "\nsecond line\nthird line\n")
        XCTAssertEqual(pos, 0)
    }

    func testCCWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2cc")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "\nthird line\n",
            "2cc should clear two lines' content and leave one newline")
    }

    // MARK: - c + Motion

    func testCWChangesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("cw")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
    }

    func testCDollarChangesToLineEnd() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("c$")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "hello\nsecond line\nthird line\n")
    }

    func testCEChangesToWordEndInclusive() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("ce")
        XCTAssertEqual(buffer.text, " world\nsecond line\nthird line\n",
            "ce should delete through the word-end character")
    }

    // MARK: - C: Change to End of Line

    func testCapitalCChangesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        key("C", shift: true)
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "hello\nsecond line\nthird line\n",
            "C is shorthand for c$")
    }

    // MARK: - Pending Operator Cancellation

    func testPendingDCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("d")
        escape()
        keys("l")
        XCTAssertEqual(pos, 1)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "Escape should cancel the pending operator without modifying the buffer")
    }

    func testPendingCCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("c")
        escape()
        keys("l")
        XCTAssertEqual(pos, 1)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    func testPendingYCancelledByEscape() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("y")
        escape()
        keys("p")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "Cancelled yank should leave the register untouched")
    }

    func testPendingOperatorCancelledByUnknownKey() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dz")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n")
    }

    // MARK: - Count Multiplication

    func testCountTimesCountMultipliesMotion() {
        // 2d3w should delete 6 words worth (counts multiply).
        buffer = VimTextBufferMock(text: "a b c d e f g\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2d3w")
        XCTAssertEqual(buffer.text, "g\n", "2d3w should delete 6 words (2*3)")
    }

    // MARK: - Register After Delete (Default Register)

    func testDeleteAndPasteRoundTrip() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dw")
        XCTAssertEqual(buffer.text, "world\nsecond line\nthird line\n")
        key("P", shift: true)
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nthird line\n",
            "Deleted text should round-trip through P")
    }
}

// swiftlint:enable file_length type_body_length
