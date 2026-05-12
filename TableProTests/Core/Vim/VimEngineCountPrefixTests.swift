//
//  VimEngineCountPrefixTests.swift
//  TableProTests
//
//  Specification tests for count prefix parsing and behavior in Normal mode.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineCountPrefixTests: XCTestCase {
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

    // MARK: - Single Digit Count

    func testSingleDigitCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3l")
        XCTAssertEqual(pos, 3)
    }

    func testCountIsConsumed() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3l")
        // After the motion, the count is gone — next l moves only 1.
        keys("l")
        XCTAssertEqual(pos, 4, "Count must be consumed by the motion it precedes")
    }

    // MARK: - Multi-Digit Count

    func testTwoDigitCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("10l")
        XCTAssertEqual(pos, 10)
    }

    func testThreeDigitCount() {
        buffer = VimTextBufferMock(text: String(repeating: "a", count: 200) + "\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("123l")
        XCTAssertEqual(pos, 123)
    }

    // MARK: - Zero Handling

    func testZeroAsLineStartMotion() {
        // Leading 0 (not preceded by a digit) is the line-start motion, not a count.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("0")
        XCTAssertEqual(pos, 0)
    }

    func testZeroAfterDigitIsPartOfCount() {
        // 10l should be ten-l, not zero-then-l.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("10l")
        XCTAssertEqual(pos, 10)
    }

    func testZeroInMiddleOfCount() {
        buffer = VimTextBufferMock(text: String(repeating: "a", count: 200) + "\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("102l")
        XCTAssertEqual(pos, 102, "0 inside a count sequence must be a digit, not motion")
    }

    // MARK: - Count Cleared by Escape

    func testEscapeClearsCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3")
        _ = engine.process("\u{1B}", shift: false)
        keys("l")
        XCTAssertEqual(pos, 1, "Escape should clear the pending count")
    }

    func testEscapeClearsCountForOperator() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3")
        _ = engine.process("\u{1B}", shift: false)
        keys("dd")
        XCTAssertEqual(buffer.text, "second line\nthird line\n",
            "After Escape, count should not apply to the next operator")
    }

    // MARK: - Count Cleared by Unknown Key

    func testUnknownKeyClearsCount() {
        // Q is a genuinely unknown key in our engine. Using it after the count
        // prefix should consume the count without applying any motion. The next
        // `l` then moves by 1, not by 3.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3Q")
        keys("l")
        XCTAssertEqual(pos, 1)
    }

    // MARK: - Count Multiplication for Operators

    func testOperatorTimesMotionMultiplies() {
        // 2d3w → delete 6 words
        buffer = VimTextBufferMock(text: "a b c d e f g h\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2d3w")
        XCTAssertEqual(buffer.text, "g h\n", "2 * 3 = 6 words deleted")
    }

    // MARK: - Count Preserved Through Operator Doubling

    func testCountAppliesToOperatorDoubling() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2dd")
        XCTAssertEqual(buffer.text, "third line\n",
            "2dd should delete two lines")
    }

    func testCountAppliesToYY() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2yy")
        keys("p")
        XCTAssertEqual(buffer.text, "hello world\nhello world\nsecond line\nsecond line\nthird line\n",
            "2yy should yank two lines for paste")
    }

    func testCountAppliesToCC() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2cc")
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(buffer.text, "\nthird line\n",
            "2cc should clear two lines and enter insert mode")
    }

    // MARK: - Overflow Protection

    func testVeryLargeCountDoesNotCrash() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("999999999l")
        // Should not crash; cursor clamped to end of line.
        XCTAssertEqual(pos, 10)
    }

    func testCountCappedAtSafeMaximum() {
        // 1_000_000 digits should be capped before arithmetic overflow.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys(String(repeating: "9", count: 50) + "l")
        XCTAssertEqual(pos, 10, "Engine must not overflow on extreme count values")
    }

    // MARK: - Count Not Counted as Motion in Insert Mode

    func testCountInsideInsertModePassesThrough() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        let consumed = engine.process("3", shift: false)
        XCTAssertFalse(consumed, "Digits in insert mode must pass through to the text view")
    }
}
