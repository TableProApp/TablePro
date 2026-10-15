//
//  VimEngineInsertModeEditTests.swift
//  TableProTests
//
//  Spec for editing shortcuts available inside Insert mode: Ctrl+W (delete previous
//  word), Ctrl+U (delete to line start), Ctrl+T (indent), Ctrl+D (outdent). Ctrl+H is
//  left to the text view, whose deleteBackward it is.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineInsertModeEditTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    init() {
        buffer = VimTextBufferMock(text: "hello world\n")
        engine = VimEngine(buffer: buffer)
    }

    private func enterInsert(at offset: Int) {
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
        _ = engine.process("i", shift: false)
    }

    // MARK: - Ctrl+W: Delete previous word

    @Test
    func ctrlWDeletesPreviousWord() {
        enterInsert(at: 11)
        _ = engine.process("\u{17}", shift: false) // Ctrl+W
        #expect(buffer.text == "hello \n",
            "Ctrl+W in insert mode should delete the previous word ('world')")
    }

    @Test
    func ctrlWInMiddleOfWord() {
        // Cursor at offset 8 (inside 'world'). Ctrl+W should delete back to 'w'.
        enterInsert(at: 8)
        _ = engine.process("\u{17}", shift: false)
        #expect(buffer.text == "hello rld\n",
            "Ctrl+W mid-word should delete back to the start of the current word")
    }

    @Test
    func ctrlWAtLineStartIsNoOp() {
        enterInsert(at: 0)
        _ = engine.process("\u{17}", shift: false)
        #expect(buffer.text == "hello world\n",
            "Ctrl+W at line start should not cross the line boundary")
    }

    @Test
    func ctrlWConsumed() {
        enterInsert(at: 11)
        let consumed = engine.process("\u{17}", shift: false)
        #expect(consumed, "Ctrl+W in insert mode must be consumed by the engine")
    }

    // MARK: - Ctrl+U: Delete to line start

    @Test
    func ctrlUDeletesToLineStart() {
        enterInsert(at: 11)
        _ = engine.process("\u{15}", shift: false) // Ctrl+U
        #expect(buffer.text == "\n",
            "Ctrl+U should delete everything from cursor back to the start of the line")
    }

    @Test
    func ctrlUOnEmptyLineIsNoOp() {
        buffer = VimTextBufferMock(text: "\n")
        engine = VimEngine(buffer: buffer)
        enterInsert(at: 0)
        _ = engine.process("\u{15}", shift: false)
        #expect(buffer.text == "\n")
    }

    @Test
    func ctrlUInMiddleOfLine() {
        enterInsert(at: 6)
        _ = engine.process("\u{15}", shift: false)
        #expect(buffer.text == "world\n",
            "Ctrl+U mid-line should delete just the part before the cursor")
    }

    // MARK: - Ctrl+H: Backspace

    @Test
    func ctrlHIsLeftToTheTextViewBackspace() {
        enterInsert(at: 5)
        let consumed = engine.process("\u{08}", shift: false) // Ctrl+H
        #expect(!consumed,
            "Ctrl+H in insert mode is the text view's deleteBackward, which handles selections and every cursor")
        #expect(buffer.text == "hello world\n")
    }

    // MARK: - Ctrl+T / Ctrl+D: Indent / Outdent

    @Test
    func ctrlTIndentsCurrentLine() {
        enterInsert(at: 5)
        _ = engine.process("\u{14}", shift: false) // Ctrl+T
        #expect(buffer.text == "    hello world\n",
            "Ctrl+T in insert mode should add one indent level to the current line")
    }

    @Test
    func ctrlDOutdentsCurrentLine() {
        buffer = VimTextBufferMock(text: "        hello\n")
        engine = VimEngine(buffer: buffer)
        enterInsert(at: 10)
        _ = engine.process("\u{04}", shift: false) // Ctrl+D
        #expect(buffer.text == "    hello\n",
            "Ctrl+D should remove one indent level from the current line")
    }

    // MARK: - Mode invariants

    @Test
    func ctrlEditsKeepInsertMode() {
        enterInsert(at: 11)
        _ = engine.process("\u{17}", shift: false)
        #expect(engine.mode == .insert, "Ctrl+W should not exit insert mode")
        _ = engine.process("\u{15}", shift: false)
        #expect(engine.mode == .insert, "Ctrl+U should not exit insert mode")
    }

    // MARK: - In Replace Mode

    @Test
    func ctrlWInReplaceModeDeletesPreviousWord() {
        buffer.setSelectedRange(NSRange(location: 11, length: 0))
        _ = engine.process("R", shift: true)
        #expect(engine.mode == .replace)
        _ = engine.process("\u{17}", shift: false)
        #expect(buffer.text == "hello \n",
            "Ctrl+W should work in replace mode too")
    }
}
