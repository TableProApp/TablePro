//
//  VimEngineEdgeCasesTests.swift
//  TableProTests
//
//  Boundary, regression, and edge-case coverage that cuts across command families.
//  These tests target bugs we have seen in production: end-of-buffer cursor states,
//  empty buffers, single-char buffers, unicode, very long content.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// swiftlint:disable file_length type_body_length

@MainActor
final class VimEngineEdgeCasesTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

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

    @Test
    func emptyBufferAllMotionsAreSafe() {
        make("")
        keys("hjklwbe0$^_")
        keys("gg")
        key("G", shift: true)
        #expect(pos == 0)
        #expect(buffer.text == "")
    }

    @Test
    func emptyBufferOperatorsAreSafe() {
        make("")
        keys("xdwddyycc")
        #expect(buffer.text == "")
    }

    @Test
    func emptyBufferInsertEntryThenEscape() {
        make("")
        keys("i")
        escape()
        #expect(engine.mode == .normal)
        #expect(pos == 0)
    }

    @Test
    func emptyBufferVisualModeIsSafe() {
        make("")
        keys("v")
        #expect(engine.mode == .visual(linewise: false))
        #expect(buffer.selectedRange().length == 0)
        keys("d")
        #expect(buffer.text == "")
        #expect(engine.mode == .normal)
    }

    // MARK: - Single-Character Buffer

    @Test
    func singleCharBufferMotionsClamp() {
        make("a", at: 0)
        keys("l")
        #expect(pos == 0, "l on a single-char buffer should not move past the only char")
        keys("h")
        #expect(pos == 0)
        keys("w")
        #expect(pos == 0, "w on a single-char buffer should not move past the only char")
        keys("$")
        #expect(pos == 0)
        keys("0")
        #expect(pos == 0)
    }

    @Test
    func singleCharBufferXLeavesEmpty() {
        make("a", at: 0)
        keys("x")
        #expect(buffer.text == "")
        #expect(pos == 0)
    }

    // MARK: - End-of-Buffer Cursor Positions

    @Test
    func wAtVeryLastCharStaysOnIt() {
        // Regression: reported visually as block cursor sitting past the ';'.
        make("SELECT * FROM users;", at: 19)
        keys("w")
        #expect(pos == 19, "w on the last word of the buffer must stay on the last char")
    }

    @Test
    func escapeFromInsertAtEndOfNoNewlineBufferStepsBack() {
        // Regression: reported as Esc doing nothing visually after typing ';'.
        make("SELECT * FROM users;", at: 20)
        keys("i")
        escape()
        #expect(engine.mode == .normal)
        #expect(pos == 19, "Esc from insert at length should step back onto the last content char")
    }

    @Test
    func cursorClampedAfterDeleteAtEndOfBuffer() {
        make("hello", at: 4)
        keys("x")
        #expect(buffer.text == "hell")
        #expect(pos == 3, "After deleting the last char, cursor must clamp to new last char")
    }

    // MARK: - Trailing Newline Behaviour

    @Test
    func jOnLineWithJustNewlineIsNoOp() {
        make("\n", at: 0)
        key("J", shift: true)
        #expect(buffer.text == "\n", "J with no line below should not modify the buffer")
    }

    @Test
    func dollarOnEmptyLineStaysAtLineStart() {
        make("\n", at: 0)
        keys("$")
        #expect(pos == 0, "$ on an empty line should stay at column 0")
    }

    // MARK: - Multiple Trailing Newlines

    @Test
    func motionsOverConsecutiveEmptyLines() {
        make("a\n\n\nb\n", at: 0)
        keys("j")
        #expect(pos == 2, "j onto the first empty line lands at the line's start")
        keys("j")
        #expect(pos == 3)
        keys("j")
        #expect(pos == 4, "j onto 'b' line should land on 'b'")
    }

    // MARK: - Very Long Single Line

    @Test
    func motionsAcrossVeryLongLineDoNotCrash() {
        let payload = String(repeating: "a", count: 10_000)
        make(payload + "\n", at: 0)
        keys("$")
        #expect(pos == 9999, "$ on a 10k-char line should land on the last content char")
        keys("0")
        #expect(pos == 0)
        // Word motion across long content
        keys("w")
        // Single contiguous word, should land at end-of-content per the clamp rule.
        #expect(pos == 9999)
    }

    // MARK: - Unicode

    @Test
    func motionsOnAsciiSafeUnicode() {
        // The engine uses UTF-16 offsets. Pure-ASCII strings are 1 unit per char.
        make("café\n", at: 0)
        let length = buffer.length
        keys("$")
        #expect(pos == length - 2, "$ on 'café\\n' should land on the 'é' before the newline")
    }

    @Test
    func doubleByteUnicodeBuffer() {
        // CJK chars are UTF-16 BMP (one code unit each). The engine's offsets should
        // match what NSString reports for the buffer.
        make("你好世界\n", at: 0)
        keys("l")
        #expect(pos == 1, "l should advance one UTF-16 code unit")
        keys("$")
        // '\n' at offset 4, content end at 3.
        #expect(pos == 3)
    }

    // MARK: - Mixed Line Endings

    @Test
    func cRLFLineEndingsTreatedAsBoundary() {
        // Vim normally normalises CRLF, but our buffer mock preserves them. The
        // line motions should still treat the LF as the line terminator.
        make("hello\r\nworld\n", at: 0)
        keys("j")
        let (line, _) = buffer.lineAndColumn(forOffset: pos)
        #expect(line == 1, "j across a CRLF should reach line 1")
    }

    // MARK: - Count Cap

    @Test
    func extremeCountDoesNotOverflowOrCrash() {
        make("hello\n", at: 0)
        // Type a million-digit count then a motion; engine must cap and execute safely.
        for _ in 0..<200 { _ = engine.process("9", shift: false) }
        keys("l")
        #expect(pos == 4, "Count beyond the cap should still produce a clamped motion")
    }

    // MARK: - Visual Mode Operator Composition

    @Test
    func visualSelectThenOperatorThenUndo() {
        make("hello world\n", at: 0)
        keys("v")
        keys("e")
        keys("d")
        #expect(buffer.text == " world\n")
        keys("u")
        #expect(buffer.undoCallCount == 1, "u should undo the visual delete")
    }

    // MARK: - Mode Switching Idempotency

    @Test
    func rapidModeSwitchesPreserveState() {
        make("hello\n", at: 0)
        // i → Esc → i → Esc many times. Cursor should remain stable.
        for _ in 0..<10 {
            keys("i")
            escape()
        }
        #expect(engine.mode == .normal)
        // After the first Esc the cursor sits at 0, so 'i'/Esc cycles keep it there.
        #expect(pos == 0)
    }

    // MARK: - Reset

    @Test
    func resetClearsAllPendingState() {
        make("hello world\n", at: 5)
        keys("3d")
        engine.reset()
        #expect(engine.mode == .normal)
        // After reset, plain l should advance by 1, not by 3.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("l")
        #expect(pos == 1, "reset() must clear count and pending operator")
    }
}

// swiftlint:enable file_length type_body_length
