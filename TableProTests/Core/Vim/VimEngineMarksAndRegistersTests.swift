//
//  VimEngineMarksAndRegistersTests.swift
//  TableProTests
//
//  Specification tests for marks (m / ' / `) and named/numbered registers ("{a-z}, "0-9).
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineMarksAndRegistersTests: XCTestCase {
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

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - Marks: Set and Jump

    func testSetMarkAndJumpBackToExactPosition() {
        // mma sets mark 'a' at cursor. Move away. `a jumps back to exact location.
        buffer.setSelectedRange(NSRange(location: 7, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("`a")
        XCTAssertEqual(pos, 7, "`a should restore the exact cursor offset where mark 'a' was set")
    }

    func testJumpToMarkLineWithSingleQuote() {
        // 'a jumps to the FIRST non-blank of the marked line (not exact offset).
        buffer = VimTextBufferMock(text: "  one\n  two\n  three\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 4, length: 0)) // line 0 col 4 ('n' in 'one')
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("'a")
        XCTAssertEqual(pos, 2, "'a should jump to first non-blank of the marked line (offset 2)")
    }

    func testMultipleMarks() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 15, length: 0))
        keys("mb")
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("mc")

        keys("`a")
        XCTAssertEqual(pos, 5)
        keys("`b")
        XCTAssertEqual(pos, 15)
        keys("`c")
        XCTAssertEqual(pos, 25)
    }

    func testOverwritingMark() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 20, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("`a")
        XCTAssertEqual(pos, 20, "Overwriting a mark should update its position")
    }

    func testJumpToUnsetMarkIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("`z")
        XCTAssertEqual(pos, 5, "Jumping to an unset mark should not move the cursor")
    }

    func testMarksSurviveEdits() {
        // Set mark, edit elsewhere, mark should still resolve.
        buffer.setSelectedRange(NSRange(location: 25, length: 0))
        keys("ma")
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("x") // delete first char — mark should adjust offset accordingly
        keys("`a")
        XCTAssertEqual(pos, 24, "Mark should adjust to compensate for earlier edits")
    }

    // MARK: - Special Mark: '' (Last Jump)

    func testDoubleQuoteJumpsToPreviousPosition() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        // Jump to G (record previous position).
        _ = engine.process("G", shift: true)
        let landedAt = pos
        keys("``")
        XCTAssertEqual(pos, 5, "`` should jump back to the position before the last jump")
        XCTAssertNotEqual(landedAt, pos)
    }

    // MARK: - Named Registers: Yank

    func testYankToNamedRegisterAndPaste() {
        // "ayy yanks line into register 'a'. Move, then "ap pastes from 'a'.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"ayy")
        keys("j")
        keys("\"ap")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\nhello world\nthird line\n",
            "Named register 'a' should preserve the yank across other yanks/deletes")
    }

    func testNamedRegisterIndependentFromUnnamed() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"ayy") // 'a' has line 0
        keys("j")
        keys("yy")    // unnamed register has line 1
        // "ap should still paste line 0; p should paste line 1.
        keys("k")
        keys("\"ap")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nthird line\n",
            "Named register 'a' should be unaffected by intervening unnamed yanks")
    }

    func testDeleteToNamedRegister() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"add") // delete line 0 into 'a'
        XCTAssertEqual(buffer.text, "second line\nthird line\n")
        keys("\"ap")
        XCTAssertEqual(buffer.text, "second line\nhello world\nthird line\n",
            "Deleted text should be retrievable from the named register")
    }

    // MARK: - Numbered Registers: Yank Cycle

    func testYankPopulatesRegisterZero() {
        // y populates register "0 (the yank register).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("yy")
        // Delete a different line — unnamed register changes but "0 keeps the yank.
        keys("jdd")
        XCTAssertEqual(buffer.text, "hello world\nthird line\n")
        keys("\"0p") // paste from yank register, not from latest delete
        XCTAssertEqual(buffer.text, "hello world\nthird line\nhello world\n",
            "\"0 should preserve the last YANKED text, not the last deleted text")
    }

    func testDeletePopulatesRegisterOne() {
        // d populates register "1; the next d pushes the previous "1 into "2.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("dd") // line 0 → "1
        keys("dd") // line 1 → "1, old "1 → "2
        XCTAssertEqual(buffer.text, "third line\n")
        keys("\"2p")
        XCTAssertEqual(buffer.text, "third line\nhello world\n",
            "\"2 should hold the previously deleted line after another deletion")
    }

    func testRegistersDoNotApplyToMotions() {
        // "a then a motion (no operator) should not crash and should consume the "a sequence.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("\"a")
        keys("l")
        XCTAssertEqual(pos, 6, "Motion after register selection should still execute as a motion")
    }

    // MARK: - Uppercase Named Register (Append)

    func testUppercaseRegisterAppends() {
        // "Ayy appends to register 'a' (rather than overwriting).
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("\"ayy") // 'a' = "hello world\n"
        keys("j")
        keys("\"A")
        keys("yy") // append "second line\n" to 'a'
        // Now 'a' should contain both lines.
        keys("\"ap")
        XCTAssertEqual(buffer.text.contains("hello world\nsecond line\nhello world\nsecond line\n"), true,
            "Uppercase register should append to lowercase counterpart")
    }
}
