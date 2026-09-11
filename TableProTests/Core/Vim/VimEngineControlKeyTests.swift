//
//  VimEngineControlKeyTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class VimEngineControlKeyTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        let lines = (0..<30).map { "line\($0) text" }
        buffer = VimTextBufferMock(text: lines.joined(separator: "\n") + "\n")
        engine = VimEngine(buffer: buffer)
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func useText(_ text: String) {
        buffer = VimTextBufferMock(text: text)
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    @discardableResult
    private func control(_ letter: Character) -> Bool {
        let code = (letter.asciiValue ?? 0) & 0x1F
        return engine.process(Character(UnicodeScalar(code)), shift: false)
    }

    private var pos: Int { buffer.selectedRange().location }

    private var line: Int { buffer.lineAndColumn(forOffset: pos).line }

    private func caret(atLine line: Int, column: Int = 0) {
        buffer.setSelectedRange(NSRange(location: buffer.offset(forLine: line, column: column), length: 0))
    }

    // MARK: - Normal mode

    func testControlRRedoesThroughTheEngine() {
        XCTAssertTrue(control("r"))
        XCTAssertEqual(buffer.redoCallCount, 1)
    }

    func testControlRTakesACount() {
        keys("3")
        control("r")
        XCTAssertEqual(buffer.redoCallCount, 3)
    }

    func testControlHMovesLeftLikeH() {
        caret(atLine: 0, column: 5)
        let original = buffer.text
        XCTAssertTrue(control("h"))
        XCTAssertEqual(pos, 4)
        XCTAssertEqual(buffer.text, original, "Ctrl+H must move the caret in Normal mode, never delete")
    }

    func testControlHTakesACount() {
        caret(atLine: 0, column: 5)
        keys("3")
        control("h")
        XCTAssertEqual(pos, 2)
    }

    func testControlNAndControlPMoveBetweenLines() {
        caret(atLine: 4, column: 2)
        control("n")
        XCTAssertEqual(line, 5)
        control("p")
        control("p")
        XCTAssertEqual(line, 3)
    }

    func testControlNCompletesAPendingOperatorLikeJ() {
        useText("one\ntwo\nthree\n")
        keys("d")
        control("n")
        XCTAssertEqual(buffer.text, "three\n", "d followed by Ctrl+N deletes two lines, as dj does")
    }

    func testScrollControlCancelsAPendingOperator() {
        useText("one two three\n")
        keys("d")
        control("d")
        keys("w")
        XCTAssertEqual(buffer.text, "one two three\n", "Ctrl+D is no motion, so it abandons the pending d")
        XCTAssertNil(engine.pendingOperator)
    }

    func testScrollControlUsesAndConsumesItsCount() {
        caret(atLine: 0)
        keys("4")
        control("d")
        XCTAssertEqual(line, 4, "A count sets how many lines Ctrl+D moves")
        keys("j")
        XCTAssertEqual(line, 5, "The count must not carry over to the next command")
    }

    func testUnboundControlCharacterDoesNotEditInNormalMode() {
        caret(atLine: 0, column: 3)
        let original = buffer.text
        XCTAssertTrue(control("k"))
        XCTAssertTrue(control("o"))
        XCTAssertTrue(control("t"))
        XCTAssertEqual(buffer.text, original)
        XCTAssertEqual(engine.mode, .normal)
    }

    func testOptionTypedCharactersDoNotEditInNormalMode() {
        caret(atLine: 0, column: 3)
        let original = buffer.text
        XCTAssertTrue(engine.process("\u{02D9}", shift: false))
        XCTAssertTrue(engine.process("\u{00A0}", shift: false))
        XCTAssertEqual(buffer.text, original)
    }

    func testReplaceCharConsumesAControlCharacterWithoutWritingIt() {
        useText("hello\n")
        keys("r")
        control("d")
        keys("x")
        XCTAssertEqual(buffer.text, "ello\n", "r takes Ctrl+D as its argument, so the next x deletes")
    }

    // MARK: - Visual mode

    func testControlDExtendsTheVisualSelection() {
        caret(atLine: 0)
        keys("v")
        control("d")
        let selection = buffer.selectedRange()
        XCTAssertEqual(selection.location, 0)
        XCTAssertEqual(
            buffer.lineAndColumn(forOffset: selection.location + selection.length - 1).line,
            15,
            "Ctrl+D moves the visual cursor half the visible lines down"
        )
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    func testControlHMovesTheVisualCursor() {
        caret(atLine: 0)
        keys("vll")
        control("h")
        XCTAssertEqual(buffer.selectedRange(), NSRange(location: 0, length: 2))
    }

    func testUnboundControlCharacterLeavesTheVisualSelection() {
        caret(atLine: 0)
        keys("vl")
        let original = buffer.text
        control("k")
        XCTAssertEqual(buffer.text, original)
        XCTAssertEqual(buffer.selectedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(engine.mode, .visual(linewise: false))
    }

    // MARK: - Insert and Replace mode

    func testControlHInInsertModeIsLeftToTheTextView() {
        useText("a\u{1F600}b\n")
        buffer.setSelectedRange(NSRange(location: 3, length: 0))
        keys("i")
        XCTAssertFalse(control("h"), "Insert mode Ctrl+H is the text view's deleteBackward, as Delete is")
        XCTAssertEqual(buffer.text, "a\u{1F600}b\n")
        XCTAssertEqual(engine.mode, .insert)
    }

    func testControlHInReplaceModeRestoresLikeBackspace() {
        useText("hello\n")
        _ = engine.process("R", shift: true)
        _ = engine.process("X", shift: true)
        _ = engine.process("Y", shift: true)
        control("h")
        XCTAssertEqual(buffer.text, "Xello\n")
        XCTAssertEqual(pos, 1)
    }

    func testOptionTypedCharacterOverwritesInReplaceMode() {
        useText("hello\n")
        _ = engine.process("R", shift: true)
        _ = engine.process("\u{00E9}", shift: false)
        XCTAssertEqual(buffer.text, "\u{00E9}ello\n")
    }

    // MARK: - Command line

    func testControlHErasesInTheCommandLine() {
        keys(":ab")
        control("h")
        XCTAssertEqual(engine.mode, .commandLine(buffer: ":a"))
    }

    func testControlCharacterIsNotAppendedToTheCommandLine() {
        keys(":")
        control("d")
        control("k")
        XCTAssertEqual(engine.mode, .commandLine(buffer: ":"))
    }
}
