//
//  VimEngineNumberAdjustTests.swift
//  TableProTests
//
//  Spec for Ctrl+A (increment) and Ctrl+X (decrement) on numbers under or after
//  the cursor on the current line.
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineNumberAdjustTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func make(_ text: String, at offset: Int) {
        buffer = VimTextBufferMock(text: text)
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
    }

    // MARK: - Ctrl+A: Increment

    func testCtrlAIncrementsNumberUnderCursor() {
        make("x = 42\n", at: 4)
        _ = engine.process("\u{01}", shift: false) // Ctrl+A
        XCTAssertEqual(buffer.text, "x = 43\n", "Ctrl+A should increment the number under the cursor")
    }

    func testCtrlAFindsNumberAfterCursor() {
        make("x = 42\n", at: 0)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "x = 43\n",
            "Ctrl+A should find the next number to the right of the cursor on the current line")
    }

    func testCtrlAWithCount() {
        make("x = 42\n", at: 4)
        _ = engine.process("5", shift: false)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "x = 47\n", "5<C-a> should increment by 5")
    }

    func testCtrlANegativeNumber() {
        make("x = -5\n", at: 4)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "x = -4\n",
            "Ctrl+A on a negative number should increment toward zero")
    }

    func testCtrlAZeroToOne() {
        make("x = 0\n", at: 4)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "x = 1\n")
    }

    func testCtrlAOnLineWithoutNumberIsNoOp() {
        make("foo bar baz\n", at: 0)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "foo bar baz\n",
            "Ctrl+A on a line without any number should not modify the buffer")
    }

    // MARK: - Ctrl+X: Decrement

    func testCtrlXDecrementsNumberUnderCursor() {
        make("x = 42\n", at: 4)
        _ = engine.process("\u{18}", shift: false) // Ctrl+X
        XCTAssertEqual(buffer.text, "x = 41\n", "Ctrl+X should decrement the number under the cursor")
    }

    func testCtrlXWithCount() {
        make("x = 42\n", at: 4)
        _ = engine.process("1", shift: false)
        _ = engine.process("0", shift: false)
        _ = engine.process("\u{18}", shift: false)
        XCTAssertEqual(buffer.text, "x = 32\n", "10<C-x> should decrement by 10")
    }

    func testCtrlXOnZeroProducesNegative() {
        make("x = 0\n", at: 4)
        _ = engine.process("\u{18}", shift: false)
        XCTAssertEqual(buffer.text, "x = -1\n")
    }

    // MARK: - Hex Numbers

    func testCtrlAOnHex() {
        make("x = 0x1F\n", at: 4)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "x = 0x20\n",
            "Ctrl+A on a hex number should preserve the format and increment")
    }

    func testCtrlXOnHex() {
        make("x = 0x10\n", at: 4)
        _ = engine.process("\u{18}", shift: false)
        XCTAssertEqual(buffer.text, "x = 0xf\n",
            "Ctrl+X on hex should preserve the format and decrement")
    }

    // MARK: - Cursor Position After Adjust

    func testCursorLandsOnLastDigitAfterIncrement() {
        make("x = 9\n", at: 4)
        _ = engine.process("\u{01}", shift: false)
        // After 9 → 10, cursor should land on '0' (the new last digit).
        XCTAssertEqual(buffer.text, "x = 10\n")
        XCTAssertEqual(buffer.selectedRange().location, 5,
            "Cursor should land on the last digit of the new number after increment")
    }

    // MARK: - Multi-Digit Numbers

    func testCtrlAOnLargeNumber() {
        make("count = 999\n", at: 8)
        _ = engine.process("\u{01}", shift: false)
        XCTAssertEqual(buffer.text, "count = 1000\n",
            "Ctrl+A across a digit-rollover should add a digit")
    }
}
