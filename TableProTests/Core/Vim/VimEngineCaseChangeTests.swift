//
//  VimEngineCaseChangeTests.swift
//  TableProTests
//
//  Specification tests for ~ toggle case and the gu / gU / g~ case operators.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineCaseChangeTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "Hello World\nsecond LINE\n")
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

    // MARK: - ~ Toggle Case

    func testTildeTogglesSingleCharCase() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("~")
        XCTAssertEqual(buffer.text, "hello World\nsecond LINE\n",
            "~ should flip case of the char under the cursor")
    }

    func testTildeAdvancesCursor() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("~")
        XCTAssertEqual(pos, 1, "~ should advance cursor by one after toggling")
    }

    func testTildeWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("5~")
        XCTAssertEqual(buffer.text, "hELLO World\nsecond LINE\n",
            "5~ should toggle case of 5 chars starting at cursor")
    }

    func testTildeDoesNotCrossNewline() {
        // Cursor at offset 8 ('r' in 'World'). 99~ should toggle from cursor to end of
        // line — 'r','l','d' → 'R','L','D'. The newline must not be consumed.
        buffer.setSelectedRange(NSRange(location: 8, length: 0))
        keys("99~")
        XCTAssertEqual(buffer.text, "Hello WoRLD\nsecond LINE\n",
            "~ with count should clamp at end of current line")
    }

    func testTildeOnNonLetterCharacterIsNoChange() {
        buffer = VimTextBufferMock(text: "a 1 b\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 1, length: 0))
        keys("~")
        XCTAssertEqual(buffer.text, "a 1 b\n",
            "~ on whitespace/digit should not change content")
        XCTAssertEqual(pos, 2)
    }

    // MARK: - g~ Toggle Case Operator

    func testGTildeWordTogglesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("g~w")
        XCTAssertEqual(buffer.text, "hELLO World\nsecond LINE\n",
            "g~w should toggle case for the word range")
    }

    func testGTildeTildeTogglesLine() {
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("g~~")
        XCTAssertEqual(buffer.text, "hELLO wORLD\nsecond LINE\n",
            "g~~ should toggle case of the entire current line")
    }

    func testGTildeDollarTogglesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("g~$")
        XCTAssertEqual(buffer.text, "Hello wORLD\nsecond LINE\n",
            "g~$ should toggle case from cursor to end of line")
    }

    // MARK: - gu: Lowercase Operator

    func testGUWordLowercasesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("guw")
        XCTAssertEqual(buffer.text, "hello World\nsecond LINE\n",
            "guw should lowercase the word range")
    }

    func testGUUlowercasesLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("guu")
        XCTAssertEqual(buffer.text, "Hello World\nsecond line\n",
            "guu should lowercase the entire current line")
    }

    func testGUDollarLowercasesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("gu$")
        XCTAssertEqual(buffer.text, "Hello world\nsecond LINE\n",
            "gu$ should lowercase from cursor to end of line")
    }

    // MARK: - gU: Uppercase Operator

    func testGUUppercaseWordUppercasesWord() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gU")
        keys("w")
        XCTAssertEqual(buffer.text, "HELLO World\nsecond LINE\n",
            "gUw should uppercase the word range")
    }

    func testGUUUppercasesLine() {
        buffer.setSelectedRange(NSRange(location: 12, length: 0))
        keys("gU")
        keys("U")
        XCTAssertEqual(buffer.text, "Hello World\nSECOND LINE\n",
            "gUU should uppercase the entire current line")
    }

    func testGUUppercaseDollarUppercasesToEndOfLine() {
        buffer.setSelectedRange(NSRange(location: 6, length: 0))
        keys("gU$")
        XCTAssertEqual(buffer.text, "Hello WORLD\nsecond LINE\n",
            "gU$ should uppercase from cursor to end of line")
    }

    // MARK: - Pending Cancellation

    func testGUEscapeCancels() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("gu")
        _ = engine.process("\u{1B}", shift: false)
        // Now type a motion — should be a plain motion, not part of gu.
        keys("l")
        XCTAssertEqual(pos, 1)
        XCTAssertEqual(buffer.text, "Hello World\nsecond LINE\n")
    }
}
