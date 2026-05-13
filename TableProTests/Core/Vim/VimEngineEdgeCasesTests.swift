//
//  VimEngineEdgeCasesTests.swift
//  TableProTests
//
//  Boundary, regression, and edge-case coverage that cuts across command families.
//  These tests target bugs we have seen in production: end-of-buffer cursor states,
//  empty buffers, single-char buffers, unicode, very long content.
//

import XCTest
import TableProPluginKit
@testable import TablePro

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineEdgeCasesTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func make(_ text: String, at offset: Int = 0) {
        buffer = VimTextBufferMock(text: text)
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    private func key(_ char: Character, shift: Bool = false) {
        _ = engine.process(char, shift: shift)
    }

    private func escape() { _ = engine.process("\u{1B}", shift: false) }

    private var pos: Int { buffer.selectedRange().location }

    // MARK: - Empty Buffer

    func testEmptyBufferAllMotionsAreSafe() {
        make("")
        keys("hjklwbe0$^_")
        keys("gg")
        key("G", shift: true)
        XCTAssertEqual(pos, 0)
        XCTAssertEqual(buffer.text, "")
    }

    func testEmptyBufferOperatorsAreSafe() {
        make("")
        keys("xdwddyycc")
        XCTAssertEqual(buffer.text, "")
    }

    func testEmptyBufferInsertEntryThenEscape() {
        make("")
        keys("i")
        escape()
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(pos, 0)
    }

    func testEmptyBufferVisualModeIsSafe() {
        make("")
        keys("v")
        XCTAssertEqual(engine.mode, .visual(linewise: false))
        XCTAssertEqual(buffer.selectedRange().length, 0)
        keys("d")
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: - Single-Character Buffer

    func testSingleCharBufferMotionsClamp() {
        make("a", at: 0)
        keys("l")
        XCTAssertEqual(pos, 0, "l on a single-char buffer should not move past the only char")
        keys("h")
        XCTAssertEqual(pos, 0)
        keys("w")
        XCTAssertEqual(pos, 0, "w on a single-char buffer should not move past the only char")
        keys("$")
        XCTAssertEqual(pos, 0)
        keys("0")
        XCTAssertEqual(pos, 0)
    }

    func testSingleCharBufferXLeavesEmpty() {
        make("a", at: 0)
        keys("x")
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(pos, 0)
    }

    // MARK: - End-of-Buffer Cursor Positions

    func testWAtVeryLastCharStaysOnIt() {
        // Regression: reported visually as block cursor sitting past the ';'.
        make("SELECT * FROM users;", at: 19)
        keys("w")
        XCTAssertEqual(pos, 19, "w on the last word of the buffer must stay on the last char")
    }

    func testEscapeFromInsertAtEndOfNoNewlineBufferStepsBack() {
        // Regression: reported as Esc doing nothing visually after typing ';'.
        make("SELECT * FROM users;", at: 20)
        keys("i")
        escape()
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(pos, 19, "Esc from insert at length should step back onto the last content char")
    }

    func testCursorClampedAfterDeleteAtEndOfBuffer() {
        make("hello", at: 4)
        keys("x")
        XCTAssertEqual(buffer.text, "hell")
        XCTAssertEqual(pos, 3, "After deleting the last char, cursor must clamp to new last char")
    }

    // MARK: - Trailing Newline Behaviour

    func testJOnLineWithJustNewlineIsNoOp() {
        make("\n", at: 0)
        key("J", shift: true)
        XCTAssertEqual(buffer.text, "\n", "J with no line below should not modify the buffer")
    }

    func testDollarOnEmptyLineStaysAtLineStart() {
        make("\n", at: 0)
        keys("$")
        XCTAssertEqual(pos, 0, "$ on an empty line should stay at column 0")
    }

    // MARK: - Multiple Trailing Newlines

    func testMotionsOverConsecutiveEmptyLines() {
        make("a\n\n\nb\n", at: 0)
        keys("j")
        XCTAssertEqual(pos, 2, "j onto the first empty line lands at the line's start")
        keys("j")
        XCTAssertEqual(pos, 3)
        keys("j")
        XCTAssertEqual(pos, 4, "j onto 'b' line should land on 'b'")
    }

    // MARK: - Very Long Single Line

    func testMotionsAcrossVeryLongLineDoNotCrash() {
        let payload = String(repeating: "a", count: 10_000)
        make(payload + "\n", at: 0)
        keys("$")
        XCTAssertEqual(pos, 9999, "$ on a 10k-char line should land on the last content char")
        keys("0")
        XCTAssertEqual(pos, 0)
        // Word motion across long content
        keys("w")
        // Single contiguous word, should land at end-of-content per the clamp rule.
        XCTAssertEqual(pos, 9999)
    }

    // MARK: - Unicode

    func testMotionsOnAsciiSafeUnicode() {
        // The engine uses UTF-16 offsets. Pure-ASCII strings are 1 unit per char.
        make("café\n", at: 0)
        let length = buffer.length
        keys("$")
        XCTAssertEqual(pos, length - 2, "$ on 'café\\n' should land on the 'é' before the newline")
    }

    func testDoubleByteUnicodeBuffer() {
        // CJK chars are UTF-16 BMP (one code unit each). The engine's offsets should
        // match what NSString reports for the buffer.
        make("你好世界\n", at: 0)
        keys("l")
        XCTAssertEqual(pos, 1, "l should advance one UTF-16 code unit")
        keys("$")
        // '\n' at offset 4, content end at 3.
        XCTAssertEqual(pos, 3)
    }

    // MARK: - Mixed Line Endings

    func testCRLFLineEndingsTreatedAsBoundary() {
        // Vim normally normalises CRLF, but our buffer mock preserves them. The
        // line motions should still treat the LF as the line terminator.
        make("hello\r\nworld\n", at: 0)
        keys("j")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        XCTAssertEqual(line, 1, "j across a CRLF should reach line 1")
    }

    // MARK: - Count Cap

    func testExtremeCountDoesNotOverflowOrCrash() {
        make("hello\n", at: 0)
        // Type a million-digit count then a motion; engine must cap and execute safely.
        for _ in 0..<200 { _ = engine.process("9", shift: false) }
        keys("l")
        XCTAssertEqual(pos, 4, "Count beyond the cap should still produce a clamped motion")
    }

    // MARK: - Visual Mode Operator Composition

    func testVisualSelectThenOperatorThenUndo() {
        make("hello world\n", at: 0)
        keys("v")
        keys("e")
        keys("d")
        XCTAssertEqual(buffer.text, " world\n")
        keys("u")
        XCTAssertEqual(buffer.undoCallCount, 1, "u should undo the visual delete")
    }

    // MARK: - Mode Switching Idempotency

    func testRapidModeSwitchesPreserveState() {
        make("hello\n", at: 0)
        // i → Esc → i → Esc many times. Cursor should remain stable.
        for _ in 0..<10 {
            keys("i")
            escape()
        }
        XCTAssertEqual(engine.mode, .normal)
        // After the first Esc the cursor sits at 0, so 'i'/Esc cycles keep it there.
        XCTAssertEqual(pos, 0)
    }

    // MARK: - Reset

    func testResetClearsAllPendingState() {
        make("hello world\n", at: 5)
        keys("3d")
        engine.reset()
        XCTAssertEqual(engine.mode, .normal)
        // After reset, plain l should advance by 1, not by 3.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        XCTAssertEqual(pos, 1, "reset() must clear count and pending operator")
    }
}

// swiftlint:enable file_length type_body_length
