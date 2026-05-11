//
//  VimEngineJoinTests.swift
//  TableProTests
//
//  Specification tests for the J / gJ join commands in Normal and Visual modes.
//  Bug reference: https://github.com/TableProApp/TablePro/issues/1222
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineJoinTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello\nworld\n")
        engine = VimEngine(buffer: buffer)
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func process(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func escape() { _ = engine.process("\u{1B}", shift: false) }

    private var cursorPos: Int { buffer.selectedRange().location }

    // MARK: - J: Basic Join (Normal Mode)

    func testJJoinsCurrentLineWithNextWithSingleSpace() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "hello world\n",
            "J should join the next line onto the current one with a single space")
    }

    func testJCursorMovesToJoinPosition() {
        // Vim convention: cursor moves to the inserted space at the join point.
        // In "hello\nworld" -> "hello world", the inserted space is at offset 5.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(cursorPos, 5, "Cursor should land on the inserted space at the join")
    }

    func testJStaysInNormalMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(engine.mode, .normal)
    }

    func testJConsumesKey() {
        let consumed = engine.process("J", shift: true)
        XCTAssertTrue(consumed, "J must be consumed (not passed through to text view)")
    }

    func testJOnLastLineIsNoOp() {
        buffer = VimTextBufferMock(text: "only line\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "only line\n", "J on last line is a no-op (no line below)")
    }

    func testJOnLastLineWithoutTrailingNewline() {
        buffer = VimTextBufferMock(text: "only line")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "only line", "J on the single line should not modify the buffer")
    }

    // MARK: - J: Whitespace Handling

    func testJStripsLeadingWhitespaceFromNextLine() {
        // Vim strips leading whitespace from the joined-in line.
        buffer = VimTextBufferMock(text: "hello\n    world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "hello world\n",
            "J must strip leading whitespace from the next line before joining")
    }

    func testJStripsLeadingTabsFromNextLine() {
        buffer = VimTextBufferMock(text: "hello\n\t\tworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "hello world\n",
            "J must strip leading tabs from the next line")
    }

    func testJDoesNotAddSpaceWhenCurrentLineEndsWithSpace() {
        buffer = VimTextBufferMock(text: "hello \nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "hello world\n",
            "J should not insert an extra space when current line already ends with one")
    }

    func testJDoesNotAddSpaceBeforeClosingParen() {
        // Vim special case: no space inserted before ) at the start of the next line.
        buffer = VimTextBufferMock(text: "func(arg\n)\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "func(arg)\n",
            "J should not insert a space before a closing parenthesis")
    }

    func testJOnEmptyNextLineRemovesNewline() {
        // Joining with an empty next line just removes the newline; no space added.
        buffer = VimTextBufferMock(text: "hello\n\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "hello\nworld\n",
            "J with an empty next line removes the newline; no space inserted")
    }

    func testJOnEmptyCurrentLineKeepsNextLineContent() {
        // Empty current line + content next line should result in just the next-line content.
        buffer = VimTextBufferMock(text: "\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "world\n",
            "J on an empty current line should leave the next line content with no leading space")
    }

    // MARK: - J: Count Prefix

    func testJWithCountTwoJoinsTwoLines() {
        // [count]J joins [count] lines, minimum 2. 2J == J.
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two\nthree\n",
            "2J should join 2 lines (same as plain J)")
    }

    func testJWithCountThreeJoinsThreeLines() {
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two three\n",
            "3J should join the current line plus the next two lines")
    }

    func testJWithCountClampsAtLastLine() {
        // 5J on a 3-line buffer should join all 3 (clamped, no error).
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("5")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two three\n",
            "Count larger than remaining lines should clamp at the last line")
    }

    func testJWithCountOneIsSameAsJ() {
        // Per Vim docs: count of 1 still joins (minimum 2 lines).
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("1")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two\nthree\n",
            "1J behaves like J (minimum two lines joined)")
    }

    func testJWithCountClearsCountAfter() {
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2")
        process("J", shift: true)
        // Now type 'l' — should move 1, not lingering count of 2.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        XCTAssertEqual(cursorPos, 1, "Count prefix should be consumed by J")
    }

    // MARK: - gJ: Join Without Space

    func testGJJoinsWithoutInsertingSpace() {
        // gJ joins lines but does NOT insert a space between them.
        buffer = VimTextBufferMock(text: "hello\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gJ")
        XCTAssertEqual(buffer.text, "helloworld\n",
            "gJ should join lines without inserting a space")
    }

    func testGJPreservesLeadingWhitespaceOfNextLine() {
        // gJ does NOT strip leading whitespace from the next line.
        buffer = VimTextBufferMock(text: "hello\n    world\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gJ")
        XCTAssertEqual(buffer.text, "hello    world\n",
            "gJ should preserve leading whitespace on the joined line")
    }

    func testGJCursorAtOriginalLineEnd() {
        // After gJ, cursor sits at the first character of the joined-in content
        // (i.e., right after the original line end).
        buffer = VimTextBufferMock(text: "hello\nworld\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gJ")
        XCTAssertEqual(cursorPos, 5,
            "Cursor should land at the start of what was the next line after gJ")
    }

    func testGJWithCount() {
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3gJ")
        XCTAssertEqual(buffer.text, "onetwothree\n",
            "3gJ should join 3 lines without any spaces")
    }

    func testGJOnLastLineIsNoOp() {
        buffer = VimTextBufferMock(text: "only\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gJ")
        XCTAssertEqual(buffer.text, "only\n", "gJ on the last line is a no-op")
    }

    // MARK: - J in Visual Mode

    func testVisualJJoinsSelectedLines() {
        // V to select line, j to extend to next line, J to join.
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("V", shift: true)
        keys("j")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two\nthree\n",
            "Visual-line J should join all selected lines with single spaces")
    }

    func testVisualJJoinsThreeSelectedLines() {
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\nfour\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("V", shift: true)
        keys("jj")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two three\nfour\n",
            "Visual J across three lines should join all three with spaces")
    }

    func testVisualJReturnsToNormalMode() {
        buffer = VimTextBufferMock(text: "one\ntwo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("V", shift: true)
        keys("j")
        process("J", shift: true)
        XCTAssertEqual(engine.mode, .normal,
            "After visual J, the engine should return to normal mode")
    }

    func testVisualJStripsLeadingWhitespace() {
        buffer = VimTextBufferMock(text: "one\n    two\n    three\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("V", shift: true)
        keys("jj")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two three\n",
            "Visual J should strip leading whitespace from each joined line")
    }

    func testVisualCharacterwiseJJoinsCoveredLines() {
        // v across two lines, J should still join those lines.
        buffer = VimTextBufferMock(text: "one\ntwo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("v")
        keys("j")
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "one two\n",
            "Characterwise visual J should still join the lines covered by the selection")
    }

    // MARK: - gJ in Visual Mode

    func testVisualGJJoinsWithoutSpace() {
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("V", shift: true)
        keys("jj")
        keys("gJ")
        XCTAssertEqual(buffer.text, "onetwothree\n",
            "Visual gJ should concatenate without inserting spaces")
    }

    func testVisualGJReturnsToNormalMode() {
        buffer = VimTextBufferMock(text: "one\ntwo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("V", shift: true)
        keys("j")
        keys("gJ")
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Undo

    func testJIsUndoable() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        process("J", shift: true)
        XCTAssertEqual(buffer.text, "hello world\n")
        keys("u")
        XCTAssertEqual(buffer.undoCallCount, 1, "u should undo the join")
    }
}
