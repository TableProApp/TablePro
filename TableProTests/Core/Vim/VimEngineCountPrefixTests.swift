//
//  VimEngineCountPrefixTests.swift
//  TableProTests
//
//  Specification tests for count prefix parsing and behavior in Normal mode.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineCountPrefixTests {
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

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - Single Digit Count

    @Test
    func singleDigitCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3l")
        #expect(pos == 3)
    }

    @Test
    func countIsConsumed() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3l")
        // After the motion, the count is gone — next l moves only 1.
        keys("l")
        #expect(pos == 4, "Count must be consumed by the motion it precedes")
    }

    // MARK: - Multi-Digit Count

    @Test
    func twoDigitCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("10l")
        #expect(pos == 10)
    }

    @Test
    func threeDigitCount() {
        buffer = VimTextBufferMock(text: String(repeating: "a", count: 200) + "\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("123l")
        #expect(pos == 123)
    }

    // MARK: - Zero Handling

    @Test
    func zeroAsLineStartMotion() {
        // Leading 0 (not preceded by a digit) is the line-start motion, not a count.
        buffer.setSelectedRange(NSRange(location: 5, length: 0))
        keys("0")
        #expect(pos == 0)
    }

    @Test
    func zeroAfterDigitIsPartOfCount() {
        // 10l should be ten-l, not zero-then-l.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("10l")
        #expect(pos == 10)
    }

    @Test
    func zeroInMiddleOfCount() {
        buffer = VimTextBufferMock(text: String(repeating: "a", count: 200) + "\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("102l")
        #expect(pos == 102, "0 inside a count sequence must be a digit, not motion")
    }

    // MARK: - Count Cleared by Escape

    @Test
    func escapeClearsCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3")
        _ = engine.process("\u{1B}", shift: false)
        keys("l")
        #expect(pos == 1, "Escape should clear the pending count")
    }

    @Test
    func escapeClearsCountForOperator() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3")
        _ = engine.process("\u{1B}", shift: false)
        keys("dd")
        #expect(buffer.text == "second line\nthird line\n",
            "After Escape, count should not apply to the next operator")
    }

    // MARK: - Count Cleared by Unknown Key

    @Test
    func unknownKeyClearsCount() {
        // Q is a genuinely unknown key in our engine. Using it after the count
        // prefix should consume the count without applying any motion. The next
        // `l` then moves by 1, not by 3.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3Q")
        keys("l")
        #expect(pos == 1)
    }

    // MARK: - Count Multiplication for Operators

    @Test
    func operatorTimesMotionMultiplies() {
        // 2d3w → delete 6 words
        buffer = VimTextBufferMock(text: "a b c d e f g h\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2d3w")
        #expect(buffer.text == "g h\n", "2 * 3 = 6 words deleted")
    }

    // MARK: - Count Preserved Through Operator Doubling

    @Test
    func countAppliesToOperatorDoubling() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2dd")
        #expect(buffer.text == "third line\n",
            "2dd should delete two lines")
    }

    @Test
    func countAppliesToYY() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2yy")
        keys("p")
        #expect(buffer.text == "hello world\nhello world\nsecond line\nsecond line\nthird line\n",
            "2yy should yank two lines for paste")
    }

    @Test
    func countAppliesToCC() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("2cc")
        #expect(engine.mode == .insert)
        #expect(buffer.text == "\nthird line\n",
            "2cc should clear two lines and enter insert mode")
    }

    // MARK: - Overflow Protection

    @Test
    func veryLargeCountDoesNotCrash() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("999999999l")
        // Should not crash; cursor clamped to end of line.
        #expect(pos == 10)
    }

    @Test
    func countCappedAtSafeMaximum() {
        // 1_000_000 digits should be capped before arithmetic overflow.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys(String(repeating: "9", count: 50) + "l")
        #expect(pos == 10, "Engine must not overflow on extreme count values")
    }

    // MARK: - Count Not Counted as Motion in Insert Mode

    @Test
    func countInsideInsertModePassesThrough() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("i")
        let consumed = engine.process("3", shift: false)
        #expect(!consumed, "Digits in insert mode must pass through to the text view")
    }
}
