//
//  VimEngineReplaceTests.swift
//  TableProTests
//
//  Specification tests for r{char} single-character replace and R overwrite mode.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineReplaceTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\nsecond line\n")
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

    // MARK: - r: Single Character Replace

    func testRReplacesSingleCharacter() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("rH")
        XCTAssertEqual(buffer.text, "Hello world\nsecond line\n",
            "r should replace the char under the cursor")
    }

    func testRStaysInNormalMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("rH")
        XCTAssertEqual(engine.mode, .normal,
            "r is a single-shot command; it must not enter insert mode")
    }

    func testRDoesNotMoveCursor() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("rX")
        XCTAssertEqual(pos, 5, "r should leave the cursor on the replaced char")
    }

    func testRWithCountReplacesMultipleChars() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3rX")
        XCTAssertEqual(buffer.text, "XXXlo world\nsecond line\n",
            "3rX should replace the next 3 chars with X")
    }

    func testRWithCountCursorOnLastReplaced() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3rX")
        XCTAssertEqual(pos, 2, "Cursor should sit on the last replaced char")
    }

    func testRCountExceedingLineRemainderIsNoOp() {
        // "hello world\n" — from offset 8 only 3 content chars remain ('rld'). 99rX must
        // not replace any chars (vim refuses to cross the newline).
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("99rX")
        XCTAssertEqual(buffer.text, "hello world\nsecond line\n",
            "r with count exceeding line content should be a no-op (must not overwrite newline)")
    }

    func testRWithNewlineReplacesCharWithNewline() {
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("r")
        _ = engine.process("\r", shift: false)
        XCTAssertEqual(buffer.text, "hello\nworld\nsecond line\n",
            "r<Enter> should replace the char with a newline")
    }

    func testREscapeCancelsReplace() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("r")
        escape()
        XCTAssertEqual(buffer.text, "hello world\nsecond line\n",
            "Escape during r prompt should cancel without modifying buffer")
        // Cursor should remain at offset 0 and mode normal.
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - R: Overwrite Mode

    func testCapitalREntersReplaceMode() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        XCTAssertEqual(engine.mode, .replace,
            "R should enter the dedicated .replace mode (overwrite, distinct from insert)")
    }

    func testCapitalROverwritesCharactersAsTyped() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        _ = engine.process("X", shift: true)
        _ = engine.process("Y", shift: true)
        XCTAssertEqual(buffer.text, "XYllo world\nsecond line\n",
            "Replace mode should overwrite chars at the cursor as the user types")
    }

    func testCapitalREscapeReturnsToNormal() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        key("R", shift: true)
        escape()
        XCTAssertEqual(engine.mode, .normal)
    }
}
