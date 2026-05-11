//
//  VimEngineInsertModeEditTests.swift
//  TableProTests
//
//  Spec for editing shortcuts available inside Insert mode: Ctrl+W (delete previous
//  word), Ctrl+U (delete to line start), Ctrl+H (backspace), Ctrl+T (indent), Ctrl+D
//  (outdent), Ctrl+J (newline), Ctrl+M (carriage return → newline).
//

import XCTest
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimEngineInsertModeEditTests: XCTestCase {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    override func setUp() {
        super.setUp()
        buffer = VimTextBufferMock(text: "hello world\n")
        engine = VimEngine(buffer: buffer)
    }

    override func tearDown() {
        engine = nil
        buffer = nil
        super.tearDown()
    }

    private func enterInsert(at offset: Int) {
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
        _ = engine.process("i", shift: false)
    }

    // MARK: - Ctrl+W: Delete previous word

    func testCtrlWDeletesPreviousWord() {
        enterInsert(at: 11)
        _ = engine.process("\u{17}", shift: false) // Ctrl+W
        XCTAssertEqual(buffer.text, "hello \n",
            "Ctrl+W in insert mode should delete the previous word ('world')")
    }

    func testCtrlWInMiddleOfWord() {
        // Cursor at offset 8 (inside 'world'). Ctrl+W should delete back to 'w'.
        enterInsert(at: 8)
        _ = engine.process("\u{17}", shift: false)
        XCTAssertEqual(buffer.text, "hello rld\n",
            "Ctrl+W mid-word should delete back to the start of the current word")
    }

    func testCtrlWAtLineStartIsNoOp() {
        enterInsert(at: 0)
        _ = engine.process("\u{17}", shift: false)
        XCTAssertEqual(buffer.text, "hello world\n",
            "Ctrl+W at line start should not cross the line boundary")
    }

    func testCtrlWConsumed() {
        enterInsert(at: 11)
        let consumed = engine.process("\u{17}", shift: false)
        XCTAssertTrue(consumed, "Ctrl+W in insert mode must be consumed by the engine")
    }

    // MARK: - Ctrl+U: Delete to line start

    func testCtrlUDeletesToLineStart() {
        enterInsert(at: 11)
        _ = engine.process("\u{15}", shift: false) // Ctrl+U
        XCTAssertEqual(buffer.text, "\n",
            "Ctrl+U should delete everything from cursor back to the start of the line")
    }

    func testCtrlUOnEmptyLineIsNoOp() {
        buffer = VimTextBufferMock(text: "\n")
        engine = VimEngine(buffer: buffer)
        enterInsert(at: 0)
        _ = engine.process("\u{15}", shift: false)
        XCTAssertEqual(buffer.text, "\n")
    }

    func testCtrlUInMiddleOfLine() {
        enterInsert(at: 6)
        _ = engine.process("\u{15}", shift: false)
        XCTAssertEqual(buffer.text, "world\n",
            "Ctrl+U mid-line should delete just the part before the cursor")
    }

    // MARK: - Ctrl+H: Backspace

    func testCtrlHDeletesPreviousChar() {
        enterInsert(at: 5)
        _ = engine.process("\u{08}", shift: false) // Ctrl+H
        XCTAssertEqual(buffer.text, "hell world\n",
            "Ctrl+H should delete the char before the cursor")
    }

    // MARK: - Ctrl+T / Ctrl+D: Indent / Outdent

    func testCtrlTIndentsCurrentLine() {
        enterInsert(at: 5)
        _ = engine.process("\u{14}", shift: false) // Ctrl+T
        XCTAssertEqual(buffer.text, "    hello world\n",
            "Ctrl+T in insert mode should add one indent level to the current line")
    }

    func testCtrlDOutdentsCurrentLine() {
        buffer = VimTextBufferMock(text: "        hello\n")
        engine = VimEngine(buffer: buffer)
        enterInsert(at: 10)
        _ = engine.process("\u{04}", shift: false) // Ctrl+D
        XCTAssertEqual(buffer.text, "    hello\n",
            "Ctrl+D should remove one indent level from the current line")
    }

    // MARK: - Mode invariants

    func testCtrlEditsKeepInsertMode() {
        enterInsert(at: 11)
        _ = engine.process("\u{17}", shift: false)
        XCTAssertEqual(engine.mode, .insert, "Ctrl+W should not exit insert mode")
        _ = engine.process("\u{15}", shift: false)
        XCTAssertEqual(engine.mode, .insert, "Ctrl+U should not exit insert mode")
    }

    // MARK: - In Replace Mode

    func testCtrlWInReplaceModeDeletesPreviousWord() {
        buffer.setSelectedRange(NSRange(location: 11, length: 0))
        _ = engine.process("R", shift: true)
        XCTAssertEqual(engine.mode, .replace)
        _ = engine.process("\u{17}", shift: false)
        XCTAssertEqual(buffer.text, "hello \n",
            "Ctrl+W should work in replace mode too")
    }
}
