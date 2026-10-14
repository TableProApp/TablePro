//
//  VimEngineIndentTests.swift
//  TableProTests
//
//  Specification tests for the indent operators >> and << and their motion forms.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
final class VimEngineIndentTests {
    private var engine: VimEngine!
    private var buffer: VimTextBufferMock!

    /// Indent width is typically 4 spaces in TablePro's editor. Tests assert that exact width
    /// to lock the expected behavior; if the engine reads the editor's `tabWidth`, this can
    /// be refactored to inject a width into the engine.
    private let indentString = "    "

    init() {
        buffer = VimTextBufferMock(text: "one\ntwo\nthree\n")
        engine = VimEngine(buffer: buffer)
    }

    private func keys(_ chars: String) {
        for char in chars { _ = engine.process(char, shift: false) }
    }

    // MARK: - >>: Indent Current Line

    @Test
    func doubleGreaterIndentsCurrentLine() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys(">>")
        #expect(buffer.text == "\(indentString)one\ntwo\nthree\n",
            ">> should add one indent (4 spaces) to the current line")
    }

    @Test
    func doubleGreaterWithCount() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3>>")
        #expect(buffer.text == "\(indentString)one\n\(indentString)two\n\(indentString)three\n",
            "3>> should indent the current line and the next two lines")
    }

    @Test
    func greaterMotionIndentsRange() {
        // >j should indent the current line and the next line.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys(">j")
        #expect(buffer.text == "\(indentString)one\n\(indentString)two\nthree\n",
            ">j should indent the current line and the line below")
    }

    @Test
    func greaterGoesIndentsToEndOfBuffer() {
        // >G from line 0 indents every line.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys(">")
        _ = engine.process("G", shift: true)
        #expect(buffer.text == "\(indentString)one\n\(indentString)two\n\(indentString)three\n",
            ">G should indent from the current line through the end of the buffer")
    }

    // MARK: - <<: Outdent Current Line

    @Test
    func doubleLessOutdentsCurrentLine() {
        buffer = VimTextBufferMock(text: "        one\ntwo\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("<<")
        #expect(buffer.text == "\(indentString)one\ntwo\n",
            "<< should remove one indent from the current line")
    }

    @Test
    func doubleLessWithCount() {
        buffer = VimTextBufferMock(text: "    one\n    two\n    three\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("3<<")
        #expect(buffer.text == "one\ntwo\nthree\n",
            "3<< should remove one indent from three consecutive lines")
    }

    @Test
    func doubleLessNoIndentIsNoOp() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("<<")
        #expect(buffer.text == "one\ntwo\nthree\n",
            "<< on an unindented line should be a no-op")
    }

    @Test
    func doubleLessLessIndentThanWidthRemovesAll() {
        // If a line has only 2 leading spaces but indent width is 4, <<
        // should remove all the leading whitespace it can (Vim behavior).
        buffer = VimTextBufferMock(text: "  one\n")
        engine = VimEngine(buffer: buffer)
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys("<<")
        #expect(buffer.text == "one\n",
            "<< on under-indented line should remove the leading whitespace it has")
    }

    // MARK: - =: Auto-indent (just verify it consumes correctly)

    @Test
    func equalsOperatorConsumesPair() {
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        let consumed = engine.process("=", shift: false)
        #expect(consumed, "= should be a recognized operator prefix")
    }

    // MARK: - Cursor Position After Indent

    @Test
    func indentMovesCursorToFirstNonBlank() {
        // After >>, cursor should be on the first non-blank of the indented line.
        buffer.setSelectedRange(NSRange(location: 0, length: 0))
        keys(">>")
        let cursor = buffer.selectedRange().location
        #expect(cursor == indentString.count,
            "Cursor should land on the first non-blank after >>")
    }
}
